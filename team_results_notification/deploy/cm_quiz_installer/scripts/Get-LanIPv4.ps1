function Get-LanIPv4 {
    $n = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Virtual|Docker|WSL|Bluetooth'
        } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1

    if ($n) { return $n.IPAddress.Trim() }

    foreach ($line in (ipconfig | Select-String 'IPv4')) {
        if ($line -match ':\s*(\d+\.\d+\.\d+\.\d+)') {
            $ip = $Matches[1]
            if ($ip -notlike '127.*' -and $ip -notlike '169.254.*') { return $ip }
        }
    }
    return $null
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-LanIPv4
}