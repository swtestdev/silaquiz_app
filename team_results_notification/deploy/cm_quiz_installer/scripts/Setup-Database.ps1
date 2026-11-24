param(
    [string] $RootPassword = '19761982',
    [string] $PackageRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Find-MySqlExe.ps1')

if (-not $PackageRoot) {
    $PackageRoot = Split-Path $PSScriptRoot -Parent
}

$sqlFile = Join-Path $PackageRoot 'sql\01-create-database.sql'
$mysql = Find-MySqlExe

if (-not $mysql) {
    Write-Warning 'mysql.exe not found. Install MySQL and re-run Install-CMQuiz.ps1'
    return $false
}
if (-not (Test-Path $sqlFile)) {
    Write-Warning "SQL file not found: $sqlFile"
    return $false
}

$sql = Get-Content $sqlFile -Raw
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $mysql
$psi.Arguments = "-u root -p$RootPassword -h 127.0.0.1 -P 3306"
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.Write($sql)
$p.StandardInput.Close()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit()

if ($p.ExitCode -ne 0) {
    Write-Warning "MySQL setup failed (exit $($p.ExitCode))."
    if ($err.Trim()) { Write-Warning $err.Trim() }
    Write-Host 'See INSTALL.md - set root password, then re-run Setup-Database.ps1'
    return $false
}

Write-Host 'Database game_sila_misly is ready.'
if ($out.Trim()) { Write-Host $out.Trim() }
return $true