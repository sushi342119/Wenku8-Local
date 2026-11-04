import 'app_typography.dart';

// Keep the original preference ID and filename: existing installations can
// reuse their downloaded face without a migration or another transfer.
const sourceHanFontId = 'sourceHanSerif';
const sourceHanFontFile = 'SourceHanSerifCN-2.003.otf';
const sourceHanFontBytes = 22613144;

class DownloadableFont {
  const DownloadableFont({
    required this.typeface,
    required this.fileName,
    required this.bytes,
    required this.description,
    required this.sourceUrls,
    this.traditional = false,
    this.archiveEntry,
    int? transferBytes,
  }) : transferBytes = transferBytes ?? bytes;

  final AppTypeface typeface;
  final String fileName, description;
  final int bytes, transferBytes;
  final List<String> sourceUrls;
  final bool traditional;
  final String? archiveEntry;
  String get id => typeface.name;
  String get name => typeface.label;
  String get sizeLabel => '${(transferBytes / 1048576).toStringAsFixed(1)} MiB';
  String get previewText => traditional ? '春日的光，落在書頁上。' : '春日的光，落在书页上。';
}

// Unmodified, fixed upstream releases. Only the catalogue and license text are
// bundled; no font, remote preview or font API is fetched on page load.
const downloadableFonts = [
  DownloadableFont(
    typeface: AppTypeface.sourceHanSerif,
    fileName: sourceHanFontFile,
    bytes: sourceHanFontBytes,
    description: '简体宋体 · 书页般的清晰与层次',
    sourceUrls: [
      'https://mirror.iscas.ac.cn/adobe-fonts/source-han-serif/Variable/OTF/Subset/SourceHanSerifCN-VF.otf',
      'https://raw.githubusercontent.com/adobe-fonts/source-han-serif/2.003R/Variable/OTF/Subset/SourceHanSerifCN-VF.otf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.sourceHanSans,
    fileName: 'SourceHanSansCN-2.005.otf',
    bytes: 15636088,
    description: '简体黑体 · 简洁利落，多种字重',
    sourceUrls: [
      'https://mirror.iscas.ac.cn/adobe-fonts/source-han-sans/Variable/OTF/Subset/SourceHanSansCN-VF.otf',
      'https://raw.githubusercontent.com/adobe-fonts/source-han-sans/2.005R/Variable/OTF/Subset/SourceHanSansCN-VF.otf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.lxgwWenKai,
    fileName: 'LXGWWenKaiGBScreen-1.530.ttf',
    bytes: 26456786,
    description: '简体文楷 · 为屏幕阅读调整笔画',
    sourceUrls: [
      'https://github.com/lxgw/LxgwWenKai-Screen/releases/download/v1.530/LXGWWenKaiGBScreen.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.zhuqueFangsong,
    fileName: 'ZhuqueFangsong-0.212.ttf',
    bytes: 8824084,
    transferBytes: 5743932,
    archiveEntry: 'ZhuqueFangsong-Regular.ttf',
    description: '简体仿宋 · 轻盈书卷气，字体预览版',
    sourceUrls: [
      'https://github.com/TrionesType/zhuque/releases/download/v0.212/ZhuqueFangsong-v0.212.zip',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.iansui,
    traditional: true,
    fileName: 'Iansui-1.020.ttf',
    bytes: 9447424,
    description: '繁体楷书 · 台湾字形与温润笔意',
    sourceUrls: [
      'https://raw.githubusercontent.com/ButTaiwan/iansui/v1.020/fonts/ttf/Iansui-Regular.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.lxgwZhenKai,
    fileName: 'LXGWZhenKaiSlabGB-0.827.ttf',
    bytes: 17453376,
    description: '简体楷书 · 饱满笔画，清楚耐读',
    sourceUrls: [
      'https://github.com/lxgw/LxgwZhenKai/releases/download/v0.827/LXGWZhenKaiSlabGB-Regular.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.lxgwMarkerGothic,
    fileName: 'LXGWMarkerGothic-1.004.ttf',
    bytes: 3190368,
    transferBytes: 3703389,
    archiveEntry:
        'LxgwMarkerGothic-v1.004/fonts/ttf/LXGWMarkerGothic-Regular.ttf',
    description: '简繁漫黑 · 轻快的马克笔笔触',
    sourceUrls: [
      'https://github.com/lxgw/LxgwMarkerGothic/releases/download/v1.004/LxgwMarkerGothic-v1.004.zip',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.xiaolai,
    fileName: 'Xiaolai-3.126.ttf',
    bytes: 22220806,
    description: '简繁手写 · 圆润活泼，字库较全',
    sourceUrls: [
      'https://github.com/lxgw/kose-font/releases/download/v3.126/Xiaolai-Regular.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.yozai,
    fileName: 'Yozai-Medium-0.868.ttf',
    bytes: 15238394,
    description: '简繁手写 · 自然舒展，中等字重',
    sourceUrls: [
      'https://github.com/lxgw/yozai-font/releases/download/v0.868/Yozai-Medium.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.sourceHanSerifTW,
    traditional: true,
    fileName: 'SourceHanSerifTW-2.003.otf',
    bytes: 15175972,
    description: '繁体宋体 · 台湾字形，多种字重',
    sourceUrls: [
      'https://mirror.iscas.ac.cn/adobe-fonts/source-han-serif/Variable/OTF/Subset/SourceHanSerifTW-VF.otf',
      'https://raw.githubusercontent.com/adobe-fonts/source-han-serif/2.003R/Variable/OTF/Subset/SourceHanSerifTW-VF.otf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.sourceHanSansTW,
    traditional: true,
    fileName: 'SourceHanSansTW-2.005.otf',
    bytes: 10495320,
    description: '繁体黑体 · 台湾字形，清晰均衡',
    sourceUrls: [
      'https://mirror.iscas.ac.cn/adobe-fonts/source-han-sans/Variable/OTF/Subset/SourceHanSansTW-VF.otf',
      'https://raw.githubusercontent.com/adobe-fonts/source-han-sans/2.005R/Variable/OTF/Subset/SourceHanSansTW-VF.otf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.lxgwWenKaiTC,
    traditional: true,
    fileName: 'LXGWWenKaiTC-1.530.ttf',
    bytes: 15341148,
    description: '繁体文楷 · 传承字形，柔和书写感',
    sourceUrls: [
      'https://github.com/lxgw/LxgwWenkaiTC/releases/download/v1.530/LXGWWenKaiTC-Regular.ttf',
    ],
  ),
  DownloadableFont(
    typeface: AppTypeface.openHuninn,
    traditional: true,
    fileName: 'jf-openhuninn-2.1.ttf',
    bytes: 4911464,
    description: '繁体圆体 · 台湾常用字，轻盈亲切',
    sourceUrls: [
      'https://github.com/justfont/open-huninn-font/releases/download/v2.1/jf-openhuninn-2.1.ttf',
    ],
  ),
];

DownloadableFont? downloadableFont(String id) =>
    downloadableFonts.where((font) => font.id == id).firstOrNull;
