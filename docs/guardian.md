# 隐藏守护与任务计划

结构：当前用户 Task Scheduler → `BridgeGuardian.exe --run` → Node 中继。

已有兼容中继可以用 `Upgrade-Guardian.cmd` 单独升级启动管理。它备份启动文件和原中继的核对副本，编译守护，注册计划任务，验证替代入口后删除该安装目录对应的旧 Run 项。不会改模型、认证配置、OpenTypeless 设置或中继业务代码。

| 功能 | 默认值/行为 |
| --- | --- |
| 窗口 | 守护为 Windows GUI subsystem，无控制台；Node 用 CreateNoWindow 启动 |
| 用户身份 | 当前用户 Interactive Token、Limited 权限，不保存 Windows 密码 |
| 开始运行 | 用户登录触发，另有每分钟保底触发 |
| 本地检查 | 每 10 秒访问 `/health`，单次超时 2 秒 |
| 无响应恢复 | 连续 3 次失败后核验身份再重启中继 |
| 退出重试 | 5、15、60 秒等待；持续健康 60 秒后重置 |
| 守护恢复 | 任务失败重试 3 次，间隔一分钟；周期触发作为额外保障 |
| 防重复 | 任务 IgnoreNew + 守护独占文件锁 |
| 运行时限 | PT0S，无三天默认停止限制 |
| 电池 | 允许电池供电启动，不因切换电池停止 |
| 主动暂停 | 持久 `guardian.paused` + 禁用任务；只有显式 Start 清除暂停 |
| 日志 | 仅状态/PID/时间，约 1 MB 时轮换一份 |

默认是在 Windows 用户登录后运行；注销、睡眠、关机时不提供语音服务。这不是系统服务。整机睡眠/重启恢复仍需在使用电脑验收，不能把配置存在当作这些场景已经通过。

日常使用：

```powershell
$bridge=Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'
& (Join-Path $bridge 'Get-BridgeStatus.ps1')
& (Join-Path $bridge 'Stop-Bridge.ps1')
& (Join-Path $bridge 'Start-Bridge.ps1')
```

直接从任务管理器结束 Node/守护会被当作异常退出而恢复。维护请用 Stop：它先记录暂停意图，再停止已核验进程。旧的 `-DisableAutoStart` 参数保留兼容，正常 Stop 已经持久暂停。

守护只管理配置中的 Node 路径和本目录的脚本，核对命令行、所有者 SID 及启动时间。恢复时遇到多个候选进程报告冲突；主动 Stop 则停止该目录所有经过核验的中继。不结束其他 Node 应用。守护退出而 Node 存活时，新守护会接管它，避免重复启动。

任务名称根据安装目录生成；运行状态中的 PID 是动态值，不应硬编码。`guardian-state.json` 的内容是最后观察结果，应结合当前进程数、任务状态与健康接口判断。Azure 登录失效/403/429/断网不属于本地存活失败，守护不循环重启，也不为健康检查调用付费模型。

`-NoAutoStart` 禁用计划任务并手动启动隐藏守护。该模式仍能恢复 Node，但守护自身退出需要手工 Start；不等同于默认的两层恢复。

回滚某次守护升级：

```powershell
.\Rollback-Guardian.ps1 -BackupDirectory '<该次升级输出的 guardian 备份目录>'
```

回滚删除该安装拥有的任务，恢复原启动文件和受管 Run 项，尽量还原原运行/暂停状态。业务代码、模型和认证配置保持原样。备份可能包含本地 Key，只留在本机。运行目录可以包含诊断日志等保留文件；回滚不等于无痕卸载，更不会删除云资源。

参考：[任务设置](https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasksettingsset)、[触发器](https://learn.microsoft.com/powershell/module/scheduledtasks/new-scheduledtasktrigger)、[安全上下文](https://learn.microsoft.com/windows/win32/taskschd/security-contexts-for-running-tasks)、[CreateNoWindow](https://learn.microsoft.com/dotnet/api/system.diagnostics.processstartinfo.createnowindow)。
