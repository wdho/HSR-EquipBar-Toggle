[CmdletBinding()]
param(
    [string]$Gcc,
    [string]$Objdump
)

$ErrorActionPreference = 'Stop'
$tools = @{}
if ($Gcc) { $tools.Gcc = $Gcc }
if ($Objdump) { $tools.Objdump = $Objdump }

& (Join-Path $PSScriptRoot 'build.ps1') @tools

$out = Join-Path $PSScriptRoot 'out'
$guideName = -join ([char[]](0x4f7f, 0x7528, 0x8bf4, 0x660e))
$files = @(
    (Join-Path $out 'xluau.dll')
    (Join-Path $PSScriptRoot 'lua/EquipBarScript.lua')
    (Join-Path $PSScriptRoot 'README.md')
    (Join-Path $PSScriptRoot 'LICENSE')
    (Join-Path $PSScriptRoot 'CHANGELOG.md')
    (Join-Path $PSScriptRoot ($guideName + '.md'))
)
$archive = Join-Path $out 'HSR-EquipBar-Toggle.zip'
Compress-Archive -LiteralPath $files -DestinationPath $archive -Force
Write-Host "Package: $archive"
