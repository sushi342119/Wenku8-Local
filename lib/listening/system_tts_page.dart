import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../local_platform.dart';
import '../app_ui.dart';
import '../feature_pages.dart';
import 'cache.dart';
import 'models.dart';

class SystemSpeechEngine {
  const SystemSpeechEngine(this.id, this.name);
  final String id, name;
  SpeechVoice get defaultVoice => SpeechVoice(
    id: '@default',
    label: name,
    source: ListeningSource.system,
    engine: id,
  );
}

/// Discovery never initializes every installed engine or generates speech.
class SystemSpeechCatalog {
  const SystemSpeechCatalog();
  Future<List<SystemSpeechEngine>> engines() async {
    final raw =
        await SpeechAudioCache.system
            .invokeListMethod<dynamic>('engines')
            .timeout(const Duration(seconds: 8)) ??
        [];
    return [
      for (final item in raw)
        if (item is Map &&
            item['id'] is String &&
            supportedSystemSpeechEngine(item['id']))
          SystemSpeechEngine(item['id'], '${item['name'] ?? item['id']}'),
    ];
  }

  Future<List<SpeechVoice>> voices(SystemSpeechEngine engine) async {
    final raw =
        await SpeechAudioCache.system
            .invokeListMethod<dynamic>('voices', {'engine': engine.id})
            .timeout(const Duration(seconds: 25)) ??
        [];
    return [
      engine.defaultVoice,
      for (final item in raw)
        if (item is Map &&
            item['id'] is String &&
            item['locale'] is String &&
            !(item['features'] is List &&
                (item['features'] as List).contains('notInstalled')))
          SpeechVoice(
            id: item['id'],
            label: systemSpeechVoiceLabel(item),
            locale: item['locale'],
            source: ListeningSource.system,
            engine: engine.id,
            offline: item['networkRequired'] == false,
            quality: item['quality'] is int ? item['quality'] : 0,
          ),
    ];
  }

  Future<void> settings() =>
      SpeechAudioCache.system.invokeMethod<void>('settings');
}

class SystemSpeechEnginesPanel extends StatefulWidget {
  const SystemSpeechEnginesPanel({
    super.key,
    required this.selected,
    this.catalog = const SystemSpeechCatalog(),
  });
  final SpeechVoice selected;
  final SystemSpeechCatalog catalog;
  @override
  State<SystemSpeechEnginesPanel> createState() =>
      _SystemSpeechEnginesPanelState();
}

class _SystemSpeechEnginesPanelState extends State<SystemSpeechEnginesPanel>
    with WidgetsBindingObserver {
  List<SystemSpeechEngine> _engines = const [];
  List<SpeechVoice>? _voices;
  SystemSpeechEngine? _engine;
  bool _busy = true;
  String? _error;
  bool _voiceHelp = false;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load([SystemSpeechEngine? engine]) async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
      _engine = engine;
      _voices = null;
    });
    try {
      if (engine == null) {
        final value = await widget.catalog.engines();
        if (mounted && request == _request) setState(() => _engines = value);
      } else {
        final value = await widget.catalog.voices(engine);
        if (mounted && request == _request) setState(() => _voices = value);
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _error = error is PlatformException
              ? error.message ?? '引擎暂不可用，请重试'
              : '未能读取系统引擎，请重试',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(_engine);
  }

  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _settings() async {
    if (LocalPlatform.ios || LocalPlatform.harmony) {
      setState(() => _voiceHelp = !_voiceHelp);
      return;
    }
    try {
      await widget.catalog.settings();
    } catch (_) {
      if (mounted) setState(() => _error = '请在手机设置中搜索「文字转语音」');
    }
  }

  bool _chosen(SpeechVoice voice) =>
      voice.source == widget.selected.source &&
      voice.engine == widget.selected.engine &&
      voice.id == widget.selected.id;
  int get _count => _engine == null ? _engines.length : _voices?.length ?? 0;

  Widget _engineRow(SystemSpeechEngine engine) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: GlassTextButton(
            key: ValueKey('system-engine-${engine.id}'),
            onPressed: () => Navigator.pop(context, engine.defaultVoice),
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    engine.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (widget.selected.source == ListeningSource.system &&
                    widget.selected.engine == engine.id)
                  const ArchiveIcon(CupertinoIcons.checkmark, size: 16),
              ],
            ),
          ),
        ),
        GlassIconButton(
          icon: CupertinoIcons.slider_horizontal_3,
          label: '${engine.name}的音色',
          onPressed: () => _load(engine),
        ),
      ],
    ),
  );

  Widget _voiceRow(SpeechVoice voice) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: GlassTextButton(
      key: ValueKey('system-voice-${voice.id}'),
      onPressed: () => Navigator.pop(context, voice),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  voice.id == '@default' ? '引擎默认音色' : voice.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                if (voice.id != '@default')
                  AppText(
                    '${voice.locale} · ${voice.offline ? '可离线' : '需要网络'}',
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ),
          if (_chosen(voice))
            const ArchiveIcon(CupertinoIcons.checkmark, size: 16),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .64,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 14, 12),
          child: Row(
            children: [
              if (_engine != null)
                GlassIconButton(
                  icon: CupertinoIcons.back,
                  label: '返回引擎列表',
                  onPressed: () => _load(),
                ),
              Expanded(
                child: ArchiveSection(
                  title: _engine?.name ?? '朗读引擎',
                  code: 'AUDIO / SYSTEM ENGINES',
                ),
              ),
              GlassIconButton(
                icon: CupertinoIcons.refresh,
                label: '重新检测引擎',
                onPressed: _busy ? null : () => _load(_engine),
              ),
              GlassIconButton(
                icon: CupertinoIcons.xmark,
                label: '关闭朗读引擎',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            key: ValueKey(_engine?.id ?? 'engines'),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            itemCount: _count + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(child: CupertinoActivityIndicator()),
                      ),
                    FeatureError(_error),
                    if (_engine == null &&
                        !_busy &&
                        _engines.isEmpty &&
                        _error == null)
                      AppText(
                        LocalPlatform.harmony
                            ? '此设备没有提供系统语音服务，可选择在线音色或自定义接口。'
                            : '没有检测到系统 TTS 引擎。安装支持文字转语音的引擎后，点右上角重新检测。',
                      ),
                  ],
                );
              }
              if (index <= _count) {
                return _engine == null
                    ? _engineRow(_engines[index - 1])
                    : _voiceRow(_voices![index - 1]);
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 16),
                  GlassTextButton(
                    onPressed: _settings,
                    child: AppText(
                      LocalPlatform.ios
                          ? '如何添加系统音色'
                          : LocalPlatform.harmony
                          ? '系统音色说明'
                          : '系统语音设置',
                    ),
                  ),
                  AnimatedOptionSection(
                    expanded: _voiceHelp,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: AppText(
                        LocalPlatform.harmony
                            ? '这里只列出设备已安装的系统音色。系统音色变更后，返回此页会自动刷新；也可使用在线音色或自定义接口。'
                            : '在系统设置的「辅助功能 → 阅读与朗读 → 声音」下载音色；旧版系统中叫「朗读内容」。完成后回到这里，列表会自动刷新。',
                        style: const TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  AppText(
                    '引擎由手机提供，是否联网及可用音色取决于引擎。这里只选择引擎，不自动试听。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
