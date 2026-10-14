# 正式版与预发布版

- 发布入口为 Actions 中的 **Sync upstream and release** 工作流。
- **每日任务**：检查上游 `bggRGjQaUbCoE/PiliPlus` 最新正式 Release 对应的 tag，
  排除草稿和预发布。只有尚未发布过对应正式版时，才将该 tag 指向的提交合并到
  `main` 并构建、发布本仓库正式 Release；不会合并 tag 之后的上游开发提交。
  没有新正式 Release 时不合并、不构建、不发布。
- **手动运行**：点击上述工作流的 `Run workflow`，同步上游 `main` 最新提交到
  本仓库 `main`，然后构建并发布预发布版。即使上游没有新提交，也可发布当前 fork
  的预发布版。同步目标始终为 `main`。
- 普通分支和 tag 推送不再自动发布。`Build` 仅供同步工作流调用，发布类型通过
  显式参数传递，不依赖调用方事件或分支名推断。
- 新正式版 tag 为 `版本F.UTC时间戳`，例如 `2.1.6F.20261010120000`。
  预发布版只增加 `-pre`，例如 `2.1.6F.20261010120000-pre`。
- 正式版设置 `prerelease: false` 并标记为 Latest；预发布设置 `prerelease: true`，
  不会成为 Latest。App 的自动和手动检查更新都只请求本仓库 `/releases/latest`，
  并校验返回对象不是草稿或预发布；Android 继续检查 ARM64 APK 和 `versionCode`。
  没有正式版时，手动检查提示「暂无可用的正式版本」。
- Android 正式版与预发布版共用发布队列。`versionCode` 使用距 2020 年的 UTC 秒数，
  同时确保大于仓库已有 APK 的最高编号，避免不同分支的提交数量造成降级安装。
  原有签名和应用 ID 保持不变。桌面等平台仍沿用原版本编号。
- 新预发布的 ARM64 APK 上传成功后，才删除其他已发布预发布版及其 tag。
  正式版和未发布的草稿不删除；构建或上传失败时保留旧预发布。
- 正式版使用附注 tag 记录对应的上游仓库与 Release tag，避免 `main` 上的后续修改
  或手动预发布导致同一个上游正式版重复发布。首次运行新策略时会处理当前上游最新
  正式版；旧 tag 不改写。
- 仅已发布且含上传完成、非空 ARM64 APK 的正式 Release 视为成功。
  构建或发布失败后，每日任务复用原正式版 tag 和提交重试；合并冲突时停止发布，
  需解决冲突后重试。

GitHub 的 Release 列表排序与 Latest 标记由平台控制；新版 tag 使用同一版本前缀和
UTC 时间戳，使正式版与预发布版的名称能够按时间比较。历史 tag 不改名。

发布策略的本地回归测试（Python 3 + Git Bash，不会发布真实 Release）：

```text
python tool/check_release_policy.py
```
