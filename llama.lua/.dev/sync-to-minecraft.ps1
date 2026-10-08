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
$Profile = (Resolve-Path -LiteralPath $Profile).Path
$Apps = Join-Path $Profile 'cc-apps\apps'
$Destination = Join-Path $Apps 'llama-lua'
$Suffix = [Guid]::NewGuid().ToString('N')
$Staging = Join-Path $Apps ".llama-lua-staging-$Suffix"
$Backup = Join-Path $Apps ".llama-lua-backup-$Suffix"
$LegacyData = Join-Path $Profile 'cc-programs\programs\llama-lua\data'

try {
    New-Item -ItemType Directory -Path (Join-Path $Staging 'models') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Project 'llama2.lua') -Destination (Join-Path $Staging 'llama2.lua')
    Copy-Item -LiteralPath (Join-Path $Project 'models\tok512.bin') -Destination (Join-Path $Staging 'models\tok512.bin')
    Copy-Item -LiteralPath (Join-Path $Project 'models\stories260K.bin') -Destination (Join-Path $Staging 'models\stories260K.bin')
    Copy-Item -LiteralPath (Join-Path $Project 'cc-appstore.json') -Destination (Join-Path $Staging 'app.json')
    Copy-Item -LiteralPath (Join-Path $Project 'icon.png') -Destination (Join-Path $Staging 'icon.png')
    $Data = Join-Path $Destination 'data'
    if (Test-Path -LiteralPath $Data) { Move-Item -LiteralPath $Data -Destination (Join-Path $Staging 'data') }
    elseif (Test-Path -LiteralPath $LegacyData) {
        Move-Item -LiteralPath $LegacyData -Destination (Join-Path $Staging 'data')
        Write-Host 'Migrated Llama data from the legacy cc-programs layout'
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
Write-Host "Synced llama.lua to $Destination"
