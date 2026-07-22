#Requires -RunAsAdministrator
#
# Restore static IP configuration for NICs after virtual HW upgrade
#
# IONOS, Th.Vogel
#
# Use at your own risk
#
# What this script does:
# - Get list of all KVM PnP devices, including removed (ghost) devices using Get-PnpDevice
# - Get all network adapters matching kvmnet ClassGuid from HKLM:SYSTEM\CurrentControlSet\Control\Network\
# - Build a migration list containing PnP-information, Adapter-UUID, PCI-Info and status
# - For each active NIC:
#   - Check if there is a corresponding missing (ghost) NIC from same PCI slot
#   - No: nothing to do, go to next NIC
#   - Yes: check if old NIC was using static IP (EnableDHCP -eq 0)
#     - No (DHCP or unconfigured): just clean up the ghost NIC, go to next NIC
#     - Yes (Static): copy static IP properties from old NIC to new NIC,
#       clean up ghost NIC registry entries, restart NIC to apply configuration
#

$ErrorActionPreference = 'Stop'

# Start transcript for post-run review
$LogPath = "$env:TEMP\RestoreNet_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $LogPath
Write-Host "RestoreNet.ps1"
Write-Host "Log: $LogPath"
Write-Host "Started: $(Get-Date)"
Write-Host ""

# Helper: remove ghost NIC device and clean up TCP/IP registry entries
function Remove-GhostNic {
    param(
        [string]$InstanceId,
        [string]$IfUUID
    )
    Write-Host "  Removing ghost device: $InstanceId"
    Remove-PnpDevice -InstanceId $InstanceId -Confirm:$false

    # Registry cleanup: Interfaces
    $InterfaceKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$IfUUID"
    if (Test-Path $InterfaceKey) {
        Get-Item $InterfaceKey | Select-Object -ExpandProperty Property |
            ForEach-Object { Remove-ItemProperty -Path $InterfaceKey -Name $_ }
    }
    # Registry cleanup: Adapters
    $AdapterKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Adapters\$IfUUID"
    if (Test-Path $AdapterKey) {
        Get-Item $AdapterKey | Select-Object -ExpandProperty Property |
            ForEach-Object { Remove-ItemProperty -Path $AdapterKey -Name $_ }
    }
}

try {

    # Get all KVM NICs (active and ghost/removed)
    $kvmadapters = Get-PnpDevice -Class net | Where-Object Service -eq netkvm |
        Select-Object Status, FriendlyName, InstanceId, Classguid

    if (-not $kvmadapters) {
        Write-Host "No KVM adapters found, nothing to do here"
        exit
    }

    # ClassGuid for NetKVM
    $ClassGuid = $kvmadapters[0].Classguid

    # Get all NICs from registry
    $NICs = Get-ChildItem -Path "HKLM:SYSTEM\CurrentControlSet\Control\Network\$ClassGuid" |
        Where-Object { $_.PSChildName -ne "Descriptions" }

    $Migrate = @()

    # Build migration list: match registry NICs to PnP devices by PnPInstanceId
    foreach ($NIC in $NICs) {
        $Connection = Get-ItemProperty -Path Registry::$($NIC.Name)\Connection
        $kvmadapter = $kvmadapters | Where-Object { $_.InstanceId -eq $Connection.PnPInstanceId }
        if (-not $kvmadapter) { continue }

        # Get PnP data from registry to resolve PCI slot number
        $PnP = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$($kvmadapter.InstanceId)"

        Write-Host "Found KVM Adapter:"
        Write-Host "  Name:     $($kvmadapter.FriendlyName)"
        Write-Host "  Status:   $($kvmadapter.Status)"
        Write-Host "  Instance: $($kvmadapter.InstanceId)"
        Write-Host "  IF UUID:  $($NIC.PSChildName)"
        Write-Host "  Slot:     $($PnP.UINumber)"
        Write-Host ""

        $Migrate += [PSCustomObject]@{
            State    = ($kvmadapter.Status -eq "OK")
            Slot     = $PnP.UINumber
            IfUUID   = $NIC.PSChildName
            Instance = $kvmadapter.InstanceId
            Name     = $kvmadapter.FriendlyName
        }
    }

    # Process active NICs, sorted by PCI slot
    $ActiveNics = $Migrate | Where-Object { $_.State -eq $true } | Sort-Object -Property Slot

    foreach ($NewNic in $ActiveNics) {

        # Find corresponding ghost NIC in same PCI slot
        $OldNic = $Migrate | Where-Object { ($_.State -eq $false) -and ($_.Slot -eq $NewNic.Slot) }

        if (-not $OldNic) {
            Write-Host "Nothing to migrate for NIC: $($NewNic.Name)"
            continue
        }

        $OldTcpIpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($OldNic.IfUUID)"
        if (-not (Test-Path $OldTcpIpPath)) {
            Write-Host "  No TCP/IP config found for old NIC - cleanup only"
            Remove-GhostNic -InstanceId $OldNic.Instance -IfUUID $OldNic.IfUUID
            continue
        }
        $OldTcpIp = Get-ItemProperty -Path $OldTcpIpPath

        # EnableDHCP: 0 = static, 1 = DHCP, $null = unconfigured (treat same as DHCP - cleanup only)
        $isStatic = ($null -ne $OldTcpIp.EnableDHCP) -and ([int]$OldTcpIp.EnableDHCP -eq 0)

        if (-not $isStatic) {
            Write-Host "Old NIC from Slot $($OldNic.Slot) was DHCP or unconfigured - cleanup only"
            Remove-GhostNic -InstanceId $OldNic.Instance -IfUUID $OldNic.IfUUID

        } else {
            Write-Host "Old NIC from Slot $($OldNic.Slot) was STATIC - transferring config"
            $NewIfPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($NewNic.IfUUID)"

            # REG_MULTI_SZ properties (arrays of strings)
            foreach ($Property in @("IPAddress", "SubnetMask", "DefaultGateway")) {
                Write-Host "  $Property = $($OldTcpIp.$Property)"
                Set-ItemProperty -Path $NewIfPath -Name $Property -Value $OldTcpIp.$Property -Type MultiString
            }
            # REG_SZ properties
            foreach ($Property in @("NameServer", "Domain")) {
                Write-Host "  $Property = $($OldTcpIp.$Property)"
                Set-ItemProperty -Path $NewIfPath -Name $Property -Value $OldTcpIp.$Property -Type String
            }
            # REG_DWORD: mark as static (Windows manages DhcpIPAddress itself)
            Set-ItemProperty -Path $NewIfPath -Name EnableDHCP -Value 0 -Type DWord

            Remove-GhostNic -InstanceId $OldNic.Instance -IfUUID $OldNic.IfUUID

            # Restart adapter to apply new configuration
            Write-Host "  Restarting adapter: $($NewNic.Name)"
            Restart-NetAdapter -Name (Get-NetAdapter -InterfaceDescription $NewNic.Name).Name
        }
    }

    Write-Host ""
    Write-Host "Done: $(Get-Date)"

} catch {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
} finally {
    Stop-Transcript
}
