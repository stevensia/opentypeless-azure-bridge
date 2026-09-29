# 认证与凭据边界

## 两段认证

1. OpenTypeless → localhost 中继：每台机器生成的随机 `localApiKey`。
2. 中继 → Azure：Microsoft Entra access token，由该机器独立 Azure CLI 登录获取；短期 Token 只在中继内存中缓存，CLI 自己管理登录缓存。

不要把 Azure access token 当成应用长期 API Key。也不要因为 Azure 资源禁用了 API Key，就尝试开启它：此中继使用 Entra 认证。普通 Windows 本地账户可以运行，但必须完成 Azure 身份认证或配置管理员提供的工作负载身份。

## 用户登录（默认）

Setup 在运行目录下维护独立 `azure-auth`；升级已有兼容安装时可保留该安装原来位于 OpenTypeless 本地目录内的认证路径。认证环境变量仅在调用进程范围设置并恢复，不更改普通 CLI 的配置目录。

`Sign-In.ps1` 在自己的 profile 内配置 AzureCloud 并关闭 WAM broker，使用浏览器或显式设备代码登录。MFA、组织设备合规和条件访问仍需用户完成，脚本不会绕过。

```powershell
$bridge=Join-Path $env:LOCALAPPDATA 'OpenTypeless\foundry-bridge'
& (Join-Path $bridge 'Sign-In.ps1')
& (Join-Path $bridge 'Stop-Bridge.ps1')
& (Join-Path $bridge 'Start-Bridge.ps1')
```

重新登录后重启中继，是为了丢弃旧身份的内存 Token。中继提前五分钟刷新 Token，多个并发请求共用一次刷新；无法刷新时报告需要重新登录，不无限重试。

本实现默认采用 `https://cognitiveservices.azure.com/` audience，参考环境的语音和润色请求均验证过。微软较新的 v1 文档也展示 `https://ai.azure.com/.default`。当前版本不提供任意 audience 配置；更换前需同时验证语音和文本端点，不能只替换一个示例。[1][2]

## 证书服务主体（管理员预先准备）

管理员需要提供 Entra 应用/服务主体、已注册的证书公钥、匹配的本地私钥和资源推理权限。脚本支持使用包含证书和私钥的 PEM 文件进行 CLI 登录；不直接读取 Windows 证书库中的不可导出私钥。仅有 `.cer` 或证书指纹不够。[3]

```powershell
.\Setup.ps1 -Mode Apply -ClientId '<application-client-id>' `
  -CertificatePath 'C:\Secure\voice-bridge.pem'
```

私钥单独安全交付并维护 ACL 和到期轮换；不要放进源码、共享安装包或公开 Issue。CLI 的 service principal 缓存也属于敏感数据。证书参数入口已经实现，但本版本没有真实服务主体端到端验收；失败应交给管理员核对，不复制其他机器缓存代替认证。

## Shared gateway / Managed Identity

若希望每台电脑完全不持有 Azure 身份，可以另外部署经 HTTPS 保护的共享中转，由服务器 Managed Identity 或证书身份调用 Azure，并给每台客户端分配可撤销凭据。这个项目没有实现远程网关、客户端租户隔离或互联网暴露所需的保护；不得直接把监听地址改为 `0.0.0.0` 充当服务器。

`Azure-Resources.ps1` 为 AIServices 资源启用的 SystemAssigned Identity 用于其项目管理能力，不是这台 Windows 电脑可直接借用的身份。[4]

来源：[Azure Entra 认证](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/managed-identity) [1]；[v1 API](https://learn.microsoft.com/azure/foundry/openai/api-version-lifecycle) [2]；[CLI 证书登录](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-service-principal) [3]；[Foundry 资源准备](https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources) [4]。核对日期：2026-09-29。
