import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'workshop_database.dart';
import 'workshop_models.dart';

/// 本地与 WebDAV (RFC 4918) 双通道备份及灾难恢复服务
/// 支持：
/// 1. 本地全量 ZIP 归档备份（Isolate 后台打包 + 版本保留策略自动轮转清理）
/// 2. 本地增量镜像目录同步（仅拷贝新增预览图 + 热备数据库快照 + 可读 JSON/CSV 报表）
/// 3. WebDAV 连通性测试（PROPFIND 校验）
/// 4. WebDAV 增量镜像同步（基于内容哈希文件名比对，仅上传新增预览图与最新快照库）
/// 5. WebDAV 全量 ZIP 归档上传
/// 6. 一键从 WebDAV 云端恢复本地数据库与全部历史预览图
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
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:\-\.]'), '')
        .substring(0, 15);
    final zipPath = p.join(outDir.path, 'WE_Workshop_Backup_$timestamp.zip');

    await Isolate.run(() {
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      encoder.addDirectory(stagingDir, includeDirName: false);
      if (previewsDir.existsSync()) {
        encoder.addDirectory(previewsDir, includeDirName: true);
      }
      encoder.close();
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

    // 增量拷贝新增预览图
    final localPreviewsRoot =
        Directory(p.join(database.dataRootDir, 'previews'));
    if (await localPreviewsRoot.exists()) {
      await for (final entity in localPreviewsRoot.list(recursive: true)) {
        if (entity is File) {
          final relPath =
              p.relative(entity.path, from: localPreviewsRoot.path);
          final targetFile = File(p.join(mirrorPreviews.path, relPath));
          if (!await targetFile.exists()) {
            await targetFile.parent.create(recursive: true);
            await entity.copy(targetFile.path);
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

  webdav.Client _buildWebDavClient(AppSettings settings) {
    return webdav.newClient(
      settings.webdavUrl.trim(),
      user: settings.webdavUsername.trim(),
      password: settings.webdavPassword,
    );
  }

  String _normalizeRemoteRoot(String rawRoot) {
    String root = rawRoot.trim();
    if (!root.startsWith('/')) root = '/$root';
    if (!root.endsWith('/')) root = '$root/';
    return root;
  }

  /// 3. WebDAV 连通性测试（发送 PROPFIND / ping 验证账号与路径权限）
  Future<void> testWebDavConnection(AppSettings settings) async {
    final client = _buildWebDavClient(settings);
    await client.ping();
    final remoteRoot = _normalizeRemoteRoot(settings.webdavRemoteRoot);
    await client.mkdirAll(remoteRoot);
  }

  /// 4. WebDAV 增量镜像备份（PROPFIND 比对哈希文件名，仅 PUT 新增预览图与最新快照）
  Future<int> runWebDavIncrementalSync({
    required AppSettings settings,
    void Function(String msg)? onProgress,
  }) async {
    final client = _buildWebDavClient(settings);
    final remoteRoot = _normalizeRemoteRoot(settings.webdavRemoteRoot);

    onProgress?.call('正在连接 WebDAV 服务器并初始化远端目录结构...');
    await client.mkdirAll('${remoteRoot}exports/');
    await client.mkdirAll('${remoteRoot}previews/');

    final stagingDir = await _prepareStagingExport();
    int uploadedFiles = 0;

    // 增量同步各创作者的预览图目录
    final localPreviewsRoot =
        Directory(p.join(database.dataRootDir, 'previews'));
    if (await localPreviewsRoot.exists()) {
      final creatorDirs =
          localPreviewsRoot.listSync().whereType<Directory>().toList();

      for (final creatorDir in creatorDirs) {
        final creatorId = p.basename(creatorDir.path);
        final remoteCreatorDir = '${remoteRoot}previews/$creatorId/';
        await client.mkdirAll(remoteCreatorDir);

        final remoteFiles = await client.readDir(remoteCreatorDir);
        final remoteFileNames =
            remoteFiles.map((f) => f.name ?? '').toSet();

        final localFiles = creatorDir.listSync().whereType<File>().toList();
        for (final localFile in localFiles) {
          final fileName = p.basename(localFile.path);
          if (!remoteFileNames.contains(fileName)) {
            onProgress?.call('WebDAV 增量上传新预览图：$fileName');
            await client.writeFromFile(
              localFile.path,
              '$remoteCreatorDir$fileName',
            );
            uploadedFiles++;
          }
        }
      }
    }

    // 上传最新 SQLite 热备快照与 JSON/CSV 报表
    onProgress?.call('正在上传 SQLite 热备快照与已消失作品 CSV 报表...');
    await client.writeFromFile(
      p.join(stagingDir.path, 'workshop_monitor_snapshot.db'),
      '${remoteRoot}workshop_monitor_snapshot.db',
    );
    await client.writeFromFile(
      p.join(stagingDir.path, 'manifest.json'),
      '${remoteRoot}manifest.json',
    );
    await client.writeFromFile(
      p.join(stagingDir.path, 'exports', 'creators_summary.json'),
      '${remoteRoot}exports/creators_summary.json',
    );
    await client.writeFromFile(
      p.join(stagingDir.path, 'exports', 'items_all.json'),
      '${remoteRoot}exports/items_all.json',
    );
    await client.writeFromFile(
      p.join(stagingDir.path, 'exports', 'items_missing_alert.csv'),
      '${remoteRoot}exports/items_missing_alert.csv',
    );
    uploadedFiles += 5;

    await database.insertBackupRecord(
      BackupRecord(
        targetType: 'WEBDAV',
        backupMode: 'INCREMENTAL_MIRROR',
        location: '${settings.webdavUrl}$remoteRoot',
        fileSizeBytes: 0,
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    return uploadedFiles;
  }

  /// 5. WebDAV 全量 ZIP 归档包上传
  Future<String> runWebDavFullZipBackup({
    required AppSettings settings,
    void Function(String msg)? onProgress,
  }) async {
    final tempArchiveDir =
        Directory(p.join(database.dataRootDir, 'temp_webdav_zip'));
    onProgress?.call('正在打包本地全量 ZIP 归档...');
    final zipFile = await runLocalZipBackup(
      targetBackupDir: tempArchiveDir.path,
      maxKeepCount: 2,
    );

    final client = _buildWebDavClient(settings);
    final remoteRoot = _normalizeRemoteRoot(settings.webdavRemoteRoot);
    final remoteArchivesDir = '${remoteRoot}archives/';
    await client.mkdirAll(remoteArchivesDir);

    final fileName = p.basename(zipFile.path);
    final remoteZipPath = '$remoteArchivesDir$fileName';
    onProgress?.call('正在上传全量归档包至 WebDAV：$fileName...');
    await client.writeFromFile(zipFile.path, remoteZipPath);

    final size = await zipFile.length();
    await database.insertBackupRecord(
      BackupRecord(
        targetType: 'WEBDAV',
        backupMode: 'FULL_ZIP',
        location: remoteZipPath,
        fileSizeBytes: size,
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    return remoteZipPath;
  }

  /// 6. 一键从 WebDAV 云端灾难恢复（拉取远端快照库与所有历史预览图）
  Future<int> restoreFromWebDav({
    required AppSettings settings,
    void Function(String msg)? onProgress,
  }) async {
    final client = _buildWebDavClient(settings);
    final remoteRoot = _normalizeRemoteRoot(settings.webdavRemoteRoot);

    onProgress?.call('正在从 WebDAV 下载最新数据库快照 workshop_monitor_snapshot.db...');
    final tempSnapshotFile =
        File(p.join(database.dataRootDir, 'restored_snapshot.db'));
    if (await tempSnapshotFile.exists()) {
      await tempSnapshotFile.delete();
    }

    await client.read2File(
      '${remoteRoot}workshop_monitor_snapshot.db',
      tempSnapshotFile.path,
    );

    onProgress?.call('正在热替换本地 SQLite 数据库...');
    await database.restoreDatabaseFromSnapshot(tempSnapshotFile);

    int downloadedPreviews = 0;
    onProgress?.call('正在扫描并恢复 WebDAV 远端预览图资源池...');
    final remoteCreatorDirs = await client.readDir('${remoteRoot}previews/');
    for (final creatorEntry in remoteCreatorDirs) {
      if (creatorEntry.isDir != true || creatorEntry.name == null) continue;
      final creatorId = creatorEntry.name!;
      final localCreatorDir =
          Directory(p.join(database.dataRootDir, 'previews', creatorId));
      await localCreatorDir.create(recursive: true);

      final remotePreviewFiles =
          await client.readDir('${remoteRoot}previews/$creatorId/');
      for (final remoteFile in remotePreviewFiles) {
        if (remoteFile.isDir == true || remoteFile.name == null) continue;
        final fileName = remoteFile.name!;
        final localFile = File(p.join(localCreatorDir.path, fileName));
        if (!await localFile.exists()) {
          onProgress?.call('正在恢复预览图：$fileName');
          await client.read2File(
            '${remoteRoot}previews/$creatorId/$fileName',
            localFile.path,
          );
          downloadedPreviews++;
        }
      }
    }

    await database.insertBackupRecord(
      BackupRecord(
        targetType: 'WEBDAV',
        backupMode: 'RESTORE',
        location: '${settings.webdavUrl}$remoteRoot',
        fileSizeBytes: 0,
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    return downloadedPreviews;
  }
}
