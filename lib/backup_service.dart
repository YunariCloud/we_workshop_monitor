import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'workshop_database.dart';
import 'workshop_models.dart';

/// 本地 ZIP 归档与增量镜像备份服务。
class BackupService {
  final WorkshopDatabase database;

  const BackupService({required this.database});

  /// 准备热备快照 staging 目录：生成无锁 SQLite 快照 + 人类可读 JSON/CSV 导出清单
  Future<Directory> _prepareStagingExport() async {
    final stagingDir =
        Directory(p.join(database.dataRootDir, 'backup_staging'));
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    final exportsDir = Directory(p.join(stagingDir.path, 'exports'));
    await exportsDir.create(recursive: true);

    // 1. 生成 SQLite 无锁热备快照 (VACUUM INTO)
    final snapshotDbPath =
        p.join(stagingDir.path, 'workshop_monitor_snapshot.db');
    final snapshotFile = await database.createHotSnapshot(snapshotDbPath);
    final dbBytes = await snapshotFile.readAsBytes();
    final dbSha256 = sha256.convert(dbBytes).toString();

    // 2. 导出创作者汇总、全部作品 JSON 与“已消失/下架作品”专用 CSV 报表
    final creators = await database.getAllCreators();
    final allItems = await database.queryItems();
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
      }),
    );

    return stagingDir;
  }

  /// 1. 本地全量 ZIP 归档备份（含自动版本保留轮转）
  Future<File> runLocalZipBackup({
    required String targetBackupDir,
    int maxKeepCount = 10,
  }) async {
    final outDir = Directory(targetBackupDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final stagingDir = await _prepareStagingExport();
    final previewsDir = Directory(p.join(database.dataRootDir, 'previews'));
    final avatarsDir = Directory(p.join(database.dataRootDir, 'avatars'));
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:\-\.]'), '')
        .substring(0, 15);
    final zipPath = p.join(outDir.path, 'WE_Workshop_Backup_$timestamp.zip');

    await Isolate.run(() async {
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      try {
        await encoder.addDirectory(stagingDir, includeDirName: false);
        if (previewsDir.existsSync()) {
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

    await database.insertBackupRecord(
      BackupRecord(
        targetType: 'LOCAL',
        backupMode: 'FULL_ZIP',
        location: zipPath,
        fileSizeBytes: zipBytes.length,
        checksumSha256: zipSha256,
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    // 执行版本保留策略 (Retention Policy)
    final existingZips = outDir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('WE_Workshop_Backup_'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    if (existingZips.length > maxKeepCount) {
      for (final oldZip in existingZips.skip(maxKeepCount)) {
        await oldZip.delete();
      }
    }

    return zipFile;
  }

  /// 2. 本地增量镜像目录备份（仅拷贝新增预览图 + 更新快照库与可读清单）
  Future<int> runLocalMirrorSync({required String targetMirrorDir}) async {
    final mirrorRoot = Directory(targetMirrorDir);
    final mirrorExports = Directory(p.join(mirrorRoot.path, 'exports'));
    final mirrorPreviews = Directory(p.join(mirrorRoot.path, 'previews'));
    await mirrorExports.create(recursive: true);
    await mirrorPreviews.create(recursive: true);

    final stagingDir = await _prepareStagingExport();
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
      final sourceRoot = Directory(p.join(database.dataRootDir, folder));
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
        backupMode: 'INCREMENTAL_MIRROR',
        location: mirrorRoot.path,
        fileSizeBytes: 0,
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    return copiedFiles;
  }
}
