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

Flutter 3.41.5、Dart 3.11.3、JDK 17、Android SDK。源码包中保留的 Gradle wrapper 用于复现构建；Flutter、Gradle 及依赖首次构建需要下载。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
cd android
./gradlew :app:testReleaseUnitTest
```

未配置签名时输出为本地预览包，使用调试证书。正式分发前，在本机创建 `android/key.properties`，设置 `storeFile`（相对于 android 的路径或绝对路径）、`storePassword`、`keyAlias`、`keyPassword`，使用自己的签名证书。密钥文件和 keystore 已加入忽略规则，不要上传。

同一包名的后续升级必须使用同一签名证书。当前包名为 `org.mewx.wenku8_flutter`；修改包名会创建独立应用，不能直接沿用原应用的数据。

自动化检查验证代码和预览构建；实际联网、系统语音、锁屏媒体控件和不同 Android 系统的显示效果仍需对应设备验收。

## 用 GitHub Actions 构建 APK

在 GitHub 打开 **Actions → Build Android APKs → Run workflow**。构建完成后，在该次运行的 **Artifacts** 下载压缩包，内含 ARM64、ARMv7、x86_64 APK、源码 ZIP 和本版说明。无需开通付费语音或更新服务。

手动运行未配置签名时使用临时 Runner 的调试证书，只用于预览；它不能保证覆盖上次安装。要持续升级，先在仓库 **Settings → Secrets and variables → Actions** 配置同一套长期签名：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 Base64 内容 |
| `ANDROID_KEY_ALIAS` | 密钥别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 |
| `ANDROID_STORE_PASSWORD` | keystore 密码 |

不要把签名文件或这些值提交到 Git；工作流只在临时目录解码，任务结束清除。已有本地预览版必须使用原来的签名才能覆盖；改用新签名以前先导出阅读记录，不要直接卸载现有应用。

## 发布一个可被应用检测的版本

1. 更新 `pubspec.yaml` 的版本号和更大的 Android 构建号，并同步 `lib/updates/app_updates.dart` 的本版说明与版本常量。
2. 在 `CHANGELOG.md` 添加对应版本的说明。运行 `python3 tools/prepare_release.py --tag v0.2.3 --notes build/release-notes.md` 可检查当前版本与标签是否一致。
3. 提交到自己的 Fork 后，推送与版本一致的标签，例如当前版本用 `v0.2.3`。本地整理脚本不会推送。
4. Actions 完成检查和三架构构建，上传 APK / 工程源码并创建 **Draft Release**。先核对签名、工程归档、脱敏与第三方条件，再点击 **Publish release**。
5. 已安装应用会在下次前台检查时显示新版本；也可以在「关于轻小说文库」立即检查。草稿、预发布和普通 Actions Artifacts 不进入自动更新渠道。

正式标签构建缺少四项签名配置时会直接失败，不会用每次变化的临时证书发布更新。重跑只可替换草稿附件，不覆盖已发布版本；有修订时增加版本号再发布。

更新源默认为 `mikufoxxx/Wenku8_Flutter`。发布工作流将 `${{ github.repository }}` 写入 `UPDATE_REPOSITORY`，因此他人 Fork 的构建检查自己的 Releases。本地构建可用 `--dart-define=UPDATE_REPOSITORY=用户名/仓库名` 指定。应用不包含 GitHub Token，不收集账号或阅读内容；自动检查可关闭。

下载使用 HTTPS 和受限的 GitHub 资源地址，使用 GitHub 提供的 SHA-256 摘要（如有）核验完整性。安装前还必须通过 Android 包名、版本和签名检查，首次安装授权及最终确认由系统界面完成。下载可取消，断线或校验失败不会进入安装步骤。
