param(
    [string]$OutputPath = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'out\RdpUsageTray.exe')
)

$ErrorActionPreference = 'Stop'

$command = Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue
if (-not $command) {
    throw "Invoke-ps2exe was not found. Install PS2EXE on the build PC, then run this script again."
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$inputPath = Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'client\RdpUsageTray.ps1'
Invoke-ps2exe `
    -inputFile $inputPath `
    -outputFile $OutputPath `
    -noConsole `
    -title 'RDP Usage' `
    -description 'RDP usage status and reservation tray app' `
    -company 'Internal' `
    -product 'RDP Usage'

Write-Host "Built $OutputPath"
