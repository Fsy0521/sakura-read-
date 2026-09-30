// 全量数据备份 / 恢复（含本地小说文件）。
//
// 备份内容：
//   - 六个 JSON 数据文件（settings / library / bookmarks / reading_stats /
//     book_sources / pet）——放在 zip 根目录；
//   - EPUB 封面缓存（covers/）；
//   - 本地小说源文件（books/<bookId>.<ext>；在线书无文件，自动跳过）。
//
// 恢复策略（“养老”友好）：
//   - 小说统一恢复到 App 私有目录下的 novels/，并重写 library.json 里的
//     path 指向新位置——不依赖原外部路径（换机 / 重装后仍可用）；
//   - 恢复完成后热重载各 store（无需重启 App）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../platform/native_bridge.dart';
import '../source/source_store.dart';
import 'book_store.dart';
import 'file_scan.dart';
import 'models.dart';
import 'pet_store.dart';
import 'prefs.dart';
import 'stats_store.dart';

/// 备份文件里需要原样搬运的 JSON 数据文件名。
const List<String> kBackupJsonFiles = [
  'settings.json',
  'library.json',
  'bookmarks.json',
  'reading_stats.json',
  'book_sources.json',
  'pet.json',
];

/// 导出结果。
class BackupResult {
  const BackupResult({
    this.path,
    this.error,
    this.bookCount = 0,
    this.novelCount = 0,
  });

  final String? path;
  final String? error;
  final int bookCount;
  final int novelCount;

  bool get ok => path != null;
}

/// 恢复结果。
class RestoreResult {
  const RestoreResult({this.error, this.bookCount = 0, this.novelCount = 0});

  final String? error;
  final int bookCount;
  final int novelCount;

  bool get ok => error == null;
}

/// 备份 / 恢复服务。
class BackupService {
  BackupService._();

  static String _timestamp() {
    final now = DateTime.now();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p(now.month)}${p(now.day)}_'
        '${p(now.hour)}${p(now.minute)}${p(now.second)}';
  }

  static Future<void> _writeFile(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  static Uint8List _entryBytes(ArchiveFile entry) {
    final dynamic raw = entry.content;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return Uint8List(0);
  }

  /// 导出全部数据到 `Download/樱读备份_时间戳.zip`。
  static Future<BackupResult> exportBackup({
    required BookStore store,
    required SourceStore sourceStore,
    required AppPrefs prefs,
    required StatsStore statsStore,
    void Function(String message)? onProgress,
  }) async {
    try {
      onProgress?.call('正在保存当前数据…');
      // 先把各 store 的最新状态落盘，避免读到防抖中间态
      await Future.wait([
        store.flush(),
        prefs.flush(),
        sourceStore.flush(),
        statsStore.flush(),
        if (BookmarkStore.shared != null) BookmarkStore.shared!.flush(),
        if (PetStore.shared != null) PetStore.shared!.flush(),
      ]);

      final dirs = await NativeBridge.appDirs();
      final filesDir = Directory(dirs.files);

      onProgress?.call('打包数据文件…');
      final archive = Archive();

      // 1) 数据 JSON
      for (final name in kBackupJsonFiles) {
        final f = File('${filesDir.path}/$name');
        if (await f.exists()) {
          archive.addFile(ArchiveFile.bytes(name, await f.readAsBytes()));
        }
      }

      // 2) EPUB 封面缓存
      final coversDir = Directory('${filesDir.path}/covers');
      if (await coversDir.exists()) {
        await for (final e in coversDir.list(followLinks: false)) {
          if (e is File) {
            archive.addFile(
              ArchiveFile.bytes(
                'covers/${pathFileName(e.path)}',
                await e.readAsBytes(),
              ),
            );
          }
        }
      }

      // 3) 本地小说源文件
      var novelCount = 0;
      for (final b in store.books) {
        if (b.format == BookFormat.online) continue;
        final src = File(b.path);
        if (!await src.exists()) continue;
        final ext = pathExtension(b.path);
        archive.addFile(
          ArchiveFile.bytes('books/${b.id}.$ext', await src.readAsBytes()),
        );
        novelCount++;
      }

      onProgress?.call('压缩备份…');
      final bytes = ZipEncoder().encode(archive);

      final root = await NativeBridge.storageRoot();
      final outFile = File('$root/Download/樱读备份_${_timestamp()}.zip');
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(bytes, flush: true);

      return BackupResult(
        path: outFile.path,
        bookCount: store.books.length,
        novelCount: novelCount,
      );
    } catch (e) {
      return BackupResult(error: '$e');
    }
  }

  /// 从备份 zip 恢复全部数据（完成后热重载各 store）。
  static Future<RestoreResult> restoreBackup({
    required String zipPath,
    required BookStore store,
    required SourceStore sourceStore,
    required AppPrefs prefs,
    required StatsStore statsStore,
    void Function(String message)? onProgress,
  }) async {
    try {
      onProgress?.call('读取备份…');
      final bytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);

      final dirs = await NativeBridge.appDirs();
      final filesDir = dirs.files;
      final novelsDir = Directory('$filesDir/novels');

      // 收集备份里的本地小说条目名（<bookId>.<ext>）
      final bookEntries = <String>{};
      for (final f in archive.files) {
        if (f.isFile && f.name.startsWith('books/')) {
          bookEntries.add(f.name.substring('books/'.length));
        }
      }

      var novelCount = 0;
      var bookCount = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final name = f.name;
        var data = _entryBytes(f);

        if (kBackupJsonFiles.contains(name)) {
          if (name == 'library.json') {
            final rewritten = _rewriteLibrary(data, novelsDir.path, bookEntries);
            bookCount = rewritten.$2;
            data = Uint8List.fromList(utf8.encode(rewritten.$1));
          }
          await _writeFile(File('$filesDir/$name'), data);
        } else if (name.startsWith('covers/')) {
          final base = name.substring('covers/'.length);
          await _writeFile(File('$filesDir/covers/$base'), data);
        } else if (name.startsWith('books/')) {
          final base = name.substring('books/'.length);
          await _writeFile(File('${novelsDir.path}/$base'), data);
          novelCount++;
        }
      }

      onProgress?.call('重新载入数据…');
      await Future.wait([
        store.load(),
        prefs.load(),
        sourceStore.load(),
        statsStore.load(),
        if (BookmarkStore.shared != null) BookmarkStore.shared!.load(),
        if (PetStore.shared != null) PetStore.shared!.load(),
      ]);

      return RestoreResult(bookCount: bookCount, novelCount: novelCount);
    } catch (e) {
      return RestoreResult(error: '$e');
    }
  }

  /// 重写 library.json：本地书的 path 指向 App 私有 novels/ 目录（若备份里带该小说）。
  ///
  /// 返回 (重写后的 JSON 字符串, 书的总数)。
  static (String, int) _rewriteLibrary(
    Uint8List data,
    String novelsDirPath,
    Set<String> bookEntries,
  ) {
    try {
      final json = jsonDecode(utf8.decode(data));
      if (json is! Map || json['books'] is! List) {
        return (utf8.decode(data), 0);
      }
      final books = json['books'] as List;
      for (final item in books) {
        if (item is! Map) continue;
        if (item['format'] == 'online') continue;
        final id = item['id'] as String? ?? '';
        String? entryName;
        for (final n in bookEntries) {
          if (n.startsWith('$id.')) {
            entryName = n;
            break;
          }
        }
        if (entryName != null) item['path'] = '$novelsDirPath/$entryName';
      }
      return (jsonEncode(json), books.length);
    } catch (_) {
      return (utf8.decode(data), 0);
    }
  }
}
