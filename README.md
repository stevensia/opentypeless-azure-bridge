# OpenTypeless Azure Bridge

面向 Windows 的本机中继，让 OpenTypeless 使用 **Azure OpenAI / Microsoft Foundry** 的语音识别和文字润色部署。包含 Microsoft Entra 认证、协议参数适配、隐藏守护、任务计划自动恢复及可回滚的本机配置脚本。

这是独立社区配套工具，与 Microsoft、OpenAI、OpenTypeless 官方无隶属关系。项目采用 MIT 许可证。当前版本 **0.1.0 / 预览版**；支持范围和未验证项目见 [兼容性与验证](docs/compatibility.md)。

## 从哪里开始

| 你的情况 | 使用路径 |
| --- | --- |
| 还没有 Azure 账号、资源或模型部署 | 先读 [从零准备 Azure](docs/azure-from-zero.md)；资源脚本默认只输出 Plan |
| 已有资源和两个可用部署 | 按下面的“已有 Azure 资源”生成本地配置，再安装 |
| 已有本机中继，只想增加/升级守护 | 使用 `Upgrade-Guardian.cmd`，见 [守护管理](docs/guardian.md) |
| 应用版本不受支持，或不希望脚本修改应用设置 | 使用 `Setup.ps1 -Mode Apply -BridgeOnly`，然后 [手动配置 UI](docs/manual-setup.md) |
| 希望让 AI 帮忙配置 | 把 [AI-SETUP.md](AI-SETUP.md) 交给 AI，登录/MFA 仍由你完成 |
| 准备将仓库上传 GitHub | 阅读 [发布流程](docs/publishing.md)，只发布经过检查的源码/发行包 |

## 推荐模型

参考环境已实际使用以下组合；模型名与版本在 **2026-09-29** 再次通过 Azure 部署 API 核对。它们不是对所有订阅/区域的可用性承诺。

| 用途 | Azure 模型 | 已核对版本 | 本仓库示例部署 ID |
| --- | --- | --- | --- |
| 语音识别 | `gpt-transcribe` | `2026-07-28` | `speech-main` |
| AI 润色 | `gpt-6-sol` | `2026-09-22` | `polish-main` |
| 润色备选 | `gpt-5.4` | `2026-03-05` | 自己创建并填写 |

该语音链路是上传录音文件后转录，**不是本机离线模型，也不是 Realtime 会话**。润色使用 Chat Completions；不包含联网搜索。各模型可用性、版本、参数、费用与替代方法见 [模型选择](docs/models.md)。

## 已有 Azure 资源：最短路径

准备 Windows 10/11、Node.js 22 或更新的受支持 LTS、Azure CLI、Windows PowerShell 5.1，以及已安装并完成首次引导的 OpenTypeless。安装器可通过 `-InstallDependencies` 安装缺少的 Node.js/Azure CLI；账号、订阅、MFA 和配额申请不能代办。

在仓库目录执行：

```powershell
# 不创建云资源。按提示输入你自己的 tenant 和资源自定义子域名。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-Profile.ps1

# 查看 .local/azure-profile.local.json，填入你真实的两个部署 ID。
# 同名示例 ID 只有在你已经按本指南部署后才能使用。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Mode Check
```

自动改应用设置前，从 **OpenTypeless 托盘菜单退出**。随后双击 `Setup.cmd`，或：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Mode Apply -InstallDependencies
```

脚本会安装本机中继/守护，在独立 Azure CLI 目录完成登录，执行小型 Azure 连接探针，再备份并合并 OpenTypeless 配置。探针产生正常 Azure API 用量。它**不自动创建云资源**；云端创建是另一个显式 `Azure-Resources.ps1 -Mode Apply` 操作。

最后在 OpenTypeless 分别测试语音和润色连接，并真实口述一段中文。静音探针只验证认证与接口，不能代表识别准确率；JSON 字段匹配也不能证明系统凭据库迁移已经完成。

## 配置与认证

```text
OpenTypeless
  speech → http://127.0.0.1:17863/v1
  polish → http://127.0.0.1:17863/polish/v1
       │ 每机生成的本地连接密钥
       ▼
本机中继 → Azure CLI 用户/证书身份 → Entra access token → Azure 模型部署
```

OpenTypeless 润色服务商选 OpenAI，表示使用兼容协议；实际后端是你的 Azure 资源。应用 API Key 字段填写**本机中继生成的 Key**，不填 Azure access token。它与资源是否允许 Azure API Key 是两回事。

- 公共示例：`config/*.example.json`，只有占位符和公开模型信息。
- 你的配置：`.local/*.local.json`，被 Git 忽略；不要提交或加入公开 Release。
- 运行目录：`%LOCALAPPDATA%\OpenTypeless\foundry-bridge`，包含本机 Key、认证目录、备份、日志、编译产物。**不要将此目录作为源码上传或跨电脑复制。**
- 默认登录只影响工具自己的 `AZURE_CONFIG_DIR`，不更改日常 Azure CLI 的云、租户和订阅。

Windows 可以使用本地账户，但默认方案仍需对 Azure 登录。证书服务主体需要管理员预先准备证书注册和 RBAC；脚本入口不等于已为你创建证书。详见 [认证](docs/authentication.md)。

## 日常控制

```powershell
$bridge = Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'
& (Join-Path $bridge 'Get-BridgeStatus.ps1') # 本地状态，不做付费推理
& (Join-Path $bridge 'Stop-Bridge.ps1')      # 停止，并持久暂停自动恢复
& (Join-Path $bridge 'Start-Bridge.ps1')     # 恢复运行和默认自动恢复
& (Join-Path $bridge 'Test-Setup.ps1') -Live # 真实 Azure 探针，会产生用量
```

守护直接作为无控制台窗口的程序运行。任务计划负责登录启动和每分钟保底恢复；守护监控 Node 中继退出及本地健康。主动 Stop 后不会被重新拉起。此方案依赖当前用户会话，不是开机无人登录也运行的 Windows 系统服务。见 [守护说明](docs/guardian.md) 与 [故障排查](docs/troubleshooting.md)。

## 开发和验证

本项目没有 npm 运行时依赖，`npm test` 不需要先 `npm install`。

```powershell
npm test
npm run check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PowerShell.ps1
# 隔离模拟服务测试，不调用 Azure；-TaskScheduler 额外测试临时任务计划。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Guardian.ps1
npm run release
```

CI 运行模拟测试，不读取你的 Azure 配置，也不需要 Azure/GitHub secrets。`npm run release` 仅按 `release-files.json` 白名单打包，并附带 SHA256 文件清单；不会递归打包个人运行目录。仓库治理见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [CHANGELOG.md](CHANGELOG.md)。
