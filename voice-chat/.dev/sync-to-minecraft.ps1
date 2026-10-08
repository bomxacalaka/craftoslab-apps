[CmdletBinding()]
param(
    [string]$Profile,
    [switch]$Help
)

if ($Help) {
    Write-Host 'Usage: sync-to-minecraft.ps1 [-Profile PATH] [-Help]'
    Write-Host 'Profile resolution: 1) -Profile PATH, 2) CurseForge instance "CraftOS", 3) %USERPROFILE%\.minecraft'
    exit 0
}

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
if ([string]::IsNullOrWhiteSpace($Profile)) {
    $Profile = Join-Path $env:USERPROFILE '.minecraft'
}
if ([string]::IsNullOrWhiteSpace($Profile) -or -not (Test-Path -LiteralPath $Profile)) {
    throw "Minecraft profile not found: $Profile. Pass -Profile with the instance directory."
}
$Profile = (Resolve-Path -LiteralPath $Profile).Path
$Apps = Join-Path $Profile 'cc-apps\apps'
$Destination = Join-Path $Apps 'voice-chat'
$Suffix = [Guid]::NewGuid().ToString('N')
$Staging = Join-Path $Apps ".voice-chat-staging-$Suffix"
$Backup = Join-Path $Apps ".voice-chat-backup-$Suffix"
$LegacyData = Join-Path $Profile 'cc-programs\programs\voice-chat\data'

try {
    New-Item -ItemType Directory -Path $Staging -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Project 'cc-appstore.json') -Destination (Join-Path $Staging 'app.json')
    Copy-Item -LiteralPath (Join-Path $Project 'icon.png') -Destination (Join-Path $Staging 'icon.png')
    $Data = Join-Path $Destination 'data'
    if (Test-Path -LiteralPath $Data) { Move-Item -LiteralPath $Data -Destination (Join-Path $Staging 'data') }
    elseif (Test-Path -LiteralPath $LegacyData) {
        Move-Item -LiteralPath $LegacyData -Destination (Join-Path $Staging 'data')
        Write-Host 'Migrated Voice Chat data from the legacy cc-programs layout'
    }
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $Backup }
    try { Move-Item -LiteralPath $Staging -Destination $Destination }
    catch {
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $Destination }
        throw
    }
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }
} finally {
    if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
}
Write-Host "Synced Phone to $Destination"
