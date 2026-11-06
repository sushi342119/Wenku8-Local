# 书屿构建与发布

开发环境：Flutter 3.41.5 / Dart 3.11.3、JDK 17。

## 日常验证

主分支提交与 PR 执行静态检查、Flutter 测试和 Python 工具测试。主分支还使用固定证书构建 ARM64 APK，见 Build Local APK 的 Artifacts。PR 不接触签名密钥。

## 正式发布

1. 同步更新 pubspec.yaml、lib/updates/app_updates.dart 中的版本、构建号及说明，以及 CHANGELOG.md。构建号必须大于已发布版本。
2. 配置 ANDROID_KEYSTORE_BASE64、ANDROID_STORE_PASSWORD、ANDROID_KEY_ALIAS、ANDROID_KEY_PASSWORD 四项 Actions Secrets。使用现有长期密钥，保留安全备份。
3. 执行 flutter pub get、flutter analyze、flutter test 和 Python 工具测试。
4. 推送与版本一致的标签，例如 v1.6.1+43。Prepare Release 验证版本、构建固定签名的 ARM64 APK、导出匹配源码并创建草稿 Release。
5. 检查草稿附件、许可条件与真机覆盖安装效果后，在 GitHub 发布草稿。只有已发布的正式 Release 会进入应用更新检查。

标签、主分支及手动触发均只创建草稿，不会直接发布正式版。工作流也可选择已有版本标签手动运行；已有同名 Release（包括草稿）时创建步骤会失败，不会替换已有附件。需要修订附件时增加构建号，生成新的版本与标签。

Prepare Release 在创建草稿前使用 Android SDK 验证候选 APK 与已发布的 v1.8.2+49 的实际包名和签名证书一致，且版本与本次配置匹配、构建号递增。基准包下载失败、签名无效或身份不兼容时停止发布。该检查不替代真机数据与覆盖安装验收。

## 应用身份与签名

包名 org.mewx.wenku8_flutter 是现有安装的兼容标识，不代表签名相同。为保留旧版数据与升级路径暂时沿用。改变它会创建独立应用，必须先实现并验证迁移。正式构建缺少签名配置时失败；调试使用独立后缀。新建证书无法覆盖旧证书的安装。当前与上游及历史 APK 的证书指纹尚未核对，不能声称签名已隔离。

更新源默认 sushi342119/Shuyu；工作流明确传入当前仓库。APK 安装前验证包名、版本和签名。

发布附件暂时保留 `wenku8-local-<标签>-arm64-v8a.apk` 文件名：现有更新器只识别 `wenku8-` 前缀及对应 ABI 后缀。修改应用显示名称或图标不需要修改 applicationId；文件名更名需要另行实现旧版更新兼容。

### 发布前兼容性验收

1. 下载 v1.8.1+48 的正式 APK 和候选 APK，使用 Android SDK 的 `apkanalyzer manifest application-id`、`apkanalyzer manifest version-code` 读取包名与构建号，使用 `apksigner verify --verbose --print-certs` 验证签名并记录证书 SHA-256 指纹。候选包必须沿用 `org.mewx.wenku8_flutter` 和现有发布证书，构建号严格增加。不得用 APK 文件本身的 SHA-256 摘要代替证书指纹。
2. 历史书屿 APK 与上游 APK 的证书分别核对；固定使用同一套 Secrets 不等于已证明与上游签名隔离。不得为隔离上游直接新建或替换发布证书。历史临时签名安装需单独验证。
3. 在测试设备安装正式旧版，导入 TXT、EPUB、PDF，建立书架、阅读进度、书签和标签并导出备份；随后直接覆盖安装候选包，不卸载、不清除数据。检查上述记录、小说正文、文件夹授权、重启后读取、备份导出与恢复以及应用内更新。
4. 验收完成后才手动发布草稿；未完成的证书或真机检查应明确记录，不能仅凭构建和单元测试通过声称升级兼容。

### 备份与换包限制

普通 JSON 备份包含书架、按书籍数字 ID 关联的阅读进度、书签、标签及部分设置，不包含本地书库 `local_books/index.json`、ID 分配状态 `local_library_next`、小说原书或离线正文，也不能转移 Android 文件夹授权。

更换 applicationId 会创建独立应用，新应用不能自动读取旧应用的私有数据。重新扫描会分配本地书籍 ID，普通备份按旧 ID 合并，可能无法关联原书，甚至把记录关联到不同书籍。现有云同步虽然可携带原书，也不能代替经过验证的跨安装书籍 ID 映射。当前不支持以“导入备份后重新扫描”保证完整换包迁移。

外部小说文件可以仍然存在，但新应用需要重新授权；旧应用私有目录中的原书、导入副本和正文不能自动接管。不要在迁移实现并验收前引导用户卸载旧应用或清除数据，这可能删除仅存于旧应用专属目录的文件。系统备份和设备迁移也不能作为跨包名恢复的保证。

## 第三方组件

保留 LICENSE、NOTICE、assets/licenses、字体许可与修改说明。libcpp.so 缺少源码，其独立授权依据仍需维护者核实并留存；不能把工程 ZIP 描述成该二进制的完整对应源码。参见 THIRD_PARTY.md。仅源码审阅可用 tools/export_public_source.py 的 --source-only 参数导出。
