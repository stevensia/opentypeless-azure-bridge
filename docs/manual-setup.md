# 手动配置 OpenTypeless

如果应用版本与自动适配不一致，或不想写 settings.json：

```powershell
.\Setup.ps1 -Mode Check -BridgeOnly
.\Setup.ps1 -Mode Apply -BridgeOnly -InstallDependencies
```

这条路径只安装/验证中继和守护，不要求退出 OpenTypeless，也不改应用设置。以下以默认端口和示例部署 ID 为例，使用你本地 profile 中实际配置的值：

| 字段 | 语音服务 | AI 润色 |
| --- | --- | --- |
| Provider | Custom Whisper / 自定义 Whisper | OpenAI |
| Base URL | `http://127.0.0.1:17863/v1` | `http://127.0.0.1:17863/polish/v1` |
| Model | `speech-main` | `polish-main` |
| API Key | 本机中继的连接 Key | 同一个本机连接 Key |
| 其他 | 自定义 preset，语言 `zh` | 开启 AI 润色 |

不要把 Base URL 再拼上 `/audio/transcriptions` 或 `/chat/completions`，也不要把示例部署名当作已经创建的资源。

复制本机 Key 到剪贴板（不输出密钥到终端）：

```powershell
$bridge=Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'
& (Join-Path $bridge 'Copy-LocalKey.ps1')
# 粘贴到两个服务的 Key 字段、保存后清空剪贴板。
Set-Clipboard -Value ''
```

不要将密钥粘贴给 AI、发到 Issue 或截进截图。手工保存后分别运行应用的两个连接测试，再实际口述。若只有脚本探针成功而没有操作应用，就只报告中继可用，不报告应用已经验收。

自动配置路径会先备份 JSON，再合并相关字段，保留快捷键、自定义提示词和其他未知字段；不会修改 OpenTypeless 可执行文件或源代码。根据所审阅的上游逻辑，应用启动时会迁移明文凭据到系统凭据库；脚本本身不会读取或验证该库。JSON 密钥已清空不能单独证明认证成功。

恢复自动配置的字段：先从托盘退出应用，然后执行：

```powershell
& (Join-Path $bridge 'Restore-AppSettings.ps1') -BackupDirectory '<本次配置输出的备份目录>'
```

回滚只还原脚本管理的字段，保留随后修改的无关设置；若随后手动更改过模型/endpoint，会停止避免覆盖。Windows 凭据库没有被备份，因此旧服务商的 Key 可能需要在 UI 重新填写。
