import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'steam_api_service.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';

/// 首次全量基线建档与后续增量比对状态机引擎 (WorkshopDiffEngine)
class WorkshopDiffEngine {
  final WorkshopDatabase database;
  final SteamWorkshopService steamService;

  const WorkshopDiffEngine({
    required this.database,
    required this.steamService,
  });

  /// 执行单个创作者的作品同步（自动判断首次基线建档或后续增量对比）
  Future<SyncReport> syncCreator({
    required Creator creator,
    required String apiKey,
    SteamQueryMode queryMode = SteamQueryMode.automatic,
    void Function(String stageMessage)? onStatusUpdate,
    void Function(int completed, int total)? onProgress,
  }) async {
    onProgress?.call(0, 0);
    final now = DateTime.now().toUtc();
    final batchId = 'SYNC_${now.millisecondsSinceEpoch}';

    onStatusUpdate?.call(
      '正在获取创作者【${creator.personaName}】的创意工坊公开列表...',
    );
    final remoteEntries = await steamService.fetchAllCreatorItems(
      steamId: creator.steamId,
      apiKey: apiKey,
      queryMode: queryMode,
      onProgress: (fetched, total) {
        onProgress?.call(0, total);
        onStatusUpdate?.call(
          '${steamService.lastFetchSourceLabel}：正在读取作品 $fetched / ${total > 0 ? total : fetched}...',
        );
      },
    );

    final localItems = await database.getItemsByCreator(creator.steamId);
    final localMap = {
      for (final item in localItems) item.publishedFileId: item
    };
    final remoteMap = {
      for (final entry in remoteEntries) entry.publishedFileId: entry
    };

    final absentItems = localItems
        .where((item) =>
            item.status == ItemStatus.active &&
            !remoteMap.containsKey(item.publishedFileId))
        .toList();
    final totalToProcess = remoteEntries.length +
        (creator.isBaselineCompleted ? absentItems.length : 0);
    var processed = 0;
    onProgress?.call(0, totalToProcess);

    // ========================================================================
    // 分支 A：首次全量基线建档 (isBaselineCompleted == false)
    // ========================================================================
    if (!creator.isBaselineCompleted) {
      int completed = 0;
      for (final remote in remoteEntries) {
        completed++;
        onStatusUpdate?.call(
          '首次全量建档 ($completed/${remoteEntries.length})：正在归档《${remote.title}》预览图...',
        );

        final previewResult = await steamService.downloadPreviewImage(
          creatorSteamId: creator.steamId,
          publishedFileId: remote.publishedFileId,
          previewUrl: remote.previewUrl,
        );

        final contentHash = WorkshopItem.computeContentHash(
          title: remote.title,
          description: remote.description,
          tags: remote.tags,
          previewRemoteUrl: remote.previewUrl,
        );

        final baselineItem = WorkshopItem(
          publishedFileId: remote.publishedFileId,
          creatorSteamId: creator.steamId,
          title: remote.title,
          description: remote.description,
          tags: remote.tags,
          fileSizeBytes: remote.fileSizeBytes,
          previewRemoteUrl: remote.previewUrl,
          previewLocalPath: previewResult?.relativePath,
          previewSha256: previewResult?.sha256Hash,
          timeCreated: remote.timeCreated,
          timeUpdated: remote.timeUpdated,
          viewsCount: remote.views,
          subscriptionsCount: remote.subscriptions,
          favoritesCount: remote.favorites,
          status: ItemStatus.active,
          contentHash: contentHash,
          firstSeenAt: now,
          lastSeenAt: now,
        );

        await database.db.transaction((txn) async {
          await txn.insert(
            'workshop_items',
            baselineItem.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          await txn.insert('item_change_logs', {
            'published_file_id': baselineItem.publishedFileId,
            'creator_steam_id': creator.steamId,
            'sync_batch_id': batchId,
            'change_type': ChangeType.baseline.code,
            'changed_fields_json': jsonEncode({
              'title': baselineItem.title,
              'preview_local_path': baselineItem.previewLocalPath,
            }),
            'detected_at': now.toIso8601String(),
          });
        });
        onProgress?.call(++processed, totalToProcess);
      }

      await database.upsertCreator(
        creator.copyWith(
          isBaselineCompleted: true,
          totalActiveCount: remoteEntries.length,
          totalMissingCount: 0,
          lastSyncedAt: now,
        ),
      );

      return SyncReport(
        syncBatchId: batchId,
        creatorSteamId: creator.steamId,
        creatorName: creator.personaName,
        isBaselineRun: true,
        baselineCount: remoteEntries.length,
      );
    }

    // ========================================================================
    // 分支 B：后续增量比对状态机 (ADDED / MODIFIED / RESTORED / MISSING)
    // ========================================================================
    int addedCount = 0;
    int modifiedCount = 0;
    int missingCount = 0;
    int restoredCount = 0;

    // 1. 遍历远端当前公开列表：处理 ADDED、RESTORED 与 MODIFIED
    for (final remote in remoteEntries) {
      final existing = localMap[remote.publishedFileId];
      final newContentHash = WorkshopItem.computeContentHash(
        title: remote.title,
        description: remote.description,
        tags: remote.tags,
        previewRemoteUrl: remote.previewUrl,
      );

      if (existing == null) {
        // 【新增作品 ADDED】
        addedCount++;
        onStatusUpdate?.call('发现新增作品：《${remote.title}》，正在下载预览图...');
        final previewResult = await steamService.downloadPreviewImage(
          creatorSteamId: creator.steamId,
          publishedFileId: remote.publishedFileId,
          previewUrl: remote.previewUrl,
        );

        final addedItem = WorkshopItem(
          publishedFileId: remote.publishedFileId,
          creatorSteamId: creator.steamId,
          title: remote.title,
          description: remote.description,
          tags: remote.tags,
          fileSizeBytes: remote.fileSizeBytes,
          previewRemoteUrl: remote.previewUrl,
          previewLocalPath: previewResult?.relativePath,
          previewSha256: previewResult?.sha256Hash,
          timeCreated: remote.timeCreated,
          timeUpdated: remote.timeUpdated,
          viewsCount: remote.views,
          subscriptionsCount: remote.subscriptions,
          favoritesCount: remote.favorites,
          status: ItemStatus.active,
          contentHash: newContentHash,
          firstSeenAt: now,
          lastSeenAt: now,
        );

        await database.db.transaction((txn) async {
          await txn.insert('workshop_items', addedItem.toMap());
          await txn.insert('item_change_logs', {
            'published_file_id': addedItem.publishedFileId,
            'creator_steam_id': creator.steamId,
            'sync_batch_id': batchId,
            'change_type': ChangeType.added.code,
            'changed_fields_json': jsonEncode({
              'title': addedItem.title,
              'preview_local_path': addedItem.previewLocalPath,
            }),
            'detected_at': now.toIso8601String(),
          });
        });
      } else {
        // 【存续作品比对】
        if (existing.status == ItemStatus.missing) {
          restoredCount++;
          await database.db.insert('item_change_logs', {
            'published_file_id': existing.publishedFileId,
            'creator_steam_id': creator.steamId,
            'sync_batch_id': batchId,
            'change_type': ChangeType.restored.code,
            'changed_fields_json': jsonEncode({
              'title': remote.title,
              'status': {'old': 'MISSING', 'new': 'ACTIVE'},
            }),
            'detected_at': now.toIso8601String(),
          });
        }

        final bool hasChanged = existing.contentHash != newContentHash ||
            existing.timeUpdated != remote.timeUpdated;
        final needsPreviewRepair = existing.previewLocalPath == null ||
            !await File(
                    p.join(database.dataRootDir, existing.previewLocalPath!))
                .exists();

        if (hasChanged || needsPreviewRepair) {
          final diffMap = <String, dynamic>{};
          if (existing.title != remote.title) {
            diffMap['title'] = {'old': existing.title, 'new': remote.title};
          }
          if (existing.description != remote.description) {
            diffMap['description'] = {
              'old': existing.description,
              'new': remote.description,
            };
          }
          if (jsonEncode(existing.tags) != jsonEncode(remote.tags)) {
            diffMap['tags'] = {'old': existing.tags, 'new': remote.tags};
          }
          if (existing.fileSizeBytes != remote.fileSizeBytes &&
              remote.fileSizeBytes > 0) {
            diffMap['file_size_bytes'] = {
              'old': existing.fileSizeBytes,
              'new': remote.fileSizeBytes,
            };
          }

          String? updatedPreviewPath = existing.previewLocalPath;
          String? updatedPreviewSha256 = existing.previewSha256;

          if (existing.previewRemoteUrl != remote.previewUrl ||
              existing.timeUpdated != remote.timeUpdated ||
              needsPreviewRepair) {
            final newPreview = await steamService.downloadPreviewImage(
              creatorSteamId: creator.steamId,
              publishedFileId: remote.publishedFileId,
              previewUrl: remote.previewUrl,
            );
            if (newPreview != null) {
              // 保留旧预览图文件不删除，同时记录新旧预览图路径至时光机日志
              if (existing.previewSha256 != null &&
                  newPreview.sha256Hash != existing.previewSha256) {
                diffMap['preview_local_path'] = {
                  'old': existing.previewLocalPath,
                  'new': newPreview.relativePath,
                };
              }
              updatedPreviewPath = newPreview.relativePath;
              updatedPreviewSha256 = newPreview.sha256Hash;
            }
          }

          final updatedItem = WorkshopItem(
            publishedFileId: existing.publishedFileId,
            creatorSteamId: existing.creatorSteamId,
            title: remote.title,
            description: remote.description,
            tags: remote.tags,
            fileSizeBytes: remote.fileSizeBytes,
            previewRemoteUrl: remote.previewUrl,
            previewLocalPath: updatedPreviewPath,
            previewSha256: updatedPreviewSha256,
            timeCreated: remote.timeCreated,
            timeUpdated: remote.timeUpdated,
            viewsCount: remote.views,
            subscriptionsCount: remote.subscriptions,
            favoritesCount: remote.favorites,
            status: ItemStatus.active,
            contentHash: newContentHash,
            firstSeenAt: existing.firstSeenAt,
            lastSeenAt: now,
            disappearedAt: null,
          );

          await database.db.transaction((txn) async {
            await txn.update(
              'workshop_items',
              updatedItem.toMap(),
              where: 'published_file_id = ?',
              whereArgs: [existing.publishedFileId],
            );
            if (diffMap.isNotEmpty) {
              modifiedCount++;
              await txn.insert('item_change_logs', {
                'published_file_id': existing.publishedFileId,
                'creator_steam_id': creator.steamId,
                'sync_batch_id': batchId,
                'change_type': ChangeType.modified.code,
                'changed_fields_json': jsonEncode(diffMap),
                'detected_at': now.toIso8601String(),
              });
            }
          });
        } else {
          // 仅刷新存活时间戳与订阅统计
          await database.db.update(
            'workshop_items',
            {
              'status': ItemStatus.active.code,
              'last_seen_at': now.toIso8601String(),
              'views_count': remote.views,
              'subscriptions_count': remote.subscriptions,
              'favorites_count': remote.favorites,
              'disappeared_at': null,
            },
            where: 'published_file_id = ?',
            whereArgs: [existing.publishedFileId],
          );
        }
      }
      onProgress?.call(++processed, totalToProcess);
    }

    // 2. 遍历本地 ACTIVE 集合：对未出现在远端公开列表的作品执行二次点查核验
    for (final localItem in localItems) {
      if (localItem.status == ItemStatus.active &&
          !remoteMap.containsKey(localItem.publishedFileId)) {
        onStatusUpdate?.call(
          '疑似消失核验：正在点查《${localItem.title}》(${localItem.publishedFileId})...',
        );
        final isTrulyMissing = await steamService.confirmItemIsMissing(
          localItem.publishedFileId,
        );

        if (isTrulyMissing) {
          missingCount++;
          await database.db.transaction((txn) async {
            await txn.update(
              'workshop_items',
              {
                'status': ItemStatus.missing.code,
                'disappeared_at': now.toIso8601String(),
              },
              where: 'published_file_id = ?',
              whereArgs: [localItem.publishedFileId],
            );
            await txn.insert('item_change_logs', {
              'published_file_id': localItem.publishedFileId,
              'creator_steam_id': creator.steamId,
              'sync_batch_id': batchId,
              'change_type': ChangeType.missing.code,
              'changed_fields_json': jsonEncode({
                'last_known_title': localItem.title,
                'preview_local_path': localItem.previewLocalPath,
                'verified_by': 'ISteamRemoteStorage/GetPublishedFileDetails',
              }),
              'detected_at': now.toIso8601String(),
            });
          });
        }
        onProgress?.call(++processed, totalToProcess);
      }
    }

    // 3. 汇总并更新创作者统计计数
    final refreshedItems = await database.getItemsByCreator(creator.steamId);
    final activeTotal =
        refreshedItems.where((e) => e.status == ItemStatus.active).length;
    final missingTotal =
        refreshedItems.where((e) => e.status == ItemStatus.missing).length;

    await database.upsertCreator(
      creator.copyWith(
        isBaselineCompleted: true,
        totalActiveCount: activeTotal,
        totalMissingCount: missingTotal,
        lastSyncedAt: now,
      ),
    );

    return SyncReport(
      syncBatchId: batchId,
      creatorSteamId: creator.steamId,
      creatorName: creator.personaName,
      isBaselineRun: false,
      addedCount: addedCount,
      modifiedCount: modifiedCount,
      missingCount: missingCount,
      restoredCount: restoredCount,
    );
  }
}
