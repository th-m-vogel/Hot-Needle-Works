#
# Restore static IP configuration for NIC's after virtual HW upgrade
#
# IONOS, Th.Vogel
#
# Use at your ow risk
#
# What this script does:
# - get list of all KVM PnP devices, including removed devices using Get-PnpDevice
# - get all network adapters matching kvmnet ClassGuid from HKLM:SYSTEM\CurrentControlSet\Control\Network\
# - Build a migration list containg PnP-information, Adapter-UUID, PCI-Info and status
# - for each active NIC:
#   - check if there is a corrosponding missing NIC from same PCI Slot
#   - no: go to next NIC
#   - yes: check if old nic is using DHCP
#     - yes: just cleanup the old nic from system, go to next NIC
#     - no: copy static IP propertes from old NIC, to new NIC, cleanup old nic information, restart NIC to apply configuration
# 

# get unkown NIC's
$kvmadapters = Get-PnpDevice -class net | where Service -eq netkvm | Select Status,FriendlyName,InstanceId,Classguid

if (-not $kvmadapters ) {
    Write-Host "No KVM-Adapters found, nothing to do here"
    exit
}

# ClassGuid for NetKVM
$ClassGuid = $kvmadapters[0].Classguid

# get all NICs
$NICs = Get-ChildItem -Path "HKLM:SYSTEM\CurrentControlSet\Control\Network\$($ClassGuid)" | where { $_.PSChildName -ne "Descriptions" }

# clean array
$Migrate = @()

# find KVM_NICs and create migration list
foreach ($NIC in $NICs ) {
    # get connection details
    $Connection = Get-ItemProperty -Path Registry::$($NIC.Name)\Connection
    # find a KVM Adapter with same PnP information as in connection
    if ($kvmadapter = $kvmadapters | where { $_.InstanceId -eq $Connection.PnPInstanceId }) {

        # get PnP data from gegistry
        $PnP = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$($kvmadapter.InstanceId)"

        # Collect Info
        Write-Host "Found KVM Adapter:"
        Write-Host "- Name:     " $kvmadapter.FriendlyName
        Write-Host "- Status:   " $kvmadapter.Status
        Write-Host "- Instance: " $kvmadapter.InstanceId
        Write-Host "- IF UUID:  " $NIC.PSChildName
        Write-Host "- Slot:     " $PnP.UINumber
        Write-Host

        if ( $kvmadapter.Status -eq "OK" ) {
            $MigInfo = [PSCustomObject]@{
                State = $true
                Slot = $PnP.UINumber
                IfUUID = $NIC.PSChildName
                Instance = $kvmadapter.InstanceId
                Name = $kvmadapter.FriendlyName
            }
        } else {
            $MigInfo = [PSCustomObject]@{
                State = $False
                Slot = $PnP.UINumber
                IfUUID = $NIC.PSChildName
                Instance = $kvmadapter.InstanceId
                Name = $kvmadapter.FriendlyName
            }

        } 
        $Migrate += $MigInfo
    }
}

# Work on Migration List, active present NIC's

$ActiveNics = $Migrate | where { $_.State -eq $true } | Sort -Property Slot

foreach ($NewNic in $ActiveNics ) {

    # check for corosponding old NIC
    if ( $OldNic = $Migrate | where { ($_.State -eq $false ) -and ($_.Slot -eq $NewNic.Slot) } ) {

        # Check Old nic for static config
        $OldTcpIp = Get-ItemProperty -Path "HKLM:SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($OldNic.IfUUID)"

        if ( $OldTcpIp.EnableDHCP ) {
            Write-Host "Old Nic from Slot $($OldNic.Slot) was set to DHCP, nothing to do here beside cleanup"
            # cleanup
            # remove device using devcon
            devcon -r remove "@$($OldNic.Instance)"
            # regitry cleanup at HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces
            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($OldNic.IfUUID)"
            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_  }
            # regitry cleanup at HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Adapters
            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Adapters\$($OldNic.IfUUID)"
            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_  }
        } else { 
            Write-Host "Old Nic from Slot $($OldNic.Slot) was set to STATIC, transfer config"
            foreach ( $Property in @("IPAddress","SubnetMask","DefaultGateway","NameServer","Domain","EnableDHCP")) {
                Write-Host "found Property $Property with value" $OldTcpIp.$Property
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($NewNic.IfUUID)" -Name $Property -Value $OldTcpIp.$Property 
                
            }
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($NewNic.IfUUID)" -Name DhcpIPAddress -Value 255.255.255.255 
            # cleanup
            # remove device using devcon
            devcon -r remove "@$($OldNic.Instance)"
            # regitry cleanup at HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces
            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($OldNic.IfUUID)"
            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_ }
            # regitry cleanup at HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Adapters
            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Adapters\$($OldNic.IfUUID)"
            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | %{ Remove-ItemProperty -Path $RemoveKey -Name $_ }

            # Restart Netadaper to re-initialize
            Write-Host " ... Restart Netadapter " $NewNic.Name
            Restart-NetAdapter -Name (Get-NetAdapter -InterfaceDescription $NewNic.Name).Name 

            
        }
    } else {
        Write-Host "Nothing to migrate for NIC $($NewNic.Name)"
    }
} 


