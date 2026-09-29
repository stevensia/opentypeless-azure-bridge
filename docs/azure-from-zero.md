# 从零准备 Azure 资源与部署

最后核对：2026-09-29。目标是准备一个 Azure Global 的 Foundry / Azure OpenAI 资源，以及文件转录和 Chat Completions 润色两个部署。本工具不依赖 Foundry Agent 服务；不要把项目 URL 填成模型根 endpoint。

## 1. 人工完成的前提

1. 注册/使用 Microsoft Entra 账号，并准备有效 Azure 订阅。订阅、账单信息、组织准入、MFA、条件访问和地区限制需由你或管理员完成。[1]
2. 确认订阅和资源组的权限。创建资源需要相应管理权限；分配推理角色还需要角色分配权限。能创建资源不代表能授予 RBAC，也不代表已经可以推理。[1][2]
3. 在 Portal 的订阅“资源提供程序”中确认 `Microsoft.CognitiveServices` 已注册；未注册时由有权限的人注册。脚本 Check 会停止，不会假定失败查询意味着资源不存在。
4. 确认组织允许当前网络访问 Entra 和 Azure 推理 endpoint。私有网络资源需自行准备 VPN、DNS 或 Private Endpoint，脚本不修改防火墙。
5. 参考 [模型说明](models.md)，确认所在区域、订阅访问资格、配额和容量。参考环境使用过 `eastus2`，不保证你的订阅也有容量；预算和费用由你在 Azure 管理。

准备本地依赖（如果尚未安装）：

```powershell
winget install --id OpenJS.NodeJS.LTS --exact --source winget
winget install --id Microsoft.AzureCLI --exact --source winget
```

安装完成后重新打开 PowerShell，确认 `node --version`、`az version`。Foundry 项目相关 CLI 命令在微软指南中要求 Azure CLI 2.80.0 或以上；本工具不创建项目，但建议使用当前受支持版本。[1]

## 2. 推荐组合和命名

默认创建两个部署：

| 用途 | 模型 | 版本 | 示例部署名 | SKU |
| --- | --- | --- | --- | --- |
| 文件转录 | `gpt-transcribe` | `2026-07-28` | `speech-main` | `GlobalStandard` |
| 润色 | `gpt-6-sol` | `2026-09-22` | `polish-main` | `GlobalStandard` |

这些是参考环境实际使用并于 2026-09-29 复核的模型版本。模型目录随区域、订阅及时间变化；Check 不通过就先处理可用性问题，不要偷偷换成其他模型。需要润色备选时，可显式选择已验证的 `gpt-5.4` / `2026-03-05`。[3][4]

示例容量 `10` 是部署的速率配额容量，不是固定费用、并发数或每月免费额度；不同模型的单位可能不同。可用容量以目录、配额页面和服务返回为准。申请配额或模型访问资格需人工完成。

## 3. 用脚本准备（推荐可重复操作路径）

在仓库目录：

```powershell
New-Item -ItemType Directory .local -Force | Out-Null
Copy-Item .\config\azure-resources.example.json .\.local\azure-resources.local.json
```

编辑本地文件中的：

- `tenantId`、`subscriptionId`：从 Azure 订阅/Entra 页面复制你自己的值。
- `resourceGroup`：已有或准备新建的资源组。
- `resourceName`：全局唯一、小写字母/数字/连字符；脚本令它同时作为自定义子域名。
- `location`：通过目录和配额确认后的区域 ID。
- `kind`：默认 `AIServices`；使用传统 Azure OpenAI 资源时可用 `OpenAI`。
- `principalObjectId`：要授予推理权限的 Entra **对象 ID**，不是应用 client ID；对应填写 `principalType`。需要管理员手工授权时填 `null`，脚本跳过 RBAC 创建。
- `speech`、`polish`：明确的模型、版本、部署名、SKU 和容量。修改模型时同时核对其 API 和推理参数，不仅修改展示名称。

然后逐步运行：

```powershell
# 默认 Plan：完全离线，只校验配置和显示计划，不登录、不建资源。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Azure-Resources.ps1 -Mode Plan

# 首次 Check 可以显式登录，使用工具独立的 provisioning-auth 目录。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Azure-Resources.ps1 -Mode Check -SignIn

# 浏览器登录不可用时可尝试 -SignIn -DeviceCode；是否允许由组织策略决定。
# 确认资源、模型和费用后再明确执行 Apply。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Azure-Resources.ps1 -Mode Apply
```

Check 只读 Azure 状态：核对订阅/租户/云、资源提供程序、模型版本/SKU/容量范围、已有账号和部署。它无法保证当前剩余配额、动态容量、所有角色或真实推理成功；CLI 可能写自己的本地日志/认证状态。

Apply 的行为：

1. 重做上述预检；身份不匹配、目录不可用、同名部署模型不一致或现有资源状态异常时停止。
2. 创建缺失的资源组和账号。新账号用 `disableLocalAuth=true` 禁用 Azure 资源 Key；`AIServices` 同时启用系统托管身份和项目管理能力。这个托管身份是资源自身身份，本机中继仍使用你的 CLI 登录。[5]
3. 创建缺失的两个模型部署。相同模型/版本/SKU 的现有部署保留，不强行改其容量；不覆盖不同模型的同名部署。
4. 若提供 principal 对象 ID，在资源范围授予 `Cognitive Services OpenAI User`；权限不足时停止，交由管理员处理。[2]
5. 回读两个部署达到 `Succeeded` 后生成 `.local/azure-profile.local.json`，供本机 Setup 使用。已有输出配置不会被覆盖；可用 `-OutputProfile` 指定另一个本地文件。

**Apply 不是事务。** 如果建资源后发生配额或权限错误，已经完成的资源可能保留。先重跑 Check，再处理问题；脚本不自动删除任何云资源，不以失败结果假装回滚成功。已有共享资源的认证、网络和身份设置不被脚本改写。

上述自动化的配置校验、命令生成和冲突判断有模拟测试；未为发布准备额外创建一套真实收费资源。因此新订阅创建和组织特定权限仍要现场验收，失败时可按下一节 Portal 步骤处理。

## 4. Portal 路径（策略或脚本不适用时）

1. 登录 Microsoft Foundry / Azure Portal，选择正确目录和订阅。创建资源组和 **Microsoft Foundry 资源**；记录资源名称、区域和资源级自定义 endpoint。若 Portal 要求创建项目，可按向导创建，客户端仍使用资源级 OpenAI endpoint。[1]
2. 在该资源的模型目录中搜索 `gpt-transcribe`，确认版本及区域，选择部署；部署名填 `speech-main` 或自己喜欢的名字。
3. 同样部署 `gpt-6-sol`，部署名填 `polish-main`。如无访问资格或配额，先申请；或经你明确决定使用 `gpt-5.4` 并记录变更。[3][4]
4. 在资源的“访问控制（IAM）”为实际调用身份授予推理角色，例如 `Cognitive Services OpenAI User`。创建/管理资源的权限和数据平面推理权限分开确认。[2]
5. 如果资源只允许 Entra 认证，使用本工具即可；无需为本工具启用 Azure API Key。不要更改共享资源认证策略来绕过权限问题。
6. 等待部署为 `Succeeded`、角色传播完成。记下 tenant ID、资源自定义子域名和**部署名**。不要记录或向 AI 发送 Key、access token、认证缓存或私钥。
7. 回到仓库执行 `Initialize-Profile.ps1`，或复制 `config/azure-profile.example.json` 到 `.local/azure-profile.local.json` 并填写。

例如可直接传入参数（将占位符替换为自己的数据）：

```powershell
.\Initialize-Profile.ps1 -TenantId '<tenant-id>' -ResourceSubdomain '<custom-subdomain>' `
  -SpeechDeployment 'speech-main' -PolishDeployment 'polish-main' -PolishPreset ReasoningNone
```

Portal 显示的项目地址通常包含 `/api/projects/...`，不应填进本工具的 Base URL。应用本身填 localhost，中继配置才填写 Azure 根 endpoint。

## 5. 安装、验证、费用与清理

云端就绪后回到 [README](../README.md)，执行本地 Check → Apply。资源脚本与桥接脚本采用独立认证目录，首次安装可能需要再次登录；这是正常隔离，不应复制另一台电脑的 token cache。

验收分层进行：部署 Succeeded → 实际推理权限 → 中继健康 → 应用两个连接测试 → 真实麦克风口述。不要把前一层成功等同于后一层成功。

模型调用按 Azure 订阅计费；本指南不把其他提供商的 API 价格当作 Azure 价格。部署前核对 [Azure OpenAI 定价](https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/) 和订阅预算。用完后通过 Portal 人工检查并删除自己不再需要的部署/专用资源，避免误删共享资源组；本项目没有自动删除云资源的命令。

## 官方依据

1. [Microsoft Foundry 资源准备与模型部署](https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources)
2. [Azure OpenAI 的 Entra 认证与角色](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/managed-identity)
3. [微软模型目录](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure) 与 [区域可用性](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)
4. [Azure 文件转录快速入门](https://learn.microsoft.com/azure/foundry/openai/whisper-quickstart) 与 [推理模型参数](https://learn.microsoft.com/azure/foundry/openai/how-to/reasoning)
5. [账号 ARM API 2025-06-01：customSubDomainName、disableLocalAuth、allowProjectManagement](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2025-06-01/accounts)
6. [Azure CLI 部署命令](https://learn.microsoft.com/cli/azure/cognitiveservices/account/deployment) 与 [模型目录命令](https://learn.microsoft.com/cli/azure/cognitiveservices/model)
