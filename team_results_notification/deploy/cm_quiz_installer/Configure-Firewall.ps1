#Requires -RunAsAdministrator
$rules = @(
    @{ Name = 'CM_Quiz API 8000'; Port = 8000 },
    @{ Name = 'CM_Quiz Web 8080'; Port = 8080 }
)

foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Firewall rule already exists: $($r.Name)"
        continue
    }
    New-NetFirewallRule -DisplayName $r.Name `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $r.Port `
        -Profile Private | Out-Null
    Write-Host "Added firewall rule: $($r.Name) (TCP $($r.Port), Private)"
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Run as Administrator to create firewall rules.'
}