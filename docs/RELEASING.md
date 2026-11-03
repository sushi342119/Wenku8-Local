# 整理公开版本

在项目根目录执行：

```sh
python3 tools/export_public_source.py ../Wenku8_Flutter-release
```

生成目录可作为 GitHub 上传的 Flutter 源文件。继续使用原 Fork 时，保留原仓库的历史与署名，将对应文件加入现有仓库即可。导出保留 Flutter 源码、测试、资源、平台工程和许可，排除本机路径、密钥、真机截图与日志、语音探测工具、内部开发记录、旧版 Android 构建目录和独立性能探针。目标目录必须为空，脚本不会覆盖现有文件，也不会执行 Git 操作。

## 先保留许可与第三方条件

原项目 `LICENSE` 保留 GPL version 2 或后续版本条款；本 Flutter 组合版本使用 GPL version 3，以兼容 LGPL v3 的在线语音协议适配。发布时提供 Flutter 工程归档、原始 `LICENSE`、`NOTICE`、`assets/licenses/` 及字体 OFL 原文，保留署名和修改日期。不要将衍生项目改标为仅有 MIT 或 Apache 许可。完整来源见 [第三方组件与条件](THIRD_PARTY.md)。

字体使用 SIL OFL 1.1；协议适配保留 LGPL v3。原版 API 二进制的原样再分发条件单独适用，不从主仓库 GPL 许可推导。

## 联网接口的运行库

当前 Android 接口通过 `TokenManager` 加载原版文库应用内嵌的 `libcpp.so`。它是现有联网功能的组成部分，整理工程时原样保留，不归入开发工具或个人数据清理范围。

这个工作区只有预编译运行库，没有对应 JNI 源码。项目维护者于 2026-10-15 确认该组件允许原样再分发；本分支保留原文件，不修改其内容或接口。此独立授权组件不纳入应用源码的 GPL 授权，也不能将工程 ZIP 描述为它的完整对应源码。超出原样再分发条件时需联系原版权方。

保留的文件位于 `android/app/src/main/jniLibs/<abi>/libcpp.so`。如果只希望导出不含该库的源码供审阅，可以执行下面的命令；这样生成的 APK 无法调用现有文库联网接口。不要将个人会话、账号文件或从手机导出的数据放进工程。

```sh
python3 tools/export_public_source.py ../Wenku8_Flutter-source-only --source-only
```

## 签名与构建

开发环境：Flutter 3.41.5、Dart 3.11.3、JDK 17 和 Android SDK。先配置 `android/key.properties` 和固定的发布密钥，再执行：

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

`key.properties` 包含 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。不要提交密钥或密码。发布构建不再自动使用调试证书；未配置密钥时不会生成已签名的可分发版本。调试预览使用 debug 构建。

新的正式应用 ID 是 `com.github.sushi342119.wenku8local`。它与旧版及借鉴项目的 `org.mewx.wenku8_flutter` 不同，Android 会把新版当作独立应用，而非旧版升级；旧版用户需要手动迁移数据。旧版本不要卸载或清除数据，直到完成迁移并核对。

### 从旧包名迁移

1. 在旧版的“备份与恢复”中导出备份文件，保存到应用外部并保留原文件。备份包含书架和阅读记录等，但不包含离线正文或账号信息，也不保证迁移本地书籍文件及文件夹授权。
2. 安装新版；旧版应仍保留在设备上。在新版导入备份，并检查书架、进度、书签和标签。
3. 重新选择本地书籍文件夹并扫描，检查本地书籍、进度和授权。旧版应用私有目录中的书籍需先复制或导出到可访问的位置。重新下载所需的离线内容。
4. 完成真机核验前保留旧版和备份。不同版本的本地书籍 ID 或文件访问方式可能不同，本流程尚需真机验证，不能保证全部数据自动关联。

更换应用 ID 或签名后，旧 APK 不能作为新版的覆盖更新。保持新版的发布签名稳定，并在分发前在设备上验证首次安装、旧版并存、备份恢复、本地书籍和后续更新。

## 用 GitHub Actions 构建 APK

打开 **Actions → Build Local APK → Run workflow**。工作流运行静态检查和 `test/local_library_test.dart`，然后构建 ARM64 release APK 并上传为 Actions artifact；它不会创建 GitHub Release。构建需要在仓库 Actions Secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |
| `ANDROID_STORE_PASSWORD` | keystore 密码 |

不要将密钥或这些值提交到 Git。每次发布都应使用同一套长期签名，并在发布前检查 APK 的包名、版本号和证书。

## 发布更新

更新 `pubspec.yaml` 的版本名和递增的 Android 构建号，同步 `lib/updates/app_updates.dart` 和更新日志。构建并测试 APK 后，手动创建 GitHub Release 并上传 APK；普通 Actions artifact 不会进入更新渠道。发布前在真机上测试安装及升级，并保留可恢复的用户数据。

应用默认从 `sushi342119/Wenku8-Local` 检查 Release，版本页面也限制在该仓库。仓库迁移时需同时修改 Dart 更新源和 Android 的页面地址校验。安装前应用会检查包名、版本和签名；系统仍会要求用户确认安装。
