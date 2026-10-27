import 'package:flutter_test/flutter_test.dart';
import 'package:wenku8_flutter/local_source_identity.dart';

void main() {
  test('旧 appFolder 记录在当前选择 SAF 时仍与 appFolder 扫描同键', () {
    const path = '/data/user/0/app/files/novels/a.txt';
    const tree = 'content://provider/tree/novels';
    final oldBook = LocalSourceIdentity.forBook(
      sourceId: '',
      sourceKey: '',
      fileUri: path,
      folderUri: tree,
    );
    final scanned = LocalSourceIdentity.appFolder(path);
    final ignored = {oldBook.ignoredKey};
    expect(oldBook.sourceId, 'appFolder:novels');
    expect(ignored.contains(scanned.ignoredKey), isTrue);
    expect(
      oldBook.ignoredKey,
      isNot(LocalSourceIdentity.saf(tree, path).ignoredKey),
    );
  });

  test('旧 appFolder 记录 file:// 定位符仍与 appFolder 扫描同键', () {
    const path = '/data/user/0/app/files/novels/a.txt';
    final oldBook = LocalSourceIdentity.forBook(
      sourceId: '',
      sourceKey: '',
      fileUri: 'file://$path',
      folderUri: 'content://provider/tree/novels',
    );
    expect(
      oldBook.ignoredKey,
      LocalSourceIdentity.appFolder(path).ignoredKey,
    );
  });

  test('旧 SAF 记录与当前 SAF 扫描同键', () {
    const tree = 'content://provider/tree/novels';
    const document =
        'content://provider/tree/novels/document/novels%2Fa.txt';
    final oldBook = LocalSourceIdentity.forBook(
      sourceId: '',
      sourceKey: '',
      fileUri: document,
      folderUri: tree,
    );
    expect(
      oldBook.ignoredKey,
      LocalSourceIdentity.saf(tree, document).ignoredKey,
    );
  });

  test('旧 SAF 记录的树从自身 URI 取，不借用当前已换的目录', () {
    const oldTree = 'content://provider/tree/old';
    const newTree = 'content://provider/tree/new';
    const document = 'content://provider/tree/old/document/old%2Fa.txt';
    final oldBook = LocalSourceIdentity.forBook(
      sourceId: '',
      sourceKey: '',
      fileUri: document,
      folderUri: newTree,
    );
    expect(
      oldBook.ignoredKey,
      LocalSourceIdentity.saf(oldTree, document).ignoredKey,
    );
    expect(
      oldBook.ignoredKey,
      isNot(LocalSourceIdentity.saf(newTree, document).ignoredKey),
    );
  });

  test('旧 SAF 记录无树身份时抛错，不生成猜测的忽略键', () {
    expect(
      () => LocalSourceIdentity.forBook(
        sourceId: '',
        sourceKey: '',
        fileUri: 'content://provider/document/a.txt',
        folderUri: 'content://provider/tree/new',
      ),
      throwsStateError,
    );
  });

  test('已知来源不受当前选择的文件夹影响', () {
    final source = LocalSourceIdentity.forBook(
      sourceId: 'saf:content://provider/tree/old',
      sourceKey: 'content://provider/document/a',
      fileUri: 'content://provider/document/a',
      folderUri: 'content://provider/tree/new',
    );
    expect(source.sourceId, 'saf:content://provider/tree/old');
  });
}
