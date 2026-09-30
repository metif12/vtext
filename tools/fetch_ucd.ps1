param(
	[Parameter(Mandatory = $false)][string]$Version = '18.0.0'
)

# Fetches the Unicode Character Database files the generator and the tests read.
#
# The generated tables in ucd_*.v are committed, so a normal build never needs
# these files. Only regenerating the tables (v run tools/gen_tables.v) and the
# UCD comparison tests do, which is why the large conformance files are not
# committed either.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ucd = Join-Path $root 'ucd'
New-Item -ItemType Directory -Path $ucd -Force | Out-Null

$base = "https://www.unicode.org/Public/$Version/ucd"
$emoji = "https://www.unicode.org/Public/16.0.0/ucd/emoji"

$files = @(
	"$base/ArabicShaping.txt"
	"$base/CompositionExclusions.txt"
	"$base/DerivedNormalizationProps.txt"
	"$base/NormalizationTest.txt"
	"$base/LineBreak.txt"
	"$base/PropertyValueAliases.txt"
	"$base/Scripts.txt"
	"$base/UnicodeData.txt"
	"$base/BidiTest.txt"
	"$base/BidiCharacterTest.txt"
	"$base/extracted/DerivedBidiClass.txt"
	"$base/extracted/DerivedCombiningClass.txt"
	"$base/extracted/DerivedGeneralCategory.txt"
	"$base/extracted/DerivedJoiningGroup.txt"
	"$base/extracted/DerivedJoiningType.txt"
	"$base/auxiliary/GraphemeBreakProperty.txt"
	"$base/auxiliary/GraphemeBreakTest.txt"
	"$base/auxiliary/WordBreakProperty.txt"
	"$emoji/emoji-data.txt"
)

foreach ($url in $files) {
	$dest = Join-Path $ucd (Split-Path $url -Leaf)
	$code = curl.exe -s -o $dest -w '%{http_code}' $url
	if ($code -ne '200') {
		Write-Warning "failed ($code): $url"
	} else {
		$kb = [int]((Get-Item $dest).Length / 1KB)
		Write-Host ("{0,4} {1,7} KB  {2}" -f $code, $kb, (Split-Path $url -Leaf))
	}
}

Write-Host ''
Write-Host "Unicode $Version data is in $ucd"
Write-Host 'Regenerate the tables with:'
Write-Host '  v run tools/gen_tables.v'
Write-Host '  v run tools/gen_normalization.v'
