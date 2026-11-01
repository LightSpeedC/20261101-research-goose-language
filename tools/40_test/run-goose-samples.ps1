param(
	# goose を展開したフォルダ (goose.exe と samples を含む)
	[string]$GooseRoot = 'C:/Tools/Goose/goose-v2026.3-windows-x64',
	# 期待出力 (<name>.out) のフォルダ。公式リポジトリの samples/expected を置く
	[string]$ExpectedDir = (Join-Path $PSScriptRoot '../../tmp/src/expected'),
	# 実行結果とログの出力先
	[string]$OutDir = (Join-Path $PSScriptRoot '../../tmp/goose-out')
)
$ErrorActionPreference = 'Stop'
# Goose のサンプルを、公式ランナー (samples/run_samples.py) と同じ呼び方で実行し、期待出力と突き合わせる (r261101-01)
# JIT 実行 (goose --jit) と、ネイティブ実行 (goose build して実行) の両方を行う
$goose = "$GooseRoot/goose.exe"
$samples = "$GooseRoot/samples"
$expDir = $ExpectedDir
$outDir = $OutDir
if (-not (Test-Path -LiteralPath $goose)) { throw 'goose.exe が無い' }
if (-not (Test-Path -LiteralPath $expDir)) { throw '期待出力のフォルダが無い' }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path "$outDir/native" | Out-Null

# 窓を開かない (公式ランナーも同じ指定)
$env:GOOSE_GFX_HEADLESS = '1'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$runTimeoutMs = 120000
$buildTimeoutMs = 300000

function Invoke-Proc {
	param([string]$FilePath, [string[]]$ArgList, [string]$StdinPath, [string]$WorkDir, [string]$OutFile, [string]$ErrFile, [int]$TimeoutMs)
	$sp = @{ FilePath = $FilePath; WorkingDirectory = $WorkDir; NoNewWindow = $true; PassThru = $true; RedirectStandardOutput = $OutFile; RedirectStandardError = $ErrFile }
	if ($ArgList.Count -gt 0) { $sp.ArgumentList = $ArgList }
	if ($StdinPath) { $sp.RedirectStandardInput = $StdinPath }
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$proc = Start-Process @sp
	$null = $proc.Handle
	if (-not $proc.WaitForExit($TimeoutMs)) {
		taskkill /PID $proc.Id /T /F | Out-Null
		return [pscustomobject]@{ TimedOut = $true; Code = $null; Ms = $sw.ElapsedMilliseconds }
	}
	$proc.WaitForExit()
	return [pscustomobject]@{ TimedOut = $false; Code = $proc.ExitCode; Ms = $sw.ElapsedMilliseconds }
}

function Read-Normalized([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) { return $null }
	return ([System.IO.File]::ReadAllText($Path, $utf8)).Replace("`r`n", "`n").TrimEnd("`n")
}

function Get-ErrHead([string]$Path) {
	if (-not (Test-Path -LiteralPath $Path)) { return '' }
	$lines = [System.IO.File]::ReadAllText($Path, $utf8) -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^(parsed ok|typechecked ok|bce:)' }
	$first = $lines | Select-Object -First 1
	if ($first -and $first.Length -gt 90) { $first = $first.Substring(0, 90) }
	return $first
}

function Get-FirstDiff([string]$Actual, [string]$Expected) {
	$a = $Actual -split "`n"; $b = $Expected -split "`n"
	for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
		$x = if ($i -lt $a.Count) { $a[$i] } else { '(なし)' }
		$y = if ($i -lt $b.Count) { $b[$i] } else { '(なし)' }
		if ($x -cne $y) { return ($i + 1) }
	}
	return 0
}

# 実行結果を判定して「絵文字 + 語」を返す
function Judge-Run($Result, [string]$OutFile, [string]$ErrFile, $Want) {
	if ($Result.TimedOut) { return [pscustomobject]@{ Text = '⏱️ 時間切れ'; Note = '' } }
	$errText = if (Test-Path -LiteralPath $ErrFile) { [System.IO.File]::ReadAllText($ErrFile, $utf8) } else { '' }
	if ($Result.Code -ne 0 -and $errText -match 'JIT mode does not support') { return [pscustomobject]@{ Text = '⬜ JIT 非対応'; Note = '' } }
	if ($Result.Code -ne 0) { return [pscustomobject]@{ Text = "❌ 失敗 exit=$($Result.Code)"; Note = (Get-ErrHead $ErrFile) } }
	$got = Read-Normalized $OutFile
	if ($null -eq $Want) { return [pscustomobject]@{ Text = '☑️ 実行のみ'; Note = '期待出力なし' } }
	if ($got -ceq $Want) { return [pscustomobject]@{ Text = '✅ 一致'; Note = '' } }
	return [pscustomobject]@{ Text = '❌ 不一致'; Note = ('最初の差 {0} 行目' -f (Get-FirstDiff $got $Want)) }
}

$rows = New-Object System.Collections.ArrayList
foreach ($srcFile in (Get-ChildItem -LiteralPath $samples -Filter '*.goose' | Sort-Object Name)) {
	$name = $srcFile.BaseName -replace '^\d+_', ''
	$stdinPath = "$samples/data/$name.stdin"
	if (-not (Test-Path -LiteralPath $stdinPath)) { $stdinPath = $null }
	$progArgs = @()
	$argFile = "$samples/data/$name.args"
	if (Test-Path -LiteralPath $argFile) { $progArgs = @((Get-Content -LiteralPath $argFile -Raw -Encoding UTF8) -split '\s+' | Where-Object { $_ }) }
	$incArgs = @()
	if (Test-Path -LiteralPath "$samples/$name.h") { $incArgs = @('--include', "$samples/$name.h") }
	$want = Read-Normalized (Join-Path $expDir "$name.out")

	# JIT 実行
	$jitOut = Join-Path $outDir "$name.jit.out"; $jitErr = Join-Path $outDir "$name.jit.err"
	$jitResult = Invoke-Proc -FilePath $goose -ArgList (@('-O2') + $incArgs + @('--jit', $srcFile.FullName, '--') + $progArgs) -StdinPath $stdinPath -WorkDir $samples -OutFile $jitOut -ErrFile $jitErr -TimeoutMs $runTimeoutMs
	$jit = Judge-Run $jitResult $jitOut $jitErr $want

	# ネイティブ実行 (goose build してから実行)
	$exe = "$outDir/native/$name.exe"
	$buildOut = Join-Path $outDir "$name.build.out"; $buildErr = Join-Path $outDir "$name.build.err"
	if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }
	$buildResult = Invoke-Proc -FilePath $goose -ArgList (@('build', '-O2', '-o', $exe) + $incArgs + @($srcFile.FullName)) -StdinPath $null -WorkDir $samples -OutFile $buildOut -ErrFile $buildErr -TimeoutMs $buildTimeoutMs
	if ($buildResult.TimedOut -or $buildResult.Code -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
		$native = [pscustomobject]@{ Text = '❌ ビルド失敗'; Note = (Get-ErrHead $buildErr) }
	} else {
		$natOut = Join-Path $outDir "$name.native.out"; $natErr = Join-Path $outDir "$name.native.err"
		$natResult = Invoke-Proc -FilePath $exe -ArgList $progArgs -StdinPath $stdinPath -WorkDir $samples -OutFile $natOut -ErrFile $natErr -TimeoutMs $runTimeoutMs
		$native = Judge-Run $natResult $natOut $natErr $want
	}
	$note = (@($jit.Note, $native.Note) | Where-Object { $_ }) -join ' / '
	$row = [pscustomobject]@{ name = $name; jit = $jit.Text; native = $native.Text; note = $note }
	[void]$rows.Add($row)
	Write-Host ('{0,-24} JIT: {1,-14} native: {2,-14} {3}' -f $name, $jit.Text, $native.Text, $note)
}
Write-Host ''
$all = $rows.Count
foreach ($col in @('jit', 'native')) {
	$ok = @($rows | Where-Object { $_.$col -like '✅*' }).Count
	$ng = @($rows | Where-Object { $_.$col -like '❌*' }).Count
	$to = @($rows | Where-Object { $_.$col -like '⏱*' }).Count
	$sk = @($rows | Where-Object { $_.$col -like '⬜*' }).Count
	$only = @($rows | Where-Object { $_.$col -like '☑*' }).Count
	Write-Host ('{0,-6}: 一致 {1} / 不一致・失敗 {2} / 時間切れ {3} / 非対応 {4} / 実行のみ {5} / 全 {6}' -f $col, $ok, $ng, $to, $sk, $only, $all)
}
