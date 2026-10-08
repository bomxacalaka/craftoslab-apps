[CmdletBinding()]
param(
    [ValidateSet('accelerated', 'standard')]
    [string]$Backend = 'standard',

    [ValidateRange(1, 512)]
    [int]$Steps = 256,

    [ValidateRange(0.0, 2.0)]
    [double]$Temperature = 1.0,

    [ValidateRange(0.0, 1.0)]
    [double]$TopP = 0.9,

    [int]$Seed = 1,

    [ValidateRange(1, 100)]
    [int]$BenchmarkRuns = 1,
    [string]$Prompt = ''
)

$projectRoot = Join-Path $PSScriptRoot '..'   # the app root (this script lives in .dev/)
$standardExe = 'C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe'
$acceleratedExe = Join-Path $projectRoot 'tools\craftos-accelerated\CraftOS-PC_console.exe'
$dataDirectory = Join-Path $projectRoot $(if ($Backend -eq 'accelerated') { '.craftos-jit-data' } else { '.craftos-data' })
$executable = if ($Backend -eq 'accelerated') { $acceleratedExe } else { $standardExe }

if (-not (Test-Path -LiteralPath $executable)) {
    throw "CraftOS executable not found: $executable"
}

function ConvertTo-LuaString([string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

$programArguments = @(
    '/lab/llama2.lua',
    '--steps', $Steps.ToString([Globalization.CultureInfo]::InvariantCulture),
    '--temperature', $Temperature.ToString([Globalization.CultureInfo]::InvariantCulture),
    '--topp', $TopP.ToString([Globalization.CultureInfo]::InvariantCulture),
    '--seed', $Seed.ToString([Globalization.CultureInfo]::InvariantCulture),
    '--benchmark-runs', $BenchmarkRuns.ToString([Globalization.CultureInfo]::InvariantCulture)
)
if ($Prompt.Length -gt 0) {
    $promptHex = [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($Prompt))
    $programArguments += @('--prompt-hex', $promptHex)
}
$programArguments += @(
    '--output', '/llama2-output.txt',
    '--metrics', '/llama2-metrics.txt',
    '--quiet'
)
$luaArguments = ($programArguments | ForEach-Object { ConvertTo-LuaString $_ }) -join ', '
$luaCode = "shell.run($luaArguments); os.shutdown()"
$mount = "lab=$projectRoot"

$computerRoot = Join-Path $dataDirectory 'computer\0'
$outputPath = Join-Path $computerRoot 'llama2-output.txt'
$metricsPath = Join-Path $computerRoot 'llama2-metrics.txt'
Remove-Item -LiteralPath $outputPath, $metricsPath -Force -ErrorAction SilentlyContinue

$craftOutput = & $executable --headless --directory $dataDirectory --mount-ro $mount --exec $luaCode 2>&1
if ($LASTEXITCODE -ne 0) { throw "CraftOS exited with code $LASTEXITCODE`n$($craftOutput -join "`n")" }
if (-not (Test-Path -LiteralPath $outputPath) -or -not (Test-Path -LiteralPath $metricsPath)) {
    throw "CraftOS did not produce result files.`n$($craftOutput -join "`n")"
}

[Console]::WriteLine([IO.File]::ReadAllText($outputPath))
Write-Host '---'
Get-Content -LiteralPath $metricsPath
