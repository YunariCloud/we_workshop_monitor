import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'workshop_models.dart';

/// 桌面端 SQLite 数据库管理层（基于 sqflite_common_ffi，启用 WAL 模式与在线热备）
class WorkshopDatabase {
  Database _db;
  final String dataRootDir;
  final String dbFilePath;

  WorkshopDatabase._(this._db, this.dataRootDir, this.dbFilePath);

  Database get db => _db;

  static Future<WorkshopDatabase> initialize(
      {String? dataRootDirOverride}) async {
    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;
    final dataRootDir = dataRootDirOverride ??
        p.join((await getApplicationSupportDirectory()).path,
            'we_workshop_monitor');
    await Directory(p.join(dataRootDir, 'previews')).create(recursive: true);

    final dbPath = p.join(dataRootDir, 'workshop_monitor.db');
    final db = await _openAndMigrate(databaseFactory, dbPath);
    // Repair cached statistics left behind by the old parent-row REPLACE bug.
    // Empty archives with positive cached counts must be built again.
    await db.rawUpdate('''
      UPDATE creators SET
        is_baseline_completed = CASE
          WHEN is_baseline_completed = 1
            AND total_active_count + total_missing_count > 0
            AND NOT EXISTS (SELECT 1 FROM workshop_items w
              WHERE w.creator_steam_id = creators.steam_id)
          THEN 0 ELSE is_baseline_completed END,
        total_active_count = (SELECT COUNT(*) FROM workshop_items w
          WHERE w.creator_steam_id = creators.steam_id AND w.status = 'ACTIVE'),
        total_missing_count = (SELECT COUNT(*) FROM workshop_items w
          WHERE w.creator_steam_id = creators.steam_id AND w.status = 'MISSING')
    ''');
    return WorkshopDatabase._(db, dataRootDir, dbPath);
  }

  static Future<Database> _openAndMigrate(
    DatabaseFactory factory,
    String dbPath,
  ) async {
    return factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
          await db.execute('PRAGMA journal_mode = WAL;');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE creators (
              steam_id TEXT PRIMARY KEY,
              persona_name TEXT NOT NULL,
              profile_url TEXT NOT NULL,
              avatar_local_path TEXT,
              is_baseline_completed INTEGER DEFAULT 0,
              total_active_count INTEGER DEFAULT 0,
              total_missing_count INTEGER DEFAULT 0,
              last_synced_at TEXT,
              created_at TEXT NOT NULL
            );
          ''');

          await db.execute('''
            CREATE TABLE workshop_items (
              published_file_id TEXT PRIMARY KEY,
              creator_steam_id TEXT NOT NULL,
              title TEXT NOT NULL,
              description TEXT,
              tags_json TEXT NOT NULL,
              file_size_bytes INTEGER DEFAULT 0,
              preview_remote_url TEXT,
              preview_local_path TEXT,
              preview_sha256 TEXT,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              views_count INTEGER DEFAULT 0,
              subscriptions_count INTEGER DEFAULT 0,
              favorites_count INTEGER DEFAULT 0,
              status TEXT NOT NULL,
              content_hash TEXT NOT NULL,
              first_seen_at TEXT NOT NULL,
              last_seen_at TEXT NOT NULL,
              disappeared_at TEXT,
              FOREIGN KEY (creator_steam_id) REFERENCES creators(steam_id) ON DELETE CASCADE
            );
          ''');

          await db.execute('''
            CREATE INDEX idx_items_creator_status
            ON workshop_items(creator_steam_id, status);
          ''');

          await db.execute('''
            CREATE TABLE item_change_logs (
              log_id INTEGER PRIMARY KEY AUTOINCREMENT,
              published_file_id TEXT NOT NULL,
              creator_steam_id TEXT NOT NULL,
              sync_batch_id TEXT NOT NULL,
              change_type TEXT NOT NULL,
              changed_fields_json TEXT,
              detected_at TEXT NOT NULL,
              FOREIGN KEY (published_file_id) REFERENCES workshop_items(published_file_id) ON DELETE CASCADE
            );
          ''');

          await db.execute('''
            CREATE INDEX idx_logs_item_id
            ON item_change_logs(published_file_id, detected_at DESC);
          ''');

          await db.execute('''
            CREATE TABLE backup_records (
              backup_id INTEGER PRIMARY KEY AUTOINCREMENT,
              target_type TEXT NOT NULL,
              backup_mode TEXT NOT NULL,
              location TEXT NOT NULL,
              file_size_bytes INTEGER DEFAULT 0,
              checksum_sha256 TEXT,
              status TEXT NOT NULL,
              error_message TEXT,
              created_at TEXT NOT NULL
            );
          ''');

          await db.execute('''
            CREATE TABLE app_kv_config (
              config_key TEXT PRIMARY KEY,
              config_value TEXT NOT NULL
            );
          ''');
        },
      ),
    );
  }

  /// 保存非敏感配置项至 SQLite
  Future<void> saveConfigJson(Map<String, dynamic> configMap) async {
    await _db.insert(
      'app_kv_config',
      {
        'config_key': 'app_settings',
        'config_value': jsonEncode(configMap),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 读取非敏感配置项
  Future<Map<String, dynamic>?> loadConfigJson() async {
    final rows = await _db.query(
      'app_kv_config',
      where: 'config_key = ?',
      whereArgs: ['app_settings'],
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['config_value'] as String?;
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> upsertCreator(Creator creator) async {
    // REPLACE deletes the parent row first, cascading into workshop_items and
    // their history. Update the existing row in place instead.
    await _db.transaction((txn) async {
      final updated = await txn.update('creators', creator.toMap(),
          where: 'steam_id = ?', whereArgs: [creator.steamId]);
      if (updated == 0) {
        await txn.insert('creators', creator.toMap());
      }
    });
  }

  Future<void> deleteCreator(String steamId) async {
    await _db.delete(
      'creators',
      where: 'steam_id = ?',
      whereArgs: [steamId],
    );
  }

  Future<List<Creator>> getAllCreators() async {
    final rows = await _db.query('creators', orderBy: 'created_at DESC');
    return rows.map(Creator.fromMap).toList();
  }

  Future<List<WorkshopItem>> getItemsByCreator(String creatorSteamId) async {
    final rows = await _db.query(
      'workshop_items',
      where: 'creator_steam_id = ?',
      whereArgs: [creatorSteamId],
      orderBy: 'time_updated DESC',
    );
    return rows.map(WorkshopItem.fromMap).toList();
  }

  /// 多条件检索作品（同时支持检索 item_change_logs 中的历史旧标题）
  Future<List<WorkshopItem>> queryItems({
    String? creatorSteamId,
    ItemStatus? statusFilter,
    String? tagFilter,
    String searchQuery = '',
    bool onlyModified = false,
  }) async {
    final whereClauses = <String>[];
    final whereArgs = <Object?>[];

    if (creatorSteamId != null && creatorSteamId.isNotEmpty) {
      whereClauses.add('creator_steam_id = ?');
      whereArgs.add(creatorSteamId);
    }
    if (statusFilter != null) {
      whereClauses.add('status = ?');
      whereArgs.add(statusFilter.code);
    }
    if (tagFilter != null && tagFilter.isNotEmpty) {
      whereClauses.add('tags_json LIKE ?');
      whereArgs.add('%"$tagFilter"%');
    }
    if (onlyModified) {
      whereClauses.add('''
        published_file_id IN (
          SELECT DISTINCT published_file_id FROM item_change_logs
          WHERE change_type = 'MODIFIED'
        )
      ''');
    }
    if (searchQuery.trim().isNotEmpty) {
      final q = '%${searchQuery.trim()}%';
      whereClauses.add('''
        (
          title LIKE ?
          OR description LIKE ?
          OR published_file_id LIKE ?
          OR published_file_id IN (
            SELECT published_file_id FROM item_change_logs
            WHERE changed_fields_json LIKE ?
          )
        )
      ''');
      whereArgs.addAll([q, q, q, q]);
    }

    final rows = await _db.query(
      'workshop_items',
      where: whereClauses.isEmpty ? null : whereClauses.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'time_updated DESC',
    );
    return rows.map(WorkshopItem.fromMap).toList();
  }

  Future<List<ItemChangeLog>> getChangeLogs({
    String? publishedFileId,
    String? creatorSteamId,
    ChangeType? changeTypeFilter,
    int limit = 300,
  }) async {
    final whereClauses = <String>[];
    final whereArgs = <Object?>[];

    if (publishedFileId != null && publishedFileId.isNotEmpty) {
      whereClauses.add('published_file_id = ?');
      whereArgs.add(publishedFileId);
    }
    if (creatorSteamId != null && creatorSteamId.isNotEmpty) {
      whereClauses.add('creator_steam_id = ?');
      whereArgs.add(creatorSteamId);
    }
    if (changeTypeFilter != null) {
      whereClauses.add('change_type = ?');
      whereArgs.add(changeTypeFilter.code);
    }

    final rows = await _db.query(
      'item_change_logs',
      where: whereClauses.isEmpty ? null : whereClauses.join(' AND '),
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'detected_at DESC, log_id DESC',
      limit: limit,
    );
    return rows.map(ItemChangeLog.fromMap).toList();
  }

  Future<void> insertBackupRecord(BackupRecord record) async {
    await _db.insert('backup_records', {
      'target_type': record.targetType,
      'backup_mode': record.backupMode,
      'location': record.location,
      'file_size_bytes': record.fileSizeBytes,
      'checksum_sha256': record.checksumSha256,
      'status': record.status,
      'error_message': record.errorMessage,
      'created_at': record.createdAt.toUtc().toIso8601String(),
    });
  }

  Future<List<BackupRecord>> getBackupRecords({int limit = 50}) async {
    final rows = await _db.query(
      'backup_records',
      orderBy: 'created_at DESC, backup_id DESC',
      limit: limit,
    );
    return rows.map(BackupRecord.fromMap).toList();
  }

  /// 使用 SQLite 原生 VACUUM INTO 指令生成无锁一致性热备份快照
  Future<File> createHotSnapshot(String destinationDbPath) async {
    final targetFile = File(destinationDbPath);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    final escapedPath = destinationDbPath.replaceAll("'", "''");
    await _db.execute("VACUUM INTO '$escapedPath';");
    return targetFile;
  }

  /// 从备份快照数据库文件热恢复替换当前数据库
  Future<void> restoreDatabaseFromSnapshot(File snapshotDbFile) async {
    await _db.close();
    final walFile = File('$dbFilePath-wal');
    final shmFile = File('$dbFilePath-shm');
    if (await walFile.exists()) await walFile.delete();
    if (await shmFile.exists()) await shmFile.delete();

    await snapshotDbFile.copy(dbFilePath);
    _db = await _openAndMigrate(databaseFactoryFfi, dbFilePath);
  }
}
