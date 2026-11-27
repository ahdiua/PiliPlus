# 正式版与预发布版

发布只由手动推送的 tag 触发。同步上游只合并代码，不会发布。

## 发布

推送一个符合格式的 tag，**Release** 工作流就会构建并发布该 tag 指向的提交：

```text
git tag 2.2.1F.1
git push origin 2.2.1F.1
```

tag 格式为「上游版本 + `F` + 可选的 fork 序号 + 可选的 `-pre`」：

| tag | 含义 |
|---|---|
| `2.2.1F` | 基于上游 2.2.1 的第一个正式版 |
| `2.2.1F.1`、`2.2.1F.2` | 同一上游版本上的 fork 小版本 |
| `2.2.0.1F`、`2.2.0.1F.1` | 上游四段版本（如 2.2.0.1）同样追加 `F` |
| `2.2.1F.3-pre` | 预发布版：不会成为 Latest，App 也不会提示更新 |

- 上游自己也会发四段版本（2.2.0.1、2.2.0.2），所以 fork 小版本不用 `2.2.1.1` 这种写法，以免撞名。
- 允许上游式的 `v` 前缀（`v2.2.1F.1`）。序号从 1 开始，不能有前导零。
- 构建前会依次检查（`lib/scripts/release-tag.sh`），任何一项不满足就不构建：
  - tag 格式正确；
  - tag 中的前三段版本与该提交 `pubspec.yaml` 的版本一致。上游的第四段不在 pubspec 里，
    例如 `2.2.0.1F` 对应的 pubspec 是 `2.2.0`；
  - 该提交已经在 `main` 上。请先推送 `main`，再推送 tag。
- 构建失败时，在 Actions 里重新运行这次 **Release** 即可，tag 不需要改动。
- 同一个 tag 只发布一次。需要重新发布时，换一个新序号。

## 同步上游

在 Actions 中手动运行 **Sync upstream**，选择合并来源：

- `release`（默认）：上游 `bggRGjQaUbCoE/PiliPlus` 最新正式 Release 对应的提交，
  排除草稿和预发布。不会合并该 tag 之后的开发提交。上游还没有正式版时不做任何事。
- `main`：上游 `main` 的最新提交。

合并成功后推送 `main`，在运行摘要里给出建议的 tag，但不打 tag、不发布。
`main` 已经包含该提交时不做任何事。合并有冲突时直接失败，不推送；需要在本地合并、
解决冲突后推送 `main`。不再有定时任务，`main` 不会在开发时被自动改动。

## 版本号与更新检查

- 正式版设置 `prerelease: false` 并标记为 Latest；预发布设置 `prerelease: true`，
  不会成为 Latest。App 的自动和手动检查更新都只请求本仓库 `/releases/latest`，
  并校验返回对象不是草稿或预发布；Android 还要求有 ARM64 APK，并比较 `versionCode`。
  没有正式版时，手动检查提示「暂无可用的正式版本」。
- 更新判断只看 APK 文件名里的 `versionCode`，不依赖 tag 字符串，所以 tag 的命名方式不影响更新检查。
  `versionCode` 取距 2020 年的 UTC 秒数，并保证大于仓库里已有 APK 的最大编号，
  避免不同分支的提交数量造成降级安装。原有签名和应用 ID 保持不变。
- 关于页显示的版本名就是 tag，Android 再加提交哈希，例如 `2.2.1F.1-30d457503`。
  这样能区分同一上游版本上的多个 fork 版本。`pubspec.yaml` 和 APK 文件名仍使用
  semver 形式（如 `2.2.1-30d457503+<versionCode>`），因为 Flutter 需要 semver，
  更新检查也要从文件名读取 `versionCode`。
- 新预发布的 ARM64 APK 上传成功后，才删除其他已发布的预发布版及其 tag。
  正式版和未发布的草稿不删除；构建或上传失败时保留旧预发布。
- Android 构建共用一个发布队列。桌面等平台的工作流只能手动运行，仍沿用原版本编号。

## 旧 tag

`2.2.1F`、`2.1.6.2F` 以及 `2.1.6F.<UTC 时间戳>` 这些 tag 和已发布的 Release 保持不变。
旧格式本身也符合新规则（时间戳就是一个很大的序号），但只有新推送的 tag 才会触发构建。

发布策略的本地回归测试（Python 3 + Git Bash，不会发布真实 Release）：

```text
python tool/check_release_policy.py
```
