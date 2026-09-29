# 兼容性、验证范围与限制

项目版本：0.1.0，预览版。整理日期：2026-09-29。

| 范围 | 状态 |
| --- | --- |
| Windows 10/11，Windows PowerShell 5.1 | 目标平台；在当前 Windows 环境实际解析并执行测试 |
| Node.js | 要求 22+；本地测试为 24.14.1，CI 配置覆盖 22/24 |
| Azure CLI | 用户登录/证书命令接口；新资源 Check/Apply 使用独立配置目录 |
| Azure Global | 实现；不支持 Azure China 或任意第三方 upstream URL |
| OpenTypeless 自动配置 | 以 1.1.59 的实际 JSON 字段为基准；合成配置合并/回滚经过测试 |
| 其他 OpenTypeless 版本 | 默认拒绝自动写配置；可以 BridgeOnly + 手动 UI；显式审查后才允许未测试版本 |
| 守护 | 无窗口宿主、进程退出与无响应恢复、单实例、暂停、任务计划恢复经过隔离测试 |
| 云资源创建 | Plan/Check/Apply 的命令、校验、冲突判断和幂等逻辑通过假 CLI 集成测试；未额外创建真实收费资源 |
| 真实 Azure 推理 | 参考部署的语音、GPT-6 Sol/GPT-5.4 润色链路曾真实验证；公共仓库测试默认离线 |
| 证书身份 | 提供参数入口和官方步骤；未做真实服务主体端到端验收 |
| 全新第二台电脑、整机重启/睡眠 | 仍需现场验收；不能用本地模拟测试证明这些条件 |
| GitHub Actions | 工作流已提供；上传前没有实际 GitHub 运行记录 |

自动配置的支持版本只是适配边界，不代表所有安装形式和凭据库行为都已验证。未知字段保留、文件哈希并发检查、备份和回滚可以降低误写风险，但实际应用连接与口述仍需用户测试。

## 本地验证证据

- Node 原生测试：33 项，涵盖本机认证、Host/Origin、音频大小/静音、模型 allowlist、SSE、参数转换、上游错误、Token 并发刷新、配置保留/回滚，以及云计划和发布检查。
- Windows 隔离守护测试：10 项通过（包含实际临时任务计划），覆盖启动、重复运行、子进程故障、卡死、孤儿接管、守护自身恢复、暂停/恢复和不影响其他 Node。
- Azure provisioning 假 CLI 测试：Plan 不调用 CLI、Check 不写云、Apply 创建预期五类操作、重复 Apply 不改已有匹配对象、生成合法 profile、恢复父环境。
- PowerShell 脚本语法、目录 ACL 和 CLI 环境隔离/失败恢复测试。
- 发布包须通过文件白名单、内容扫描、Git 历史扫描和 ZIP 解压后哈希核对；发布者按 docs/publishing.md 重跑。

测试使用虚构租户、虚构资源和模拟上游，不包含参考环境的真实订阅、endpoint、PID 或个人目录。私有测试日志不提交。测试数量以当前测试命令输出为准，修改功能后需更新记录。

## 原理和上游契约

OpenTypeless 的配置/凭据行为参考公开源码：`src-tauri/src/storage/mod.rs`、`credentials.rs`、`llm/protocol.rs`。参考审阅提交见 [上游源码](https://github.com/tover0314-w/opentypeless/tree/33d0e32a74dbd315cf79da9214e348d0d701c1b4)。源码版本字符串和发行二进制版本不应自动视为一致；因此提供 BridgeOnly 路径，并将应用实际测试独立列为验收条件。

同一进程健康状态不代表 Azure 登录状态；同一模型名称不代表不同区域/版本的兼容性。当前实现只处理文件转录和 Chat Completions，未实现 Realtime、Responses 搜索、远程共享服务或离线模型。
