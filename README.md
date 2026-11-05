<p align="center">
  <img src="assets/branding/app-icon.png" width="96" alt="书屿" />
</p>

<h1 align="center">书屿</h1>

<p align="center">基于 Flutter 的 Android 轻小说阅读客户端</p>

<p align="center">
  <a href="https://github.com/sushi342119/Shuyu/releases"><img src="https://img.shields.io/github/v/release/sushi342119/Shuyu?style=flat-square&color=60786B" alt="Release" /></a>
  <a href="https://github.com/sushi342119/Shuyu/actions/workflows/local-build.yml"><img src="https://github.com/sushi342119/Shuyu/actions/workflows/local-build.yml/badge.svg?branch=main" alt="Build" /></a>
  <img src="https://img.shields.io/badge/Platform-Android-60786B?style=flat-square" alt="Android" />
  <a href="assets/licenses/GPL-3.0.txt"><img src="https://img.shields.io/badge/License-GPL--3.0-60786B?style=flat-square" alt="GPL 3.0" /></a>
</p>

<p align="center">
  <a href="https://github.com/sushi342119/Shuyu/releases">下载</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="https://github.com/sushi342119/Shuyu/issues">问题反馈</a> ·
  <a href="docs/RELEASING.md">构建指南</a>
</p>

## 关于书屿

喜欢把小说收藏在本地，但文件越积越多，也越来越难整理。后来遇到了很喜欢的 [Wenku8_Flutter](https://github.com/mikufoxxx/Wenku8_Flutter)，便在它的基础上修改，做了更贴合自己需求的「书屿」。

相比所采用的原版，书屿移除了账号登录、云书架、签到、书评回复及旧版记录导入，将首页改为本地藏书；新增并完善了 TXT／PDF／EPUB 导入、自动扫描、标签整理、随机抽阅、文件重命名与删除、阅读进度及备份恢复。

分享出来，希望能帮助同样喜欢收藏小说文件的人。第一次做软件，难免有不足，还请多多包涵，欢迎反馈问题和建议。

感谢原作者及所有贡献者，保留原项目版权与开源许可声明。

## 功能特性

- **书籍发现**：分类、排行、书名与作者搜索（匿名使用，无需账号）。
- **立体书架**：循环轮播、惯性滚动、吸附定位与触觉反馈。
- **阅读排版**：字号、行距、深浅主题、系统字体与内置思源宋体，支持实时预览。
- **阅读工具**：章节目录、书签定位与高亮、章内查找、插图查看与分享。
- **离线阅读**：章节缓存、缓存管理、阅读历史、进度续读与本地备份。
- **在线听书**：中文音色、语速调节、段落跟随、睡眠定时、后台与锁屏控制。
- **本地阅读数据**：无账号体系，所有收藏、进度与缓存仅保存在本机，可通过本地备份迁移。
- **本地书库**：选择文件夹，扫描导入 TXT / PDF / EPUB；TXT 自动识别 UTF-8 / GB18030 编码并切分章节，PDF 逐页渲染阅读；新书自动上架，启动时静默自动扫描。
- **标签与整理**：自建标签库，给任意书打标签并在书架按标签筛选；详情页可编辑标签，设置页可管理标签。
- **随机选书**：书架一键随机抽一本，附带"换一本"。
- **信息修正**：本地书可在书库管理页手动修正书名/作者。
- **性能设置**：低性能设备模式，可独立调整玻璃折射、模糊、动效与立体书架。

## 下载

从 [GitHub Releases](https://github.com/sushi342119/Shuyu/releases) 下载 APK。当前版本提供 **arm64-v8a** 架构的 APK。

安装后，可在 **设置 → 关于书屿** 查看版本信息、更新说明并检查更新。

## 构建

开发环境：**Flutter 3.41.5 / Dart 3.11.3、JDK 17、Android SDK**。

```sh
git clone https://github.com/sushi342119/Shuyu.git
cd Shuyu
flutter pub get
flutter build apk --release --target-platform android-arm64
```

### GitHub Actions

- [Build Local APK](https://github.com/sushi342119/Shuyu/actions/workflows/local-build.yml)：代码检查、本地书库测试和 ARM64 APK 构建。

签名配置与发布流程见 [构建发布指南](docs/RELEASING.md)。

## 贡献

欢迎通过 [Issues](https://github.com/sushi342119/Shuyu/issues) 反馈问题或提出建议，通过 Pull Request 参与开发。提交问题时请提供应用版本、Android 版本和复现步骤。

## 致谢与许可

本项目借鉴了 [mikufoxxx/Wenku8_Flutter](https://github.com/mikufoxxx/Wenku8_Flutter)，并基于 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android) 重构。感谢 MewX、Baby Pepper（SeraphRoy）、Jack Liu（aaassseee）及原项目贡献者。

- 应用源码：保留原项目 [GPL v2 或后续版本声明](LICENSE)，本 Flutter 组合版本按 [GPL v3](assets/licenses/GPL-3.0.txt) 分发。
- 内置字体：[Adobe Source Han Serif CN](https://github.com/adobe-fonts/source-han-serif)，[SIL OFL 1.1](assets/fonts/OFL-SourceHanSerif.txt)。
- 在线语音协议适配：[rany2/edge-tts](https://github.com/rany2/edge-tts)，[LGPL v3](assets/licenses/edge-tts.txt)。

完整版权声明与接口运行库分发条件见 [NOTICE](NOTICE) 和 [第三方组件许可](docs/THIRD_PARTY.md)。

## 隐私说明

收藏、进度与缓存保存在设备本地。在线书库会访问内容服务；在线听书会把待朗读文本发送给 Microsoft 在线语音服务；检查更新会访问 GitHub。详见 [隐私说明](docs/PRIVACY.md)。

图标源文件为 `assets/branding/app-icon.png`。安装 Pillow 后执行 `python3 tools/generate_app_icons.py` 重新生成 Android 图标。
