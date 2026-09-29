# 故障排查

| 现象 | 操作 |
| --- | --- |
| 本地 profile 不存在或仍有占位符 | 运行 Initialize-Profile，或先完成从零 Azure 指南；公共示例不能直接推理 |
| Azure Plan 成功，Check 失败 | Plan 不访问云；看具体登录、区域、模型、订阅或权限错误 |
| Provider 未注册 | 由有权限的人在订阅注册 Microsoft.CognitiveServices，再 Check |
| 模型版本/SKU 不可用 | 查当前区域模型目录，申请资格/配额，或显式选择有权限的模型；不自动降级 |
| Azure Apply 部分失败 | 资源可能已经创建；先 Check，查看 Portal，再决定重试；没有自动删除/回滚云资源 |
| 已有同名部署模型不同 | 选新的部署 ID 或人工审查，脚本拒绝覆盖 |
| 不支持的 OpenTypeless 版本 | 使用 -BridgeOnly 并手动 UI 配置；只有审查兼容后才用 -AllowUntestedAppVersion |
| 应用仍在运行 | 自动改设置需要从托盘退出；关窗口可能只是最小化 |
| 中继端口被占用 | 查看拥有进程；已有中继可用 Upgrade-Guardian 接管，不能凭端口杀未知进程 |
| 无控制台，但没有转录 | 运行 Get-BridgeStatus；检查 paused、taskEnabled、guardianCount 和 bridgeHealthy |
| 主动 Stop 后不恢复 | 这是预期；Start 才清除暂停并恢复任务 |
| 守护 ownership-check-failed | 无法验证进程身份；保留错误，检查本机 WMI/权限，不扩大杀进程范围 |
| HTTP 401 | 分清 localhost Key 不匹配和 Azure Token 问题；核对两段认证 |
| HTTP 403 | 检查实际调用身份的数据平面角色、传播、网络条件和组织策略；不要直接启用资源 Key 绕过 |
| HTTP 503 / 登录过期 | Sign-In → Stop → Start；MFA 由用户完成 |
| HTTP 404 | 核对资源 endpoint 和部署 ID，不以模型展示名替代部署 ID |
| HTTP 400 | 核对模型兼容参数、API 版本、输出 token 下限和文件格式 |
| HTTP 429 | 查看部署速率配额和并发；不要用连续重启放大请求 |
| 第一次调用较慢 | 可能包括 Azure CLI 获取 Token 时间；后续请求复用缓存，不只看首个请求评价模型速度 |
| 脚本/计划任务被策略阻止 | 保留具体错误，由用户/管理员使用正常批准流程；不换工具绕过策略 |

不含敏感数据的诊断：

```powershell
$bridge=Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'
& (Join-Path $bridge 'Get-BridgeStatus.ps1')
& (Join-Path $bridge 'Test-Setup.ps1')
# 下一个命令会调用 Azure，产生正常 API 用量。
& (Join-Path $bridge 'Test-Setup.ps1') -Live
```

报告问题时提供版本、阶段、HTTP 状态与脱敏错误。不要上传整个运行目录、原 settings.json、CLI 认证目录、备份、Token、证书、音频或客户口述。不要直接执行内部 `Get-Token.ps1` 并把其输出发到聊天/Issue。
