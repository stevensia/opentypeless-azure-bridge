# 将这个仓库发布到 GitHub

此目录只维护通用源码。个人 `.local` 与本机 AppData 运行目录不应发布；公开仓库和个人部署包要分别管理。

package.json 的 `private: true` 仅防止误发布到 npm，不限制 GitHub 仓库公开。

## 发布前

1. 阅读 LICENSE 与 THIRD_PARTY_NOTICES，确认你有权以所选 MIT 许可证公开自己的修改。不要暗示本项目由 Microsoft/OpenAI/OpenTypeless 官方维护。
2. 检查 Git 暂存内容和历史。示例只保留占位符；测试使用虚构数据；不要把本机 PID、任务名、资源地址或排错聊天整理进公共文档。
3. 执行：

```powershell
npm test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PowerShell.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Profile.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Provisioning.ps1
npm run check
# 已有提交时扫描所有本地 refs 的历史文件：
npm run check -- --history
npm run release
```

4. 检查 `dist` 中的 ZIP 和 `.sha256`；ZIP 内有每个源文件的 SHA256SUMS。发行包由 `release-files.json` 明确白名单构建，不使用“整个工作目录打包”。脚本规范化换行和 ZIP 时间；相同源内容两次构建应得到相同 hash。
5. 确认压缩包可以解压，说明中的相对链接和脚本入口完整。不要将 `.git`、私有 profile、缓存、日志、备份或本机生成的 exe 添加到白名单。

## 创建公开仓库（由发布者执行）

在 GitHub 新建空仓库，例如 `opentypeless-azure-bridge`。已有本地提交时，不要在网页端额外初始化 README/LICENSE，以免产生无关历史。确认公开范围后，在本目录执行：

```powershell
git status --short
git remote add origin https://github.com/YOUR-USER/opentypeless-azure-bridge.git
git push -u origin main
```

将 `YOUR-USER` 换为你控制的账号或组织。不要把访问令牌写进 remote URL；使用 GitHub 正常认证。若已有 origin，先核对再设置，不覆盖未知 remote。

初始仓库可使用通用贡献者提交身份，以免自动公开机器上的私人/公司邮箱。发布者可以为后续提交配置自己的 GitHub noreply 身份，并补充实际维护者/仓库信息。

## GitHub 设置与 Release

- 检查第一次 CI：它只用模拟数据，不要求任何 Azure secrets。当前文件中存在 CI 工作流不代表远程已经运行成功。
- 按账号/组织能力启用 secret scanning、push protection 和私密漏洞报告；必要时增加对本地自定义 Key 的检测。
- 建议保护 main，通过 PR 审查修改；不要为 fork PR 注入 Azure 凭据，也不要改用 pull_request_target 执行其代码。
- CI 的 Actions 依赖已用完整 SHA 固定，Dependabot 提交更新建议。更新时审查实际变化再合并。
- Release 可上传 `dist/opentypeless-azure-bridge-v0.1.0.zip` 和其 `.sha256`，并说明兼容边界与未验证事项。当前 CI 只保存供审查的 artifact，不自动创建公开 Release 或推送 tag。

源码公开不需要公开认证实现使用的秘密；反过来，私有仓库也不应该保存实际 Token、Key 或证书。发现已提交秘密时先撤销/轮换，再按 [GitHub 官方处理步骤](https://docs.github.com/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository) 清理历史及发行物；不能只删除当前文件。
