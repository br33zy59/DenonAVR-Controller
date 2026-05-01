#Requires -Version 5.1
# Build DenonAVR.exe with ps2exe. Install module once: Install-Module ps2exe -Scope CurrentUser
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$InputFile   = Join-Path $ProjectRoot 'src\DenonAVR.standalone.ps1'
$OutputDir   = Join-Path $ProjectRoot 'release'
$IconFile    = Join-Path $ProjectRoot 'assets\DenonAVR.ico'
$OutputFile  = Join-Path $OutputDir 'DenonAVR.exe'

Import-Module ps2exe -ErrorAction Stop
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try {
    Invoke-PS2EXE `
        -InputFile $InputFile `
        -OutputFile $OutputFile `
        -NoConsole `
        -STA `
        -Title 'Denon AVR Controller' `
        -IconFile $IconFile
    Write-Host ("Built: " + $OutputFile)
}
finally {
    $ErrorActionPreference = $prevEap
}
