param(
    [string] $RootPassword = '19761982',
    [string] $PackageRoot
)

. (Join-Path $PSScriptRoot 'Find-MySqlExe.ps1')

if (-not $PackageRoot) {
    $PackageRoot = Split-Path $PSScriptRoot -Parent
}

function Test-MySqlLogin {
    param([string] $MysqlExe)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MysqlExe
    $psi.Arguments = "-u root -p$RootPassword -h 127.0.0.1 -P 3306 -e `"SELECT 1`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    return ($p.ExitCode -eq 0)
}

$mysql = Find-MySqlExe
if ($mysql -and (Test-MySqlLogin -MysqlExe $mysql)) {
    Write-Host 'MySQL is running and root password works.'
    return $true
}

$svc = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
if (-not $svc) {
    $svcStopped = Get-Service -Name 'MySQL*' -ErrorAction SilentlyContinue
    if ($svcStopped) {
        Write-Host 'Starting MySQL service...'
        $svcStopped | Start-Service -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $mysql = Find-MySqlExe
        if ($mysql -and (Test-MySqlLogin -MysqlExe $mysql)) { return $true }
    }
}

$installerDir = Join-Path $PackageRoot 'mysql\installer'
$msi = Get-ChildItem -Path $installerDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($msi) {
    Write-Host "Running bundled installer: $($msi.Name)"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$($msi.FullName)`" /quiet /norestart" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Warning "MSI exit code: $($proc.ExitCode). Complete MySQL setup manually."
    } else {
        Start-Sleep -Seconds 5
        $mysql = Find-MySqlExe
        if ($mysql -and (Test-MySqlLogin -MysqlExe $mysql)) { return $true }
    }
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    Write-Host 'Attempting: winget install Oracle.MySQL (may require interaction)...'
    winget install --id Oracle.MySQL -e --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
    Start-Sleep -Seconds 3
    $mysql = Find-MySqlExe
    if ($mysql -and (Test-MySqlLogin -MysqlExe $mysql)) { return $true }
}

Write-Warning 'MySQL is not ready with the configured root password.'
Write-Host 'Install MySQL, set root password to match .env (see INSTALL.md), then run Install-CMQuiz.ps1 again.'
return $false