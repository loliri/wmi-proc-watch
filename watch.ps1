#Requires -Version 5.1
<#
.SYNOPSIS
    Watch for the start of one or more processes and log their ancestor chain.

.DESCRIPTION
    Registers a permanent WMI event subscription (__EventFilter +
    ActiveScriptEventConsumer + __FilterToConsumerBinding) in root\subscription.
    The subscription lives in the WMI repository: it survives reboots and keeps
    no process alive.

    The point is to identify what launched a short-lived process. The process
    itself is usually gone by the time you notice it, and its parent may be gone
    too, so the consumer resolves the ancestor chain the moment the event fires.

    Why ActiveScriptEventConsumer instead of CommandLineEventConsumer:
    a consumer is executed by the WMI provider host WmiPrvSE.exe, which runs as
    SYSTEM. Spawning powershell.exe / wscript.exe / cscript.exe from that host
    fails with "Access is denied" (exit code 5) on some systems, so a
    CommandLineEventConsumer produces no output at all. An
    ActiveScriptEventConsumer is interpreted inside the host process and spawns
    nothing, so it is not affected.

.PARAMETER ProcessName
    One or more process names to watch, e.g. reg.exe. Compared exactly and
    case-insensitively against the name reported by Win32_ProcessStartTrace.

.PARAMETER LogPath
    Log file to append to. Defaults to <script directory>\procwatch.log.

.PARAMETER MaxDepth
    How many levels of the ancestor chain to resolve. Default 3, 0 disables it.

.EXAMPLE
    sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe

.EXAMPLE
    sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe,conhost.exe -LogPath C:\Temp\watch.log
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $ProcessName,

    [string] $LogPath,

    [ValidateRange(0, 16)]
    [int] $MaxDepth = 3
)

$ErrorActionPreference = 'Stop'

$ns = 'root\subscription'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
    throw 'Administrator rights are required to register a permanent WMI subscription. Run this script elevated.'
}

if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot 'procwatch.log'
}
$LogPath = [IO.Path]::GetFullPath($LogPath)
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# The consumer script. Written as ASCII only on purpose: it is stored in the WMI
# repository and read back by a host whose default encoding is not UTF-8.
$vbs = @'
Option Explicit

Dim fso, logFile, svc, col, p, pid, ppid, depth

Set fso = CreateObject("Scripting.FileSystemObject")
Set logFile = fso.OpenTextFile("@@LOG@@", 8, True)

pid  = TargetEvent.ProcessID
ppid = TargetEvent.ParentProcessID

logFile.WriteLine "=== " & Now & " ==="
logFile.WriteLine "event    name=" & TargetEvent.ProcessName & " pid=" & pid & " ppid=" & ppid

On Error Resume Next
Set svc = GetObject("winmgmts:\\.\root\cimv2")

Set col = Nothing
Set col = svc.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE ProcessId=" & pid)
If IsObject(col) Then
    For Each p In col
        logFile.WriteLine "target   cmd =" & p.CommandLine
    Next
End If

depth = 0
Do While ppid > 0 And depth < @@MAXDEPTH@@
    Set col = Nothing
    Set col = svc.ExecQuery("SELECT Name,ExecutablePath,CommandLine,ParentProcessId FROM Win32_Process WHERE ProcessId=" & ppid)
    If Not IsObject(col) Then
        logFile.WriteLine "ancestor[" & depth & "] <query failed> pid=" & ppid
        Exit Do
    End If
    If col.Count = 0 Then
        logFile.WriteLine "ancestor[" & depth & "] <gone> pid=" & ppid
        Exit Do
    End If
    For Each p In col
        logFile.WriteLine "ancestor[" & depth & "] name=" & p.Name
        logFile.WriteLine "              path=" & p.ExecutablePath
        logFile.WriteLine "              cmd =" & p.CommandLine
        ppid = p.ParentProcessId
    Next
    depth = depth + 1
Loop

logFile.WriteLine ""
logFile.Close
'@

$script = $vbs.Replace('@@LOG@@', $LogPath).Replace('@@MAXDEPTH@@', [string]$MaxDepth)

$quoted = $ProcessName | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }
$where  = ($quoted | ForEach-Object { "ProcessName=$_" }) -join ' OR '
$query  = "SELECT * FROM Win32_ProcessStartTrace WHERE $where"

$filterName   = 'ProcWatchFilter'
$consumerName = 'ProcWatchConsumer'

# Re-running this script replaces the previous subscription rather than stacking
# a second one, so clear anything that carries our names first.
Get-WmiObject -Namespace $ns -Class __FilterToConsumerBinding -ErrorAction SilentlyContinue |
    Where-Object { $_.Filter -like "*$filterName*" -or $_.Consumer -like "*$consumerName*" } |
    Remove-WmiObject -ErrorAction SilentlyContinue
Get-WmiObject -Namespace $ns -Class __EventConsumer -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$consumerName*" } |
    Remove-WmiObject -ErrorAction SilentlyContinue
Get-WmiObject -Namespace $ns -Class __EventFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$filterName*" } |
    Remove-WmiObject -ErrorAction SilentlyContinue

$filter = Set-WmiInstance -Namespace $ns -Class __EventFilter -Arguments @{
    Name           = $filterName
    EventNamespace = 'root\cimv2'
    QueryLanguage  = 'WQL'
    Query          = $query
}

$consumer = Set-WmiInstance -Namespace $ns -Class ActiveScriptEventConsumer -Arguments @{
    Name            = $consumerName
    ScriptingEngine = 'VBScript'
    ScriptText      = $script
}

Set-WmiInstance -Namespace $ns -Class __FilterToConsumerBinding -Arguments @{
    Filter   = $filter
    Consumer = $consumer
} | Out-Null

Write-Host "Watching : $($ProcessName -join ', ')"
Write-Host "Log file : $LogPath"
Write-Host "Query    : $query"
Write-Host ""
Write-Host "Registered:"
Write-Host "  $($filter.Path.Path)"
Write-Host "  $($consumer.Path.Path)"
Write-Host ""
Write-Host "Remove it again with: unwatch.ps1"
