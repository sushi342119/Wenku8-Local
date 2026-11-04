import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local_platform.dart';
import '../reader_tools.dart' show ReaderValueSlider;
import 'models.dart';

/// Older Harmony AVPlayer versions expose discrete decoder rates. The current
/// system and other hosts keep the existing continuous control.
class ListeningSpeedControl extends StatefulWidget {
  const ListeningSpeedControl({
    super.key,
    required this.value,
    required this.onCommitted,
    this.ratesLoader,
  });
  final double value;
  final ValueChanged<double> onCommitted;
  final Future<List<double>?> Function()? ratesLoader;

  @override
  State<ListeningSpeedControl> createState() => _ListeningSpeedControlState();
}

class _ListeningSpeedControlState extends State<ListeningSpeedControl> {
  Future<List<double>?>? _rates;

  @override
  void initState() {
    super.initState();
    if (widget.ratesLoader != null || LocalPlatform.harmony) {
      _rates = _load();
    }
  }

  Future<List<double>?> _load() async {
    if (widget.ratesLoader != null) return widget.ratesLoader!();
    final rates = await const MethodChannel(
      'org.mewx.wenku8/harmony_audio',
    ).invokeListMethod<num>('playbackRates');
    return rates == null || rates.isEmpty
        ? null
        : rates.map((rate) => rate.toDouble()).toList(growable: false);
  }

  Widget _slider([List<double>? rates]) {
    if (rates == null) {
      return ReaderValueSlider(
        sliderKey: const ValueKey('listening-speed'),
        label: '语速',
        value: widget.value,
        min: listeningMinimumSpeed,
        max: listeningMaximumSpeed,
        divisions: 50,
        format: (value) => '${value.toStringAsFixed(2)}×',
        onCommitted: widget.onCommitted,
      );
    }
    var nearest = 0;
    for (var i = 1; i < rates.length; i++) {
      if ((rates[i] - widget.value).abs() <
          (rates[nearest] - widget.value).abs()) {
        nearest = i;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReaderValueSlider(
          sliderKey: const ValueKey('listening-speed'),
          label: '语速',
          value: nearest.toDouble(),
          min: 0,
          max: (rates.length - 1).toDouble(),
          divisions: rates.length - 1,
          format: (value) => '${rates[value.round()].toStringAsFixed(2)}×',
          onCommitted: (value) => widget.onCommitted(rates[value.round()]),
        ),
        if (!rates.contains(widget.value))
          Text(
            '已保存的 ${widget.value.toStringAsFixed(2)}× 不受当前系统支持，请重新选择。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => _rates == null
      ? _slider()
      : FutureBuilder<List<double>?>(
          future: _rates,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return TextButton(
                onPressed: () => setState(() => _rates = _load()),
                child: const Text('语速能力读取失败，点击重试'),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 56,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return _slider(snapshot.data);
          },
        );
}
