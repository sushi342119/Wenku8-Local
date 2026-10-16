import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/reader_landing_highlight.dart';

void main() {
  testWidgets(
    'bookmark plane keeps text geometry, ends its clock and handles motion preference changes',
    (tester) async {
      var reduced = false;
      late StateSetter update;
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return Center(
                child: ReaderLandingHighlight(
                  reduceMotion: reduced,
                  child: Builder(
                    builder: (_) {
                      builds++;
                      return const Text('书签所在段落', key: ValueKey('target-text'));
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      final rect = tester.getRect(find.byKey(const ValueKey('target-text')));
      final initial = builds;
      await tester.pump(const Duration(milliseconds: 200));
      expect(builds, initial);
      expect(tester.getRect(find.byKey(const ValueKey('target-text'))), rect);
      expect(find.byType(Opacity), findsNothing);
      update(() => reduced = true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      update(() => reduced = false);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
