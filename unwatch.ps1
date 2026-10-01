#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the WMI subscription registered by watch.ps1.

.DESCRIPTION
    Deletes the __EventFilter, ActiveScriptEventConsumer and
    __FilterToConsumerBinding created by watch.ps1, returning the
    root\subscription namespace to its original state.

    The log file is left alone. Delete it yourself if you no longer want it.

.EXAMPLE
    sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\unwatch.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ns = 'root\subscription'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    throw 'Administrator rights are required to remove a permanent WMI subscription. Run this script elevated.'
}

$filterName   = 'ProcWatchFilter'
$consumerName = 'ProcWatchConsumer'

$removed = 0

Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding |
    Where-Object { $_.Filter -like "*$filterName*" -or $_.Consumer -like "*$consumerName*" } |
    ForEach-Object {
        Write-Host "removing binding : $($_.__PATH)"
        $_.Delete()
        $removed++
    }

Get-WmiObject -Namespace $ns -Class __EventConsumer |
    Where-Object { $_.Name -like "$consumerName*" } |
    ForEach-Object {
        Write-Host "removing consumer: $($_.__PATH)"
        $_.Delete()
        $removed++
    }

Get-WmiObject -Namespace $ns -Class __EventFilter |
    Where-Object { $_.Name -like "$filterName*" } |
    ForEach-Object {
        Write-Host "removing filter  : $($_.__PATH)"
        $_.Delete()
        $removed++
    }

if ($removed -eq 0) {
    Write-Host 'Nothing to remove - no ProcWatch subscription was registered.'
} else {
    Write-Host ""
    Write-Host "Removed $removed object(s)."
}

Write-Host ""
Write-Host 'Remaining subscriptions in root\subscription:'
Get-WmiObject -Namespace $ns -Class __EventFilter |
    ForEach-Object { Write-Host "  filter   $($_.Name)" }
Get-WmiObject -Namespace $ns -Class __EventConsumer |
    ForEach-Object { Write-Host "  consumer $($_.__CLASS) $($_.Name)" }
