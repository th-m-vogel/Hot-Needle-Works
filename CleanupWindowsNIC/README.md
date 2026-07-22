# CleanupWindowsNIC — RestoreNet.ps1

Restores static IP configuration on Windows VMs after a virtual hardware upgrade that causes NIC re-enumeration.

## The Problem

### How Windows handles PnP devices

Windows keeps a detailed and persistent record of every hardware device it has ever detected.
When a present device differs from a previously known device — even slightly — Windows treats
it as a different device entirely. The old device record is retained indefinitely (it may come
back). The new device is initialised with default settings.

This is correct and intentional behaviour for a Plug-and-Play system with dynamic device
handling. It works exactly the same way on physical on-premises hardware: replace a network
card in a Windows server and Windows will enumerate a fresh adapter alongside the ghost of
the old one.

### When virtual hardware changes

Whenever the virtual hardware visible to a Windows guest changes — chipset upgrade,
machine type switch (e.g. i440fx → q35), hypervisor migration (e.g. VMware → KVM), or
any change to the PCI bus topology or ACPI device paths — Windows detects the virtual NICs
as new devices and re-enumerates them with default configuration.

### What you actually see

**Scenario A — DHCP (automatically assigned IP address)**

Impact is minimal. A new adapter appears (e.g. *Ethernet 2* instead of *Ethernet*) with the
same MAC address. It requests an IP via DHCP and comes up on its own. The ghost adapter is
left in the device list as a hidden device.

No manual intervention required.

**Scenario B — Static IP (manually assigned IP address)**

This is the critical case. After the hardware change:

- The original adapter (*Ethernet*) vanishes from the active adapter list
- A new adapter (*Ethernet 2*, or similar) appears, configured for DHCP by default
- The VM loses network connectivity until the static IP is restored on the new adapter

If you access the VM via console and try to manually re-apply the old static IP to the new
adapter, Windows blocks it:

> *"This IP address is already assigned to another adapter which is no longer present."*

The ghost of the old adapter still holds the static configuration and Windows considers
the address already in use. The ghost must be explicitly removed before the IP can be
re-assigned.

DHCP-configured VMs recover on their own. Static IP VMs don't — this script is for them.

## What This Script Does

1. Finds all VirtIO network adapters (KVM/QEMU `netkvm` service), including non-present ghost devices
2. Matches each active NIC to its ghost counterpart **by PCI slot number**
3. For each matched pair:
   - **DHCP NIC:** removes the ghost, nothing else to do
   - **Static NIC:** copies IP address, subnet mask, default gateway, DNS servers, and domain from the ghost to the new adapter; removes the ghost; restarts the adapter
4. Reports "nothing to migrate" for NICs that have no ghost counterpart

**The script is idempotent** — it is safe to run multiple times and safe to run *before* an upgrade (it will find no ghosts and exit cleanly).

## Requirements

- Windows PowerShell (elevated / Administrator)
- VirtIO (KVM/QEMU) network adapters (`netkvm` driver) — the script targets `netkvm` specifically
- No external tools required — ghost device removal uses `Remove-PnpDevice` (built-in PowerShell cmdlet, available since Windows 8 / Server 2012)

## Usage

### Option A — Post-upgrade repair (VM unreachable, access via console)

```powershell
.\RestoreNet.ps1
```

Run this after the VM has been upgraded and is no longer reachable over the network. Access via hypervisor console or out-of-band management.

### Option B — Pre-upgrade "run once on boot" (preferred for live migrations)

This approach allows automatic recovery without console access:

1. Copy `RestoreNet.ps1` to the VM before the upgrade (e.g. `C:\Scripts\RestoreNet.ps1`)
2. Register it as a one-time startup task:

```powershell
$action  = New-ScheduledTaskAction -Execute "powershell.exe" `
               -Argument "-NonInteractive -ExecutionPolicy Bypass -File C:\Scripts\RestoreNet.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName "RestoreNet-RunOnce" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force
```

3. Perform the hardware upgrade
4. The script runs automatically on the first post-upgrade boot and repairs the configuration
5. Remove the scheduled task once verified:

```powershell
Unregister-ScheduledTask -TaskName "RestoreNet-RunOnce" -Confirm:$false
```

## What It Does Not Handle

- **IPv6 static configuration** — only IPv4 (`Tcpip`) parameters are migrated
- **Non-VirtIO NICs** — the script targets `netkvm` (VirtIO) only; e1000 or other virtual NICs are not in scope
- **WINS server configuration** — not included in the property copy
- **DNS suffix search lists** — not included in the property copy
- **Windows Firewall network profiles** — a newly enumerated NIC may default to the Public firewall profile, which can block RDP even when IP connectivity is restored; verify or reset the profile manually if needed

## Known Limitations

The script does not implement a dry-run or `-WhatIf` mode. Review the output carefully before relying on it in production.

## Background

Originally written for a large-scale KVM platform migration where Windows VMs were moved from VMware ESXi to KVM. The same NIC re-enumeration behaviour appears whenever the virtual chipset or bus topology changes, including:

- VMware ESXi → KVM
- i440fx → q35 machine type upgrades
- Any migration that changes the PCI root bus or ACPI device paths the NICs are addressed through
