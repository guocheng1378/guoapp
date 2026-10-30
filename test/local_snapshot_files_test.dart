import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/local_snapshot_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemorySnapshotFiles', () {
    test('write、delete、loadAll 往返', () async {
      final files = MemorySnapshotFiles();
      expect(files.isReady, isTrue);
      expect(files.loadAll(), isEmpty);
      expect(files.containsKey('favorites'), isFalse);

      await files.write('favorites', '{"a":1}');
      expect(files.loadAll(), {'favorites': '{"a":1}'});
      expect(files.containsKey('favorites'), isTrue);
      expect(files.length, 1);

      await files.delete('favorites');
      expect(files.loadAll(), isEmpty);
      expect(files.length, 0);
      // 重复删除安全（LocalSnapshot 提交路径不保证删除只发生一次）。
      await files.delete('favorites');
      expect(files.loadAll(), isEmpty);
    });

    test('initial 种子数据在实例间共享即模拟重启', () async {
      final seed = MemorySnapshotFiles(
        initial: {'favorites': '[]', 'history': '[]'},
      );
      final reader = MemorySnapshotFiles(
        initial: Map.of(seed.loadAll()),
      );
      expect(reader.loadAll(), {'favorites': '[]', 'history': '[]'});
    });
  });

  group('decodeSnapshotFileBytes', () {
    test('gzip 魔数（1F 8B）解压', () {
      const text = '{"favorites":["a"]}';
      expect(
        decodeSnapshotFileBytes(gzip.encode(utf8.encode(text))),
        text,
      );
    });

    test('迁移窗口期明文回退', () {
      const text = '{"favorites":["a"]}';
      expect(decodeSnapshotFileBytes(utf8.encode(text)), text);
    });
  });

  group('DirectorySnapshotFiles', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('zgj_snapshot_');
    });
    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('写入即 gzip 落盘，读回解码', () async {
      final files = DirectorySnapshotFiles(directory: root);
      expect(files.isReady, isTrue);
      expect(files.loadAll(), isEmpty);

      await files.write('favorites', '{"a":1}');
      final raw = File(
        '${root.path}${Platform.pathSeparator}library'
        '${Platform.pathSeparator}favorites.json.gz',
      ).readAsBytesSync();
      expect(raw[0], 0x1f);
      expect(raw[1], 0x8b);
      expect(files.loadAll(), {'favorites': '{"a":1}'});
    });

    test('迁移窗口期的明文文件可读回', () async {
      final files = DirectorySnapshotFiles(directory: root);
      await files.write('history', '{"a":1}');
      await files.delete('history');
      // 手工放置明文（未压缩）文件，模拟迁移窗口期写入。
      File(
        '${root.path}${Platform.pathSeparator}library'
        '${Platform.pathSeparator}history.json.gz',
      ).writeAsBytesSync(utf8.encode('{"b":2}'));
      expect(files.loadAll(), {'history': '{"b":2}'});
    });

    test('损坏文件与无关后缀被跳过，不拖垮其余键', () async {
      final files = DirectorySnapshotFiles(directory: root);
      await files.write('favorites', '{"a":1}');
      final library = Directory(
        '${root.path}${Platform.pathSeparator}library',
      );
      // gzip 魔数开头的伪 gzip（deflate 流损坏）→ 解压失败跳过。
      File(
        '${library.path}${Platform.pathSeparator}history.json.gz',
      ).writeAsBytesSync(<int>[0x1f, 0x8b, 0x00, 0x01, 0x02, 0x03]);
      // 非 .json.gz 后缀忽略。
      File(
        '${library.path}${Platform.pathSeparator}notes.txt',
      ).writeAsStringSync('junk');

      expect(files.loadAll(), {'favorites': '{"a":1}'});
    });

    test('目录缺失时 loadAll 返回空表', () {
      final files = DirectorySnapshotFiles(directory: root);
      expect(files.loadAll(), isEmpty);
    });

    test('写后无 tmp 残留；陈旧 tmp 被清扫而新近 tmp 保留', () async {
      final files = DirectorySnapshotFiles(directory: root);
      final library = Directory(
        '${root.path}${Platform.pathSeparator}library',
      );
      await files.write('favorites', '{"a":1}');
      await files.write('history', '{"b":2}');
      expect(
        library.listSync().whereType<File>().where(
              (f) => f.uri.pathSegments.last.endsWith('.tmp'),
            ),
        isEmpty,
      );

      // 手工放置两个 tmp：一个陈旧（>10 分钟，模拟崩溃残留）、一个新近
      //（模拟其他进程活跃写入），loadAll 只回收前者。
      final stale = File(
        '${library.path}${Platform.pathSeparator}favorites.json.gz.123.1.tmp',
      )..writeAsBytesSync(<int>[1]);
      stale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 11)),
      );
      final fresh = File(
        '${library.path}${Platform.pathSeparator}history.json.gz.456.2.tmp',
      )..writeAsBytesSync(<int>[2]);

      expect(files.loadAll(), {'favorites': '{"a":1}', 'history': '{"b":2}'});
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test('合法 gzip 但内容非 JSON 视为损坏跳过', () async {
      final files = DirectorySnapshotFiles(directory: root);
      final library = Directory(
        '${root.path}${Platform.pathSeparator}library',
      )..createSync(recursive: true);
      // 合法 gzip 包裹非 JSON 文本：文件优先语义下坏内容不得遮蔽 blob 旧值。
      File(
        '${library.path}${Platform.pathSeparator}favorites.json.gz',
      ).writeAsBytesSync(gzip.encode(utf8.encode('not-a-json')));
      File(
        '${library.path}${Platform.pathSeparator}history.json.gz',
      ).writeAsBytesSync(gzip.encode(utf8.encode('{"ok":1}')));

      expect(files.loadAll(), {'history': '{"ok":1}'});
    });

    test('未就绪时降级：loadAll 空、delete 静默、write 抛错', () async {
      final files = DirectorySnapshotFiles();
      expect(files.isReady, isFalse);
      expect(files.loadAll(), isEmpty);
      await files.delete('favorites'); // 未就绪删除是 no-op
      expect(
        () => files.write('favorites', '{}'),
        throwsStateError,
      );
    });

    test('warmUp 传目录后即可读写', () async {
      final files = DirectorySnapshotFiles();
      expect(files.isReady, isFalse);
      await files.warmUp(directory: root);
      expect(files.isReady, isTrue);
      await files.write('favorites', '{"a":1}');
      expect(files.loadAll(), {'favorites': '{"a":1}'});
      await files.delete('favorites');
      expect(files.loadAll(), isEmpty);
    });
  });
}
