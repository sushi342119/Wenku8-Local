# 第三方组件与分发条件

## 应用源码

基于 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android) 与原贡献者的工作。原始 [LICENSE](../LICENSE) 保留 GNU GPL version 2 或后续版本条款。本次 Flutter 组合版本按 [GPL version 3](../assets/licenses/GPL-3.0.txt) 分发，以兼容 LGPL v3 的协议适配代码。保留原署名、修改说明和构建脚本；发布 APK 时一并提供对应 Flutter 工程归档。

## 原版 API 运行库：libcpp.so

- 路径：`android/app/src/main/jniLibs/<abi>/libcpp.so`。
- 用途：现有文库联网接口的 JNI 运行库。
- 本分支不修改、不解包、不重新实现该二进制。
- 项目维护者于 2026-10-15 确认其可在**保持原样**的条件下再分发。本仓库据此保留原文件。
- 该组件的源码不在本工程中；不能将应用源码的 GPL 许可视为对该组件源码、修改权或其他用途的授权。需要超出原样再分发条件时，应联系原版权方。
- 原项目当前公开构建使用 [api-stub](https://github.com/MewX/light-novel-library_Wenku8_Android/blob/master/studio-android/LightNovelLibrary/settings.gradle)，因此本工程源码归档不应被描述为该二进制的完整对应源码。

如只需审阅可编辑源码，导出时增加 `--source-only`。缺少这个运行库的构建不能使用现有文库联网接口。

## 内置字体：Adobe 思源宋体 CN

使用 Adobe 官方发布的 CN 子集 Regular / Bold 原始字体，未提取或分发 OPPO 系统字体。

- [官方仓库](https://github.com/adobe-fonts/source-han-serif)
- [SIL Open Font License 1.1 原文与版权声明](../assets/fonts/OFL-SourceHanSerif.txt)
- [文件来源](../assets/fonts/README.md)

字体维持自己的 OFL 许可，不随应用改标为 GPL。

## 在线听书协议

`lib/listening/edge_protocol.dart` 为 [rany2/edge-tts](https://github.com/rany2/edge-tts) v2 校验算法的 Dart 适配，参考提交 `bd44c1d1aaebdc1db7f47456ee12431b42ec7cac`，修改日期 2026-10-15。遵循 LGPL v3；[完整许可](../assets/licenses/edge-tts.txt) 与 GPL v3 原文随源码和应用提供。代码可在本工程中替换、修改后重新构建，构建不依赖私有密钥。

在线音色由 Microsoft Edge 在线语音服务提供。代码许可不授予该服务的所有权或可用性保证；不包含付费凭证。朗读会将待合成文本发送给该服务，缓存仅保留在设备本地。

## Flutter 与依赖包

依赖版本锁定于 `pubspec.lock`。Flutter、Cupertino Icons、音频与存储插件保留各自许可；Flutter 构建生成的许可集合可在 **设置 → 关于轻小说文库 → 开源许可与字体授权** 查看。该页面也包括上面的内置字体与协议适配声明。

液态玻璃基于 [liquid_glass_easy 5.0.0](https://pub.dev/packages/liquid_glass_easy/versions/5.0.0)，作者 Ahmed Gamil，使用 MIT License。源码和原许可保留于 [`third_party/liquid_glass_easy`](../third_party/liquid_glass_easy)；本地 GPU 性能修改单独记录在 [`PATCHES.md`](../third_party/liquid_glass_easy/PATCHES.md)。应用保留原作者署名，版权与许可随源码及 Flutter 的开源许可集合分发。

## 内容与展示图

小说、封面、插图归各自权利人所有，不包含在源码许可中。README 展示图使用独立演示数据、程序绘制封面，不包含个人账号、阅读记录或真实设备通知。
