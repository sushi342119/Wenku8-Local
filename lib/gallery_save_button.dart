import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'harmony_gallery_save_button.dart';
import 'local_platform.dart';

String gallerySaveFailureMessage(Object error) =>
    error is PlatformException && error.message?.trim().isNotEmpty == true
    ? error.message!
    : '图片未保存到相册，请重试';

/// The same user action across hosts. Harmony's actual native SaveButton grants
/// a one-use photo write; it must remain visible, solid and unobscured.
/// Give the native control at least [minimumWidth] × [height] logical pixels.
class GallerySaveButton extends StatefulWidget {
  const GallerySaveButton({
    super.key,
    this.enabled = true,
    required this.foreground,
    required this.background,
    required this.onSave,
    required this.onError,
    required this.builder,
  });

  static const double minimumWidth = 120;
  static const double height = 44;
  final bool enabled;
  final Color foreground, background;
  final Future<void> Function(String? authorizationToken) onSave;
  final ValueChanged<PlatformException> onError;
  final Widget Function(VoidCallback? onPressed) builder;

  @override
  State<GallerySaveButton> createState() => _GallerySaveButtonState();
}

class _GallerySaveButtonState extends State<GallerySaveButton> {
  MethodChannel? _native;
  bool _saving = false;
  bool get _enabled => widget.enabled && !_saving;

  Future<void> _save(String? token) async {
    if (!_enabled) return;
    setState(() => _saving = true);
    _configure();
    try {
      await widget.onSave(token);
    } catch (error) {
      if (mounted) {
        widget.onError(
          error is PlatformException
              ? error
              : PlatformException(
                  code: 'gallery_save',
                  message: gallerySaveFailureMessage(error),
                ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        _configure();
      }
    }
  }

  void _created(int id) {
    _native?.setMethodCallHandler(null);
    _native = MethodChannel('org.mewx.wenku8/gallery_save_button/$id');
    _native!.setMethodCallHandler((call) async {
      if (!mounted || !_enabled) return;
      final arguments = call.arguments;
      if (arguments is! Map) return;
      if (call.method == 'authorized') {
        final token = arguments['authorizationToken'];
        if (token is String && token.isNotEmpty) await _save(token);
      } else if (call.method == 'authorizationFailed') {
        widget.onError(
          PlatformException(
            code: arguments['code'] as String? ?? 'gallery_permission',
            message: arguments['message'] as String? ?? '未允许保存到相册，请重试',
          ),
        );
      }
    });
    _configure();
  }

  void _configure() {
    _native
        ?.invokeMethod<void>('configure', {
          'enabled': _enabled,
          'foreground': widget.foreground.toARGB32(),
          'background': widget.background.toARGB32(),
        })
        .catchError((Object error) {
          if (mounted) {
            widget.onError(
              PlatformException(
                code: 'gallery_unavailable',
                message: '相册保存按钮尚未就绪，请重新打开此页面',
              ),
            );
          }
        });
  }

  @override
  void didUpdateWidget(GallerySaveButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.foreground != widget.foreground ||
        oldWidget.background != widget.background) {
      _configure();
    }
  }

  @override
  void dispose() {
    _native?.setMethodCallHandler(null);
    _native = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!LocalPlatform.harmony) {
      return widget.builder(_enabled ? () => _save(null) : null);
    }
    return SizedBox(
      height: GallerySaveButton.height,
      child: harmonyGallerySaveButtonView(
        enabled: _enabled,
        foreground: widget.foreground,
        background: widget.background,
        onCreated: _created,
      ),
    );
  }
}
