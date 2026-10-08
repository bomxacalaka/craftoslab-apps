[CmdletBinding()]
param([string]$Profile)

$ErrorActionPreference = 'Stop'
$Project = Join-Path $PSScriptRoot '..'   # the app root (this script lives in .dev/)
if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Instances = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'
    if (Test-Path -LiteralPath $Instances) {
        $Profile = Get-ChildItem -LiteralPath $Instances -Directory |
            Where-Object { $_.Name -ieq 'CraftOS' } |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if ([string]::IsNullOrWhiteSpace($Profile) -or -not (Test-Path -LiteralPath $Profile)) {
    throw "CurseForge profile 'CraftOS' was not found. Pass -Profile with the instance directory."
}
$Model = Join-Path $Project 'model\letters.bin'
if (-not (Test-Path -LiteralPath $Model)) { throw 'Missing model\letters.bin. Train or restore the model first.' }
$DigitModel = Join-Path $Project 'model\digits.bin'
if (-not (Test-Path -LiteralPath $DigitModel)) { throw 'Missing model\digits.bin. Train or restore the model first.' }
$LlamaProject = Join-Path $Project 'llama'
if (-not (Test-Path -LiteralPath (Join-Path $LlamaProject 'llama2.lua'))) {
    $LlamaProject = Join-Path (Split-Path -Parent $Project) 'llama.lua'
}
$LlamaProgram = Join-Path $LlamaProject 'llama2.lua'
$LlamaModel = Join-Path $LlamaProject 'models\stories260K.bin'
$LlamaTokenizer = Join-Path $LlamaProject 'models\tok512.bin'
foreach ($Required in @($LlamaProgram, $LlamaModel, $LlamaTokenizer)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Missing Llama asset: $Required (refresh the in-tree llama/ copy with tools\update-llama.sh)"
    }
}
$Profile = (Resolve-Path -LiteralPath $Profile).Path
$Apps = Join-Path $Profile 'cc-apps\apps'
$Destination = Join-Path $Apps 'draw-ocr'
$Suffix = [Guid]::NewGuid().ToString('N')
$Staging = Join-Path $Apps ".draw-ocr-staging-$Suffix"
$Backup = Join-Path $Apps ".draw-ocr-backup-$Suffix"
$LegacyData = Join-Path $Profile 'cc-programs\programs\draw-ocr\data'

try {
    New-Item -ItemType Directory -Path (Join-Path $Staging 'model') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Staging 'llama\models') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Project 'ocr.lua') -Destination (Join-Path $Staging 'ocr.lua')
    Copy-Item -LiteralPath $Model -Destination (Join-Path $Staging 'model\letters.bin')
    Copy-Item -LiteralPath $DigitModel -Destination (Join-Path $Staging 'model\digits.bin')
    Copy-Item -LiteralPath $LlamaProgram -Destination (Join-Path $Staging 'llama\llama2.lua')
    Copy-Item -LiteralPath $LlamaModel -Destination (Join-Path $Staging 'llama\models\stories260K.bin')
    Copy-Item -LiteralPath $LlamaTokenizer -Destination (Join-Path $Staging 'llama\models\tok512.bin')
    Copy-Item -LiteralPath (Join-Path $Project 'cc-appstore.json') -Destination (Join-Path $Staging 'app.json')
    Copy-Item -LiteralPath (Join-Path $Project 'icon.png') -Destination (Join-Path $Staging 'icon.png')
    $Data = Join-Path $Destination 'data'
    if (Test-Path -LiteralPath $Data) { Move-Item -LiteralPath $Data -Destination (Join-Path $Staging 'data') }
    elseif (Test-Path -LiteralPath $LegacyData) {
        Move-Item -LiteralPath $LegacyData -Destination (Join-Path $Staging 'data')
        Write-Host 'Migrated Draw OCR data from the legacy cc-programs layout'
    }
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $Backup }
    try { Move-Item -LiteralPath $Staging -Destination $Destination }
    catch {
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $Destination }
        $StagedData = Join-Path $Staging 'data'
        if ((Test-Path -LiteralPath $StagedData) -and -not (Test-Path -LiteralPath (Join-Path $Destination 'data'))) {
            Move-Item -LiteralPath $StagedData -Destination (Join-Path $Destination 'data')
        }
        throw
    }
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
} finally {
    if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
}
Write-Host "Synced Draw OCR to $Destination"
