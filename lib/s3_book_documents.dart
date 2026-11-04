import 'dart:convert';
import 'dart:io';

import 'book_documents.dart';
import 'cloud_sources.dart';

/// S3 implements the same read/merge/conditional-write boundary as a system
/// document. Recovery files remain local and contain no connection secrets.
class S3BookDocuments extends BookDocuments {
  S3BookDocuments({
    required this.connection,
    required this.directory,
    S3SyncObjectClient? client,
  }) : client = client ?? S3SyncObjectClient(connection);

  final S3SyncConnection connection;
  final Directory directory;
  final S3SyncObjectClient client;
  S3ObjectRevision? _revision;
  File? _before;
  File _file(String name) => File('${directory.path}/$name');
  String get identity => jsonEncode([
    connection.config.address,
    connection.config.bucket,
    connection.config.pathStyle,
    connection.objectKey,
  ]);

  @override
  Future<Map<String, dynamic>> info() async => {
    'provider': 'S3',
    'name': '${connection.config.bucket}/${connection.objectKey}',
    // A missing object is a valid initial state. An existing empty object is
    // rejected by the bounded S3 download instead of being overwritten.
    'created': true,
  };

  @override
  Future<({File before, File output})> read() async {
    await directory.create(recursive: true);
    _revision = null;
    _before = null;
    final pending = _file('incoming');
    final revision = await client.read(pending);
    final before = await pending.rename(_file('before').path);
    await _file('before-target').writeAsString(identity, flush: true);
    _revision = revision;
    _before = before;
    return (before: before, output: _file('next'));
  }

  @override
  Future<void> write(File before, File next) async {
    final revision = _revision;
    if (revision == null || before.path != _before?.path) {
      throw const FormatException('请先重新读取云端，再合并同步');
    }
    // Invalidate before sending: even an unconfirmed request cannot be resent
    // from the old snapshot. The next sync must GET and merge again.
    _revision = null;
    await _file('next-target').writeAsString(identity, flush: true);
    await client.write(next, revision);
  }

  @override
  Future<File?> recovery(String which) async {
    if (which != 'before' && which != 'next') return null;
    final file = _file(which);
    final target = _file('$which-target');
    if (!await file.exists() ||
        !await target.exists() ||
        await target.readAsString() != identity) {
      return null;
    }
    return file;
  }

  void close() => client.close();
}
