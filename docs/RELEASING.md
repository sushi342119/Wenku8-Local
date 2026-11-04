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

工作流也可选择已有版本标签手动运行；已有同名 Release 时创建步骤会失败，避免静默覆盖。

## 应用身份与签名

包名 org.mewx.wenku8_flutter 是现有安装的兼容标识，不代表签名相同。为保留旧版数据与升级路径暂时沿用。改变它会创建独立应用，必须先实现并验证迁移。正式构建缺少签名配置时失败；调试使用独立后缀。新建证书无法覆盖旧证书的安装。当前与上游及历史 APK 的证书指纹尚未核对，不能声称签名已隔离。

更新源默认 sushi342119/Wenku8-Local；工作流明确传入当前仓库。APK 安装前验证包名、版本和签名。

## 第三方组件

保留 LICENSE、NOTICE、assets/licenses、字体许可与修改说明。libcpp.so 缺少源码，其独立授权依据仍需维护者核实并留存；不能把工程 ZIP 描述成该二进制的完整对应源码。参见 THIRD_PARTY.md。仅源码审阅可用 tools/export_public_source.py 的 --source-only 参数导出。
