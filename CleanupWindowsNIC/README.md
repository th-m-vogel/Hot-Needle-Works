# CleanupWindowsNIC — RestoreNet.ps1

Restores static IP configuration on Windows VMs after a virtual hardware upgrade that causes NIC re-enumeration.

## The Problem

When a cloud VM's underlying virtual hardware changes — chipset upgrade, hypervisor migration, machine type switch (e.g. i440fx → q35), or platform migration (e.g. VMware → KVM) — Windows treats the NICs as entirely new devices. It assigns them new connection names ("Ethernet 3", "Ethernet 4", ...) and leaves the originals as hidden ghost adapters.

The ghosts still hold the old static IP configuration. If you try to apply that IP to the new adapter, Windows blocks it:

> *"This IP address is already assigned to another adapter which is no longer present."*

The VM loses network connectivity until the ghost adapters are cleaned up and the static config is transferred.

DHCP-configured VMs recover on their own (they just request a new lease on the new adapter). Static IP VMs don't.

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
- [`devcon.exe`](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/devcon) in PATH for ghost device removal  
  *Alternative (no external dependency):* `pnputil.exe /remove-device` (built-in since Windows 8) or `Remove-PnpDevice` (PowerShell PnpDevice module)

> **Note:** If `devcon` is not available, the script will copy static IP configuration successfully but will fail to remove the ghost adapters. The VM will be reachable, but ghost cleanup will require a manual step or a rerun after installing `devcon`.

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

Running the script without `devcon` (or `pnputil`) available leaves ghost adapters in place. Network connectivity will be restored, but the ghost cleanup step will not complete. A second run after placing `devcon` in PATH will finish the cleanup.

The script does not implement a dry-run or `-WhatIf` mode. Review the output carefully before relying on it in production.

## Background

Originally written for a large-scale KVM platform migration where Windows VMs were moved from VMware ESXi to KVM. The same NIC re-enumeration behaviour appears whenever the virtual chipset or bus topology changes, including:

- VMware ESXi → KVM
- i440fx → q35 machine type upgrades
- Any migration that changes the PCI root bus or ACPI device paths the NICs are addressed through
