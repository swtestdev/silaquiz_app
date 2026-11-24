$Root = $PSScriptRoot
. (Join-Path $Root 'scripts\Get-LanIPv4.ps1')

$api = Join-Path $Root 'server_runner.exe'
$web = Join-Path $Root 'serve_no_cache.exe'

foreach ($exe in @($api, $web)) {
    if (-not (Test-Path $exe)) {
        Write-Error "Missing: $exe"
        exit 1
    }
}

$lan = Get-LanIPv4
if ($lan) {
    Write-Host "LAN IP: $lan"
    Write-Host "Players open: http://${lan}:8080/"
} else {
    Write-Host 'Could not detect LAN IP — use ipconfig and open http://<your-ip>:8080/'
}

Write-Host 'Starting server_runner (port 8000)...'
Start-Process -FilePath $api -WorkingDirectory $Root -WindowStyle Normal

Start-Sleep -Seconds 2

Write-Host 'Starting serve_no_cache (port 8080)...'
Start-Process -FilePath $web -WorkingDirectory $Root -WindowStyle Normal

Write-Host ''
Write-Host 'Leave both console windows open during the game.'
Write-Host 'Stop with Stop-QuzeGame.ps1 or close both windows.'