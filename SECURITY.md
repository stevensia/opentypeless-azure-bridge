# Security policy

此预览版按 Windows 本机、当前用户场景设计。维护者应先处理最新版本的问题；历史版本没有承诺安全维护期限。

## 数据边界

- 只绑定 127.0.0.1；模型/推理路由要求本机 Bearer Key，限制 Host、拒绝浏览器 Origin，Azure endpoint 和部署有白名单。
- 本机 Key 不是 Windows 同账号恶意进程的隔离边界。能读取该账号文件的进程或管理员可能获得 Key/缓存；不要把运行目录当作可公开内容。
- Azure Token 只在中继内存暂存；Azure CLI 的缓存仍会落盘，必须按凭据管理。日志不应写 Key、Token、音频或口述正文。
- 自动配置可能先把本机 Key 写入应用 JSON，等待应用启动迁移；备份也可能包含旧凭据。目录 ACL、备份保护、应用测试和发布排除均不可省略。
- 证书私钥、服务主体缓存、本机配置和故障转储不能上传。证书到期和撤销由拥有者维护。
- 不支持暴露公网、多人共享代理、跨租户授权或任意上游转发。要做共享网关需另外设计鉴权、HTTPS、配额及数据处理策略。

## 报告漏洞

公开后优先使用 GitHub 私密漏洞报告（维护者启用后）。若尚未开启，请只在 Issue 请求私密联系渠道，不公开利用细节、凭据或个人数据。普通功能问题可提供脱敏版本和错误状态。

发现凭据已提交时，先撤销/轮换，再处理 Git 历史、Release、fork/clone 的影响；删除当前文件或改成私有仓库不能保证秘密收回。参见 [GitHub 敏感数据处理](https://docs.github.com/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)。

## 发布保护

`.gitignore` 不是访问控制。`check-public.mjs` 是针对本项目的启发式检查，不能保证识别任意秘密；它只打印文件/行号/规则，不回显匹配值。配合人工 diff 审查、Git 历史检查和 GitHub secret scanning / push protection。自定义 localhost Key 可能不符合提供商密钥格式，不能只依赖平台检测。
