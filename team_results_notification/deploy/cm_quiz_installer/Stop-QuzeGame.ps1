$names = @('server_runner', 'serve_no_cache')
foreach ($n in $names) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopping $($_.ProcessName) (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}
Write-Host 'Done.'