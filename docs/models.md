# 模型选择和版本

最后核对：2026-09-29。推荐组合来自参考环境的真实使用与 Azure 管理 API 回读；不是通用准确率排行榜，也不表示每个订阅都能部署。

| 用途 | 推荐模型 | 已使用版本 | 说明 |
| --- | --- | --- | --- |
| 中文文件转录 | `gpt-transcribe` | `2026-07-28` | 当前主用；走 Audio 文件上传接口 |
| 中文润色 | `gpt-6-sol` | `2026-09-22` | 当前主用；Chat Completions + `reasoning_effort=none` |
| 润色备选 | `gpt-5.4` | `2026-03-05` | 已做真实小样本文字润色测试；可显式替换主用 |
| 转录备选 | `gpt-4o-transcribe` | `2025-03-20` | 曾验证兼容；当前主用不是它 |
| 转录备选 | `gpt-4o-mini-transcribe` | `2025-12-15` | 曾验证接口；质量和延迟应使用自己的音频比较 |

默认资源示例只创建主用的两个部署，避免为未使用模型占配额。想使用 GPT-5.4 时，先在资源配置中明确将 polish.model/version 改成对应值，创建新的部署 ID 或使用已匹配的部署；脚本不会暗中替换模型。

部署 ID 是你创建部署时自定义的名字，如 `speech-main`；模型 ID 是 `gpt-transcribe`。应用和中继填写部署 ID。不要假设别人订阅中的部署名和本仓库示例一致。

润色的兼容规则：

- 保留 OpenTypeless 的消息与 system prompt，只转换协议参数。
- `max_tokens` 转成 `max_completion_tokens`，已验证的高级模型使用至少 32 个输出 token 兼容连接探针。
- 主用和 GPT-5.4 示例采用 `reasoningEffort: none`；不发送采样温度。此选择适用于延迟敏感的短文本润色，不代表每个模型都支持 none。
- 普通模型可用 `Standard` preset，仅保留输出 token 限制和客户端温度。换模型前核对其 API 和参数，不把所有推理模型当作相同接口。
- 目前没有 Responses / web_search 适配；选择更高级模型不会自动获得联网搜索。

语音默认 language 为 `zh`，可在本地 profile 调整。术语 prompt 是提示而非纠错保证；不要在共享 profile 中加入个人、客户或公司机密术语。只检测全零 PCM16 WAV 的静音探针，不使用音量阈值丢弃轻声。

微软文档中的 offline transcription 指完整文件转录流程，不代表模型在本机运行。语音和润色都需要联网访问 Azure，都会按订阅计费。

来源：[模型目录](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure)、[区域可用性](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)、[文件转录](https://learn.microsoft.com/azure/foundry/openai/whisper-quickstart)、[推理参数](https://learn.microsoft.com/azure/foundry/openai/how-to/reasoning)。精确版本来自参考部署回读，更新前请重新查目录；本仓库未公开参考环境的租户、订阅或 endpoint。
