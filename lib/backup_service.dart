import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'workshop_database.dart';
import 'workshop_models.dart';
import 'lightweight_archive.dart';

/// 本地 ZIP 归档与增量镜像备份服务。
class BackupService {
  final WorkshopDatabase database;

  const BackupService({required this.database});

  /// 准备热备快照 staging 目录：生成无锁 SQLite 快照 + 人类可读 JSON/CSV 导出清单
  Future<Directory> _prepareStagingExport({bool lightweight = false}) async {
    final workRoot = Directory(p.join(database.dataRootDir, 'backup_work'));
    await workRoot.create(recursive: true);
    final stagingDir = await workRoot.createTemp('archive-');
    try {
      final exportsDir = Directory(p.join(stagingDir.path, 'exports'));
      await exportsDir.create(recursive: true);

      // 1. 生成 SQLite 无锁热备快照 (VACUUM INTO)
      final snapshotDbPath =
          p.join(stagingDir.path, 'workshop_monitor_snapshot.db');
      final snapshotFile = await database.createHotSnapshot(snapshotDbPath);

      // 2. 导出创作者汇总、全部作品 JSON 与“已消失/下架作品”专用 CSV 报表
      final snapshotDb = await databaseFactoryFfi.openDatabase(snapshotDbPath,
          options: OpenDatabaseOptions(readOnly: true));
      late List<Creator> creators;
      late List<WorkshopItem> allItems;
      late List<ItemChangeLog> allLogs;
      try {
        creators =
            (await snapshotDb.query('creators')).map(Creator.fromMap).toList();
        allItems = (await snapshotDb.query('workshop_items'))
            .map(WorkshopItem.fromMap)
            .toList();
        allLogs = (await snapshotDb.query('item_change_logs'))
            .map(ItemChangeLog.fromMap)
            .toList();
      } finally {
        await snapshotDb.close();
      }
      final missingItems =
          allItems.where((e) => e.status == ItemStatus.missing).toList();

      final creatorsJsonFile =
          File(p.join(exportsDir.path, 'creators_summary.json'));
      await creatorsJsonFile.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert(creators.map((c) => c.toMap()).toList()),
      );

      final allItemsJsonFile = File(p.join(exportsDir.path, 'items_all.json'));
      await allItemsJsonFile.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert(allItems.map((e) => e.toMap()).toList()),
      );

      final csvBuffer = StringBuffer(
        'published_file_id,creator_steam_id,title,tags,first_seen_at,disappeared_at,preview_local_path\n',
      );
      for (final item in missingItems) {
        final safeTitle = '"${item.title.replaceAll('"', '""')}"';
        final safeTags = '"${item.tags.join(";").replaceAll('"', '""')}"';
        csvBuffer.writeln(
          '${item.publishedFileId},${item.creatorSteamId},$safeTitle,$safeTags,${item.firstSeenAt.toIso8601String()},${item.disappearedAt?.toIso8601String() ?? ""},${item.previewLocalPath ?? ""}',
        );
      }
      final csvFile = File(p.join(exportsDir.path, 'items_missing_alert.csv'));
      await csvFile.writeAsString(csvBuffer.toString());

      Map<String, Object> media = {'mode': 'original'};
      if (lightweight) {
        final paths = <String>{
          for (final item in allItems)
            if (item.previewLocalPath != null) item.previewLocalPath!
        };
        for (final log in allLogs) {
          final preview = log.changedFields['preview_local_path'];
          if (preview is String) paths.add(preview);
          if (preview is Map) paths.addAll(preview.values.whereType<String>());
        }
        media = await prepareLightweightArchive(
            dataRoot: database.dataRootDir,
            stagingRoot: stagingDir.path,
            previewPaths: paths);
      }
      final dbSha256 =
          sha256.convert(await snapshotFile.readAsBytes()).toString();

      // 3. 写入 manifest.json
      final manifestFile = File(p.join(stagingDir.path, 'manifest.json'));
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'generated_at': DateTime.now().toUtc().toIso8601String(),
          'app_id': kWallpaperEngineAppId,
          'creators_count': creators.length,
          'total_items': allItems.length,
          'missing_items': missingItems.length,
          'database_sha256': dbSha256,
          'media': media,
        }),
      );

      return stagingDir;
    } catch (_) {
      await _removeStaging(stagingDir);
      rethrow;
    }
  }

  /// 1. 本地全量 ZIP 归档备份（含自动版本保留轮转）
  Future<File> runLocalZipBackup({
    required String targetBackupDir,
    int maxKeepCount = 10,
    bool lightweight = false,
    bool recordBackup = true,
  }) async {
    final outDir = Directory(targetBackupDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final stagingDir = await _prepareStagingExport(lightweight: lightweight);
    try {
      final previewsDir = Directory(p.join(database.dataRootDir, 'previews'));
      final avatarsDir = Directory(p.join(database.dataRootDir, 'avatars'));
      final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
      final zipPath = p.join(outDir.path,
          'WE_Workshop_Backup_${timestamp}_${lightweight ? 'light' : 'original'}.zip');

      await Isolate.run(() async {
        final encoder = ZipFileEncoder();
        encoder.create(zipPath);
        try {
          await encoder.addDirectory(stagingDir, includeDirName: false);
          if (!lightweight && previewsDir.existsSync()) {
            await encoder.addDirectory(previewsDir, includeDirName: true);
          }
          if (avatarsDir.existsSync()) {
            await encoder.addDirectory(avatarsDir, includeDirName: true);
          }
        } finally {
          await encoder.close();
        }
      });

      final zipFile = File(zipPath);
      final zipBytes = await zipFile.readAsBytes();
      final zipSha256 = sha256.convert(zipBytes).toString();

      if (recordBackup) {
        await database.insertBackupRecord(
          BackupRecord(
            targetType: 'LOCAL',
            backupMode: lightweight ? 'LIGHTWEIGHT_ZIP' : 'FULL_ZIP',
            location: zipPath,
            fileSizeBytes: zipBytes.length,
            checksumSha256: zipSha256,
            status: 'SUCCESS',
            createdAt: DateTime.now().toUtc(),
          ),
        );
      }

      // 执行版本保留策略 (Retention Policy)
      final existingZips = outDir
          .listSync()
          .whereType<File>()
          .where((f) =>
              p.basename(f.path).startsWith('WE_Workshop_Backup_') &&
              p.extension(f.path) == '.zip')
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));

      if (recordBackup && existingZips.length > maxKeepCount.clamp(1, 1000)) {
        for (final oldZip in existingZips.skip(maxKeepCount.clamp(1, 1000))) {
          await oldZip.delete();
        }
      }

      return zipFile;
    } finally {
      await _removeStaging(stagingDir);
    }
  }

  /// 2. 本地增量镜像目录备份（仅拷贝新增预览图 + 更新快照库与可读清单）
  Future<int> runLocalMirrorSync(
      {required String targetMirrorDir, bool lightweight = false}) async {
    final mirrorRoot = Directory(
        lightweight ? p.join(targetMirrorDir, 'lightweight') : targetMirrorDir);
    final mirrorExports = Directory(p.join(mirrorRoot.path, 'exports'));
    final mirrorPreviews = Directory(p.join(mirrorRoot.path, 'previews'));
    await mirrorExports.create(recursive: true);
    await mirrorPreviews.create(recursive: true);

    final stagingDir = await _prepareStagingExport(lightweight: lightweight);
    try {
      int copiedFiles = 0;

      // 覆盖更新数据库快照与可读报表
      for (final relFile in [
        'workshop_monitor_snapshot.db',
        'manifest.json',
        p.join('exports', 'creators_summary.json'),
        p.join('exports', 'items_all.json'),
        p.join('exports', 'items_missing_alert.csv'),
      ]) {
        final src = File(p.join(stagingDir.path, relFile));
        if (await src.exists()) {
          await src.copy(p.join(mirrorRoot.path, relFile));
          copiedFiles++;
        }
      }

      // Cache filenames include a content hash, so existing files remain valid.
      for (final folder in ['previews', 'avatars']) {
        final sourceRoot = Directory(p.join(
            lightweight && folder == 'previews'
                ? stagingDir.path
                : database.dataRootDir,
            folder));
        if (!await sourceRoot.exists()) continue;
        await for (final entity in sourceRoot.list(recursive: true)) {
          if (entity is File) {
            final target = File(p.join(mirrorRoot.path, folder,
                p.relative(entity.path, from: sourceRoot.path)));
            if (!await target.exists()) {
              await target.parent.create(recursive: true);
              await entity.copy(target.path);
              copiedFiles++;
            }
          }
        }
      }

      await database.insertBackupRecord(
        BackupRecord(
          targetType: 'LOCAL',
          backupMode: lightweight ? 'LIGHTWEIGHT_MIRROR' : 'INCREMENTAL_MIRROR',
          location: mirrorRoot.path,
          fileSizeBytes: 0,
          status: 'SUCCESS',
          createdAt: DateTime.now().toUtc(),
        ),
      );

      return copiedFiles;
    } finally {
      await _removeStaging(stagingDir);
    }
  }

  Future<void> _removeStaging(Directory directory) async {
    final root = p.normalize(p.absolute(database.dataRootDir, 'backup_work'));
    final target = p.normalize(directory.absolute.path);
    if (!p.isWithin(root, target)) {
      throw StateError('Invalid backup staging directory');
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
