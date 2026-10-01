# wmi-proc-watch

监视指定进程的启动，并记录它完整的祖先链。

用于追查「一个一闪而过的进程到底是谁拉起来的」——比如某个程序偶尔弹出一个黑框，进程几十毫秒就退出了，事后查进程表、查计划任务都找不到来源。

📖 README: [English](README.md) | **中文**

## 原理

向 WMI 注册一个**永久事件订阅**，条件是 `Win32_ProcessStartTrace` 里出现目标进程名。

订阅以三个对象的形式存在 WMI 仓库（`root\subscription`）里，由系统服务 `Winmgmts` 托管：

- `__EventFilter` —— 匹配条件
- `ActiveScriptEventConsumer` —— 命中后执行的脚本
- `__FilterToConsumerBinding` —— 把上面两者绑起来

它是**持久对象**，不是常驻进程：注册完就没了运行时进程，重启电脑、重启 WMI 服务都不丢，平时零开销。只有目标进程真正启动的那一刻，系统才拉一个 `WmiPrvSE.exe` 宿主来跑脚本。

脚本在事件触发的瞬间读取进程表，因此能拿到**父进程乃至更上层的完整命令行**——这是事后排查拿不到的东西。

## 环境要求

- Windows 10 / 11
- PowerShell 5.1 或更高
- **管理员权限**（注册永久 WMI 订阅必需）

## 用法

注册（用 `sudo` 或任意提权方式运行）：

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe
```

监视多个进程：

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName reg.exe,conhost.exe
```

自定义日志路径与祖先链深度：

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\watch.ps1 -ProcessName cmd.exe -LogPath C:\Temp\watch.log -MaxDepth 5
```

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ProcessName` | 必填 | 要监视的进程名，可传多个 |
| `-LogPath` | `<脚本目录>\procwatch.log` | 日志文件，追加写入 |
| `-MaxDepth` | `3` | 向上追溯的祖先层数，`0` 表示不追溯 |

注册后就可以不管了。日志会一直追加，直到你手动卸载——没有条数上限。

卸载：

```powershell
sudo powershell -NoProfile -ExecutionPolicy Bypass -File .\unwatch.ps1
```

日志文件不会被删除，需要的话自己清理。

## 输出示例

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

`event` 行是目标进程本身，`ancestor[0]` 是它的父进程，往上依次是祖父、曾祖父。

## 两个实现上的坑

这两点是这个工具存在的主要价值，网上不太容易搜到。

### 1. 不能用 `CommandLineEventConsumer`

最直觉的做法是用 `CommandLineEventConsumer` 直接调 `powershell.exe` 或 `wscript.exe` 跑脚本。**但在部分系统上这完全不会产生任何输出。**

原因是消费者由 `WmiPrvSE.exe` 执行，而该宿主进程以 **SYSTEM** 身份运行。从 SYSTEM 身份去 spawn `powershell.exe` / `wscript.exe` / `cscript.exe` 会直接返回 `Access is denied`（退出码 5），命令根本没跑起来。

注意这与注册时的权限无关：注册时你用的是管理员身份，但那只决定「能不能往仓库里写」，跟「运行时以什么身份执行」是两回事。事件触发时是系统服务另起宿主，身份是 SYSTEM。

本工具改用 **`ActiveScriptEventConsumer`**：VBScript 在宿主进程内直接解释执行，不 spawn 任何子进程，因此不受该限制。

> 补充：在 SYSTEM 身份下 spawn 上述解释器被拒的确切根因未经查证。上面写的是可复现的现象，不是原因。

### 2. 祖先链必须在事件到达的瞬间抓

`Win32_ProcessStartTrace` 只带 `ProcessID` / `ParentProcessID` / `ProcessName` / `SessionID`，没有命令行。命令行得自己去 `Win32_Process` 查。

而目标进程往往几十毫秒就退出，父进程也可能一样短命。所以脚本必须在事件回调里**立刻**查进程表，晚一步就只剩一个 `ParentProcessID` 数字。

即使这样，如果父进程在事件到达前就已经退出，仍然只能记到 `<gone> pid=...`。这种情况下 `ParentProcessID` 至少还在，可以配合其他手段继续查。

## 安全说明

这个工具使用的机制——**WMI 事件订阅持久化**——对应 MITRE ATT&CK 的 [T1546.003 (Windows Management Instrumentation Event Subscription)](https://attack.mitre.org/techniques/T1546/003/)，是攻击者常用的持久化手法之一。

因此：

- **部分杀毒软件 / EDR 会把它标记为可疑持久化**，甚至直接拦截。这是预期行为，不是误报——机制本身就是这样被滥用的。
- 请把它当**诊断工具**使用：用完即卸，不要长期挂着。
- 注册后可以用 `unwatch.ps1` 完全清除，订阅不残留。

注册的对象名称固定为 `ProcWatchFilter` / `ProcWatchConsumer`，便于识别和清理。

## 局限

- 只捕获进程**启动**事件，不捕获退出。
- 只监视进程名，不匹配命令行内容或路径。同名进程（如多个 `cmd.exe`）会全部记录。
- 祖先链依赖父进程在事件到达时仍存活，短命父进程会丢失。
- 日志无自动轮转，长期挂着请自行注意体积。
