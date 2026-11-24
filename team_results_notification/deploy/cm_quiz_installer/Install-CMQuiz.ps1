#Requires -Version 5.1
param(
    [string] $TargetDir = '',
    [string] $MySqlRootPassword = '19761982',
    [switch] $SkipMySQL,
    [switch] $SkipFirewall,
    [switch] $ForceEnv
)

$ErrorActionPreference = 'Stop'
$SourceDir = $PSScriptRoot
if (-not $TargetDir) { $TargetDir = $SourceDir }

. (Join-Path $SourceDir 'scripts\Get-LanIPv4.ps1')

Write-Host ''
Write-Host '=== CM_Quiz / Quze installer ==='
Write-Host "Source: $SourceDir"
Write-Host "Target: $TargetDir"
Write-Host ''

if ($SourceDir -ne $TargetDir) {
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    $exclude = @('mysql\installer')
    robocopy $SourceDir $TargetDir /E /XO /NFL /NDL /NJH /NJS /NC /NS |
        Out-Null
    Write-Host 'Files copied to target directory.'
    $PackageRoot = $TargetDir
} else {
    $PackageRoot = $SourceDir
}

if (-not $SkipMySQL) {
    $ensureScript = Join-Path $PackageRoot 'scripts\Ensure-MySQL.ps1'
    $setupScript = Join-Path $PackageRoot 'scripts\Setup-Database.ps1'
    $null = & $ensureScript -RootPassword $MySqlRootPassword -PackageRoot $PackageRoot
    $null = & $setupScript -RootPassword $MySqlRootPassword -PackageRoot $PackageRoot
}

$lanIp = Get-LanIPv4
if (-not $lanIp) {
    $lanIp = '192.168.0.100'
    Write-Warning "Could not detect LAN IP; using placeholder $lanIp in CORS_ORIGINS."
}

$cors = "http://${lanIp}:8080"
$template = Join-Path $PackageRoot 'env\.env.template'
$envPath = Join-Path $PackageRoot '.env'

if ($ForceEnv -or -not (Test-Path $envPath)) {
    $secretBytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secretBytes)
    $secret = [Convert]::ToBase64String($secretBytes)

    $templateText = Get-Content $template -Raw
    $text = $templateText `
        -replace 'REPLACE_WITH_RANDOM_SECRET', $secret `
        -replace 'http://192\.168\.0\.100:8080', $cors
    Set-Content -Path $envPath -Value $text.TrimEnd() -Encoding UTF8
    Write-Host "Wrote .env (CORS_ORIGINS=$cors)"
} else {
    Write-Host '.env already exists; keeping it (use -ForceEnv to regenerate).'
}

if (-not $SkipFirewall) {
    $fwScript = Join-Path $PackageRoot 'Configure-Firewall.ps1'
    if (Test-Path $fwScript) {
        & $fwScript
    }
}

foreach ($required in @('server_runner.exe', 'serve_no_cache.exe')) {
    $p = Join-Path $PackageRoot $required
    if (-not (Test-Path $p)) {
        Write-Warning "Missing: $required - copy binaries into the package folder."
    }
}

$webIndex = Join-Path $PackageRoot 'web\index.html'
if (-not (Test-Path $webIndex)) {
    Write-Warning 'Missing web\index.html - deploy Flutter build into web folder'
} else {
    $ck = Join-Path $PackageRoot 'web\canvaskit\canvaskit.js'
    if (-not (Test-Path $ck)) {
        Write-Warning 'Missing web\canvaskit\ - rebuild with: flutter build web --release --no-web-resources-cdn'
    }
}

Write-Host ''
Write-Host 'Install finished.'
$playerUrl = 'http://' + $lanIp + ':8080/'
Write-Host "Player URL (after start): $playerUrl"
Write-Host 'Next: run Start-QuzeGame.bat'
Write-Host ''