param(
	[Parameter(Mandatory = $false)][string]$Filter = ''
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\env.ps1"

$log = Join-Path $env:TEMP 'vtext_test.log'
Remove-Item $log -ErrorAction SilentlyContinue

$files = Get-ChildItem $PSScriptRoot -Filter '*_test.v' -File | ForEach-Object { $_.Name }
if ($Filter -ne '') {
	$files = $files | Where-Object { $_ -like "*$Filter*" }
}
if ($files.Count -eq 0) {
	Write-Output 'no test files matched'
	exit 1
}

$quoted = '"' + $env:VEXE + '" -cc gcc test ' + ($files -join ' ') + ' > "' + $log +
	'" 2>&1'
cmd /c $quoted
$exit = $LASTEXITCODE

if (Test-Path $log) {
	# Notices about unused constants are noise while a milestone is in flight.
	Get-Content $log | Where-Object { $_ -notmatch 'notice:' }
}
exit $exit
