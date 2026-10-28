import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_text_worker_client.dart';

void _neverReady(SendPort ready) => ReceivePort().listen((_) {});

void _neverReplies(SendPort ready) {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((_) {});
}

void _worker(SendPort ready) {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  requests.listen((message) {
    final (reply, job) = message as (SendPort, Map<String, Object?>);
    if (job['exit'] == true) Isolate.exit();
    if (job['exitOnce'] case final String path) {
      final marker = File(path);
      if (!marker.existsSync()) {
        marker.writeAsStringSync('exited');
        Isolate.exit();
      }
    }
    if (job['error'] == true) {
      reply.send([
        false,
        const FormatException('invalid text'),
        StackTrace.current,
      ]);
    } else if (job['exitAfterReply'] == true) {
      Isolate.exit(reply, [true, 'ok']);
    } else {
      reply.send([true, 'ok']);
    }
  });
}

void main() {
  test('missing ready and missing reply both fail within two attempts', () async {
    for (final entry in [_neverReady, _neverReplies]) {
      final client = LocalTextWorkerClient(
        entry,
        readyTimeout: const Duration(milliseconds: 200),
        replyTimeout: const Duration(milliseconds: 100),
      );
      try {
        await expectLater(
          client.run({}).timeout(const Duration(seconds: 2)),
          throwsA(isA<TextWorkerUnavailable>()),
        );
        // A timed out request cannot leave the next request permanently queued.
        await expectLater(
          client.run({}).timeout(const Duration(seconds: 2)),
          throwsA(isA<TextWorkerUnavailable>()),
        );
      } finally {
        client.dispose();
      }
    }
  });

  test(
    'exit during request rebuilds once and restores later requests',
    () async {
      final root = await Directory.systemTemp.createTemp('worker-exit-');
      final client = LocalTextWorkerClient(_worker);
      addTearDown(() async {
        client.dispose();
        await root.delete(recursive: true);
      });
      expect(
        await client
            .run({'exitOnce': '${root.path}/marker'})
            .timeout(const Duration(seconds: 3)),
        'ok',
      );
      expect(await client.run({}), 'ok');
      await expectLater(
        client.run({'exit': true}).timeout(const Duration(seconds: 3)),
        throwsA(isA<TextWorkerUnavailable>()),
      );
      expect(await client.run({}), 'ok');
    },
  );

  test(
    'idle exit clears old port; application errors do not poison transport',
    () async {
      final client = LocalTextWorkerClient(_worker);
      addTearDown(client.dispose);
      expect(await client.run({'exitAfterReply': true}), 'ok');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await client.run({}).timeout(const Duration(seconds: 3)), 'ok');
      await expectLater(client.run({'error': true}), throwsFormatException);
      expect(await client.run({}), 'ok');
    },
  );

  test('dispose fails an in-flight request and queued requests', () async {
    final client = LocalTextWorkerClient(_neverReplies);
    final pending = client.run({});
    final result = expectLater(pending, throwsA(isA<TextWorkerUnavailable>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.dispose();
    await result.timeout(const Duration(seconds: 2));
    await expectLater(client.run({}), throwsStateError);
  });
}
