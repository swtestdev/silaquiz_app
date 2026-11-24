function Find-MySqlExe {
    $candidates = @(
        'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe',
        'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
        'C:\Program Files\MySQL\MySQL Server 5.7\bin\mysql.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command mysql -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}