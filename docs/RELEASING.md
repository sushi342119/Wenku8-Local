# 书屿构建与发布

开发环境：Flutter 3.41.5 / Dart 3.11.3、JDK 17。

## 日常验证

主分支提交与 PR 执行静态检查、Flutter 测试和 Python 工具测试。主分支还使用固定证书构建 ARM64 APK，见 Build Local APK 的 Artifacts。PR 不接触签名密钥。

## 正式发布

1. 同步更新 pubspec.yaml、lib/updates/app_updates.dart 中的版本、构建号及说明，以及 CHANGELOG.md。构建号必须大于已发布版本。
2. 配置 ANDROID_KEYSTORE_BASE64、ANDROID_STORE_PASSWORD、ANDROID_KEY_ALIAS、ANDROID_KEY_PASSWORD 四项 Actions Secrets。使用现有长期密钥，保留安全备份。
3. 执行 flutter pub get、flutter analyze、flutter test 和 Python 工具测试。
4. 经维护者批准发布后，推送与版本一致的新标签。Prepare Release 验证版本、构建固定签名的 ARM64 APK、导出匹配源码并创建正式 Release。符合 `release: ` 前缀的 main 提交以及 main 上的手动运行也可能直接正式发布；其他路径创建草稿。仅修改工作流也会触发运行，因此不能在未批准发布时把工作流补丁合入 main。
5. 正式发布前完成以下兼容性验证与真机覆盖安装。只有已发布的正式 Release 会进入应用更新检查。

已有同名草稿允许补齐附件；已有同名正式 Release 时停止，不重建或覆盖历史附件。迁移不得修改 v1.8.1+48 的既有资产，首次发布使用大于 48 且大于届时最新正式版本的构建号。


## APK 文件名与旧客户端兼容

- 规范名称：`shuyu-v<major>.<minor>.<patch>+<build>-<ABI>.apk`。
- 旧名兼容附件：`wenku8-local-v<major>.<minor>.<patch>+<build>-<ABI>.apk`。
- 当前只构建 `arm64-v8a`。`armeabi-v7a`、`x86_64` 和 `universal` 仅是解析器支持的后缀；未构建的架构不得发布或改名冒充。
- 每个版本、每个实际构建的 ABI 只构建签名一次，再复制为两个名称；发布前比较字节及 SHA-256。
- 新客户端同时接受 `shuyu-` 和 `wenku8-`，保留历史 `wenku8-*` 兼容。按设备 ABI 顺序选择，同 ABI 优先 `shuyu-`，最后才回退 `universal`；附件顺序不影响品牌优先级。
- 两种名称必须保留相同的 `-<ABI>.apk` 后缀。下载 URL 使用 GitHub API 返回的 `browser_download_url`，保留 `+` / `%2B` 兼容和现有 URL、大小、摘要校验。
- 旧版只读 `/releases/latest` 且只接受 `wenku8-`；只保留一个过渡 Release 无法覆盖跳过该版本的用户。每个后续正式 Release 持续保留旧名附件，不设自动删除期限。移除需另行评估并明确批准。
- 本次仅更改对外附件名称，不更改 applicationId、签名、版本比较、临时下载路径或用户数据目录。

渐进实施：

1. 先审查解析器、固定旧解析器测试和命名测试；不触发发布，也不改已发布附件。
2. 发布另行批准后，在新版本中启用双名称工作流和上述新解析器；所有检查通过后才允许正式发布。
3. 以后继续保留双名称。README 与 Release 说明引导手动下载新名称，旧名称仅为兼容入口。

验证命令：

```sh
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test test/app_updates_test.dart --reporter expanded
flutter test --reporter expanded --timeout 60s
python3 -m unittest discover -s tools -p 'test_*.py'
```

`test/fixtures/legacy_app_updates_v1_8_1_48.dart` 固定保留实际旧版解析器，验证跳过中间版本后仍能选择旧名附件；只给新名称的负例必须返回无适配附件。
Python 测试用临时 APK 字节和假的 `gh` 命令执行工作流的命名与发布脚本，验证草稿补齐、标签发布、main 发布、草稿创建均携带两个 APK 及源码，并拒绝覆盖已有正式 Release。
这些测试不上传资产或调用真实发布接口。

另需使用现有 v1.8.1+48 真机安装，保留书库和阅读进度，验证旧客户端识别新版本旧名附件、下载并覆盖安装；再验证新客户端选择新名附件。不得通过卸载重装验证数据保留。
新旧两名 APK 的 SHA-256 必须一致，覆盖安装应保持原有应用身份、证书及用户数据。

## 应用身份与签名

包名 org.mewx.wenku8_flutter 是现有安装的兼容标识，不代表签名相同。为保留旧版数据与升级路径暂时沿用。改变它会创建独立应用，必须先实现并验证迁移。正式构建缺少签名配置时失败；调试使用独立后缀。新建证书无法覆盖旧证书的安装。当前与上游及历史 APK 的证书指纹尚未核对，不能声称签名已隔离。

更新源默认 sushi342119/Shuyu；工作流明确传入当前仓库。APK 安装前验证包名、版本和签名。

## 第三方组件

保留 LICENSE、NOTICE、assets/licenses、字体许可与修改说明。libcpp.so 缺少源码，其独立授权依据仍需维护者核实并留存；不能把工程 ZIP 描述成该二进制的完整对应源码。参见 THIRD_PARTY.md。仅源码审阅可用 tools/export_public_source.py 的 --source-only 参数导出。
