param(
	[Parameter(Mandatory = $true)][string]$Target,
	[Parameter(Mandatory = $false)][string[]]$Defines = @()
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\env.ps1"

$exe = Join-Path $env:TEMP 'vtext_build.exe'
$buildLog = Join-Path $env:TEMP 'vtext_build.log'
$runLog = Join-Path $env:TEMP 'vtext_run.log'

foreach ($f in @($exe, $buildLog, $runLog)) {
	Remove-Item $f -ErrorAction SilentlyContinue
}

$defineArgs = @()
foreach ($d in $Defines) {
	$defineArgs += @('-d', $d)
}

$quoted = '"' + $env:VEXE + '" -cc gcc ' + ($defineArgs -join ' ') + ' -o "' + $exe + '" ' +
	$Target + ' > "' + $buildLog + '" 2>&1'
cmd /c $quoted
$buildExit = $LASTEXITCODE

if ($buildExit -ne 0) {
	Write-Output "BUILD FAILED (exit $buildExit)"
	Get-Content $buildLog | Select-Object -Last 60
	exit $buildExit
}

# Notices are noise; only surface them when nothing else printed.
$errors = Get-Content $buildLog | Select-String -Pattern '^\S+\.v:\d+:\d+: error'
if ($errors) {
	Write-Output 'BUILD FAILED'
	$errors | Select-Object -First 30 | ForEach-Object { $_.Line }
	exit 1
}

$runCmd = '"' + $exe + '" > "' + $runLog + '" 2>&1'
cmd /c $runCmd
$runExit = $LASTEXITCODE

Write-Output "=== run (exit $runExit) ==="
if (Test-Path $runLog) {
	Get-Content $runLog
} else {
	Write-Output "no output produced; command was: $runCmd"
}
exit $runExit
