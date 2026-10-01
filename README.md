# wmi-proc-watch

Watch for the start of a given process and log its full ancestor chain.

Built for chasing down "what launched this process that appeared for a split second and vanished". By the time you notice the window, the process is gone, its parent may be gone too, and Task Scheduler / the registry show nothing. This tool catches it at the moment it starts.

📖 README: **English** | [中文](README_CN.md)

## How it works

It registers a **permanent WMI event subscription** matching `Win32_ProcessStartTrace` for the target process name.

The subscription is stored in the WMI repository (`root\subscription`) as three objects managed by the `Winmgmts` service:

- `__EventFilter` — the match condition
- `ActiveScriptEventConsumer` — the script to run on a match
- `__FilterToConsumerBinding` — binds the two together

It is a **persistent object**, not a resident process. Nothing stays running after registration; it survives reboots and WMI service restarts, and costs nothing while idle. Only when the target process actually starts does the system spin up a `WmiPrvSE.exe` host to run the script.

The script reads the process table the instant the event fires, so it captures the **parent's full command line** and further up the chain — exactly what post-mortem investigation cannot recover.

## Requirements

- Windows 10 / 11
- PowerShell 5.1 or later
- **Administrator rights** (required to register a permanent WMI subscription)

## Usage

Register (run elevated, e.g. with `sudo`):

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe
```

Watch several processes at once:

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe,conhost.exe
```

Custom log path and ancestor depth:

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName cmd.exe -LogPath C:\Temp\watch.log -MaxDepth 5
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-ProcessName` | required | Process name(s) to watch |
| `-LogPath` | `<script dir>\procwatch.log` | Log file, appended to |
| `-MaxDepth` | `3` | Ancestor levels to resolve; `0` disables |

Once registered, leave it alone. The log keeps growing until you remove the subscription — there is no entry limit.

Remove:

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\unwatch.ps1
```

The log file is not deleted; clean it up yourself if you want.

## Output

```
=== 2026/10/1 20:12:07 ===
event    name=reg.exe pid=33920 ppid=41116
ancestor[0] name=powershell.exe
              path=C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe
              cmd =C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "..."
ancestor[1] name=bash.exe
              path=C:\Programs\Git\bin\..\usr\bin\bash.exe
              cmd ="C:\Programs\Git\bin\..\usr\bin\bash.exe" -c "..."
```

The `event` line is the target process itself; `ancestor[0]` is its parent, then grandparent, and so on.

## Two implementation gotchas

These are the main reason this tool exists — neither is easy to find documented.

### 1. `CommandLineEventConsumer` does not work here

The obvious approach is a `CommandLineEventConsumer` invoking `powershell.exe` or `wscript.exe`. **On some systems this produces no output at all.**

The consumer is executed by `WmiPrvSE.exe`, which runs as **SYSTEM**. Spawning `powershell.exe` / `wscript.exe` / `cscript.exe` from that identity fails with `Access is denied` (exit code 5) — the command never runs.

Note this is unrelated to the privilege you registered with. Registering as an administrator only decides whether you may *write* to the repository; it has nothing to do with the identity the script later *runs* as. At trigger time the system service starts a separate host, as SYSTEM.

This tool therefore uses an **`ActiveScriptEventConsumer`**: VBScript is interpreted inside the host process itself, spawning nothing, so the restriction does not apply.

> Note: the exact root cause of the denial under SYSTEM was not investigated. The above is the reproducible symptom, not the reason.

### 2. The ancestor chain must be captured the instant the event arrives

`Win32_ProcessStartTrace` carries only `ProcessID` / `ParentProcessID` / `ProcessName` / `SessionID` — no command line. The command line has to be looked up in `Win32_Process` separately.

The target process often exits within tens of milliseconds, and its parent can be just as short-lived. So the script must query the process table **immediately** in the event callback; a moment later there is nothing left but a `ParentProcessID` number.

Even so, if the parent has already exited by the time the event arrives, all you get is `<gone> pid=...`. The `ParentProcessID` is still there, at least, and can be followed up by other means.

## Security notice

The mechanism this tool uses — **WMI event subscription persistence** — maps to MITRE ATT&CK [T1546.003 (Windows Management Instrumentation Event Subscription)](https://attack.mitre.org/techniques/T1546/003/), a well-known attacker persistence technique.

Therefore:

- **Some antivirus / EDR products will flag it as suspicious persistence**, or block it outright. That is expected behaviour, not a false positive — the mechanism is genuinely abused this way.
- Treat it as a **diagnostic tool**: remove it when you are done, do not leave it registered long-term.
- `unwatch.ps1` removes it completely; nothing is left behind.

The registered objects are always named `ProcWatchFilter` / `ProcWatchConsumer`, so they are easy to spot and clean up.

## Limitations

- Only process **start** events are captured, not exit.
- Matches on process name only — not command line or path. Same-named processes (several `cmd.exe`) are all recorded.
- The ancestor chain depends on the parent still being alive when the event arrives; short-lived parents are lost.
- No automatic log rotation. Watch the size if you leave it running.
