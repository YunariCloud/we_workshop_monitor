import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// Wallpaper Engine Steam AppID
const int kWallpaperEngineAppId = 431960;

/// 作品存续状态枚举
enum ItemStatus {
  active('ACTIVE', '正常在线', Colors.teal),
  missing('MISSING', '已消失/下架', Colors.redAccent),
  banned('BANNED', '已封禁/不可见', Colors.deepOrange);

  final String code;
  final String label;
  final Color color;
  const ItemStatus(this.code, this.label, this.color);

  static ItemStatus fromCode(String code) {
    return ItemStatus.values.firstWhere(
      (e) => e.code == code,
      orElse: () => ItemStatus.active,
    );
  }
}

/// 变更日志事件类型枚举
enum ChangeType {
  baseline('BASELINE', '首次基线建档', Icons.inventory_2_outlined, Colors.blueGrey),
  added('ADDED', '新增发布', Icons.add_circle_outline, Colors.greenAccent),
  modified('MODIFIED', '内容/封面修改', Icons.edit_note, Colors.amberAccent),
  missing('MISSING', '作品消失/下架', Icons.warning_amber_rounded, Colors.redAccent),
  restored('RESTORED', '作品恢复上架', Icons.restore, Colors.tealAccent);

  final String code;
  final String label;
  final IconData icon;
  final Color color;
  const ChangeType(this.code, this.label, this.icon, this.color);

  static ChangeType fromCode(String code) {
    return ChangeType.values.firstWhere(
      (e) => e.code == code,
      orElse: () => ChangeType.modified,
    );
  }
}

/// 创作者实体模型
class Creator {
  final String steamId;
  final String personaName;
  final String profileUrl;
  final String? avatarLocalPath;
  final bool isBaselineCompleted;
  final int totalActiveCount;
  final int totalMissingCount;
  final DateTime? lastSyncedAt;
  final DateTime createdAt;

  const Creator({
    required this.steamId,
    required this.personaName,
    required this.profileUrl,
    this.avatarLocalPath,
    required this.isBaselineCompleted,
    required this.totalActiveCount,
    required this.totalMissingCount,
    this.lastSyncedAt,
    required this.createdAt,
  });

  Creator copyWith({
    String? personaName,
    String? profileUrl,
    String? avatarLocalPath,
    bool? isBaselineCompleted,
    int? totalActiveCount,
    int? totalMissingCount,
    DateTime? lastSyncedAt,
  }) {
    return Creator(
      steamId: steamId,
      personaName: personaName ?? this.personaName,
      profileUrl: profileUrl ?? this.profileUrl,
      avatarLocalPath: avatarLocalPath ?? this.avatarLocalPath,
      isBaselineCompleted: isBaselineCompleted ?? this.isBaselineCompleted,
      totalActiveCount: totalActiveCount ?? this.totalActiveCount,
      totalMissingCount: totalMissingCount ?? this.totalMissingCount,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'steam_id': steamId,
      'persona_name': personaName,
      'profile_url': profileUrl,
      'avatar_local_path': avatarLocalPath,
      'is_baseline_completed': isBaselineCompleted ? 1 : 0,
      'total_active_count': totalActiveCount,
      'total_missing_count': totalMissingCount,
      'last_synced_at': lastSyncedAt?.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  factory Creator.fromMap(Map<String, Object?> map) {
    return Creator(
      steamId: map['steam_id'] as String,
      personaName: map['persona_name'] as String,
      profileUrl: map['profile_url'] as String,
      avatarLocalPath: map['avatar_local_path'] as String?,
      isBaselineCompleted: (map['is_baseline_completed'] as int? ?? 0) == 1,
      totalActiveCount: map['total_active_count'] as int? ?? 0,
      totalMissingCount: map['total_missing_count'] as int? ?? 0,
      lastSyncedAt: map['last_synced_at'] != null
          ? DateTime.tryParse(map['last_synced_at'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

/// 创意工坊作品元数据模型（软删除设计，保留历史封面与元数据）
class WorkshopItem {
  final String publishedFileId;
  final String creatorSteamId;
  final String title;
  final String description;
  final List<String> tags;
  final int fileSizeBytes;
  final String previewRemoteUrl;
  final String? previewLocalPath;
  final String? previewSha256;
  final int timeCreated;
  final int timeUpdated;
  final int viewsCount;
  final int subscriptionsCount;
  final int favoritesCount;
  final ItemStatus status;
  final String contentHash;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? disappearedAt;

  const WorkshopItem({
    required this.publishedFileId,
    required this.creatorSteamId,
    required this.title,
    required this.description,
    required this.tags,
    required this.fileSizeBytes,
    required this.previewRemoteUrl,
    this.previewLocalPath,
    this.previewSha256,
    required this.timeCreated,
    required this.timeUpdated,
    this.viewsCount = 0,
    required this.subscriptionsCount,
    required this.favoritesCount,
    required this.status,
    required this.contentHash,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.disappearedAt,
  });

  /// 计算作品核心元数据 SHA-256 摘要，用于快速判断作品信息是否被修改
  static String computeContentHash({
    required String title,
    required String description,
    required List<String> tags,
    required String previewRemoteUrl,
  }) {
    final sortedTags = [...tags]..sort();
    final payload = jsonEncode({
      'title': title.trim(),
      'description': description.trim(),
      'tags': sortedTags,
      'preview_url': previewRemoteUrl.trim(),
    });
    return sha256.convert(utf8.encode(payload)).toString();
  }

  /// 格式化文件大小显示（如 42.5 MB）
  String get formattedFileSize {
    if (fileSizeBytes <= 0) return '未知大小';
    const units = ['B', 'KB', 'MB', 'GB'];
    double size = fileSizeBytes.toDouble();
    int unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(2)} ${units[unitIndex]}';
  }

  Map<String, Object?> toMap() {
    return {
      'published_file_id': publishedFileId,
      'creator_steam_id': creatorSteamId,
      'title': title,
      'description': description,
      'tags_json': jsonEncode(tags),
      'file_size_bytes': fileSizeBytes,
      'preview_remote_url': previewRemoteUrl,
      'preview_local_path': previewLocalPath,
      'preview_sha256': previewSha256,
      'time_created': timeCreated,
      'time_updated': timeUpdated,
      'views_count': viewsCount,
      'subscriptions_count': subscriptionsCount,
      'favorites_count': favoritesCount,
      'status': status.code,
      'content_hash': contentHash,
      'first_seen_at': firstSeenAt.toUtc().toIso8601String(),
      'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
      'disappeared_at': disappearedAt?.toUtc().toIso8601String(),
    };
  }

  factory WorkshopItem.fromMap(Map<String, Object?> map) {
    final rawTags = map['tags_json'] as String? ?? '[]';
    final decodedTags = (jsonDecode(rawTags) as List<dynamic>)
        .map((e) => e.toString())
        .toList();
    return WorkshopItem(
      publishedFileId: map['published_file_id'] as String,
      creatorSteamId: map['creator_steam_id'] as String,
      title: map['title'] as String,
      description: map['description'] as String? ?? '',
      tags: decodedTags,
      fileSizeBytes: map['file_size_bytes'] as int? ?? 0,
      previewRemoteUrl: map['preview_remote_url'] as String? ?? '',
      previewLocalPath: map['preview_local_path'] as String?,
      previewSha256: map['preview_sha256'] as String?,
      timeCreated: map['time_created'] as int? ?? 0,
      timeUpdated: map['time_updated'] as int? ?? 0,
      viewsCount: map['views_count'] as int? ?? 0,
      subscriptionsCount: map['subscriptions_count'] as int? ?? 0,
      favoritesCount: map['favorites_count'] as int? ?? 0,
      status: ItemStatus.fromCode(map['status'] as String? ?? 'ACTIVE'),
      contentHash: map['content_hash'] as String? ?? '',
      firstSeenAt: DateTime.parse(map['first_seen_at'] as String),
      lastSeenAt: DateTime.parse(map['last_seen_at'] as String),
      disappearedAt: map['disappeared_at'] != null
          ? DateTime.tryParse(map['disappeared_at'] as String)
          : null,
    );
  }
}

/// 作品变更历史日志模型（支持时光机回溯旧标题、旧简介、旧预览图路径）
class ItemChangeLog {
  final int? logId;
  final String publishedFileId;
  final String creatorSteamId;
  final String syncBatchId;
  final ChangeType changeType;
  final Map<String, dynamic> changedFields;
  final DateTime detectedAt;

  const ItemChangeLog({
    this.logId,
    required this.publishedFileId,
    required this.creatorSteamId,
    required this.syncBatchId,
    required this.changeType,
    required this.changedFields,
    required this.detectedAt,
  });

  factory ItemChangeLog.fromMap(Map<String, Object?> map) {
    final rawJson = map['changed_fields_json'] as String?;
    return ItemChangeLog(
      logId: map['log_id'] as int?,
      publishedFileId: map['published_file_id'] as String,
      creatorSteamId: map['creator_steam_id'] as String,
      syncBatchId: map['sync_batch_id'] as String,
      changeType: ChangeType.fromCode(map['change_type'] as String),
      changedFields: rawJson != null && rawJson.isNotEmpty
          ? (jsonDecode(rawJson) as Map<String, dynamic>)
          : {},
      detectedAt: DateTime.parse(map['detected_at'] as String),
    );
  }
}

/// 备份执行历史记录模型
class BackupRecord {
  final int? backupId;
  final String targetType; // LOCAL; legacy targets remain readable
  final String backupMode; // FULL_ZIP / INCREMENTAL_MIRROR / RESTORE
  final String location;
  final int fileSizeBytes;
  final String? checksumSha256;
  final String status; // SUCCESS / FAILED
  final String? errorMessage;
  final DateTime createdAt;

  const BackupRecord({
    this.backupId,
    required this.targetType,
    required this.backupMode,
    required this.location,
    required this.fileSizeBytes,
    this.checksumSha256,
    required this.status,
    this.errorMessage,
    required this.createdAt,
  });

  factory BackupRecord.fromMap(Map<String, Object?> map) {
    return BackupRecord(
      backupId: map['backup_id'] as int?,
      targetType: map['target_type'] as String,
      backupMode: map['backup_mode'] as String,
      location: map['location'] as String,
      fileSizeBytes: map['file_size_bytes'] as int? ?? 0,
      checksumSha256: map['checksum_sha256'] as String?,
      status: map['status'] as String,
      errorMessage: map['error_message'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

enum SteamQueryMode {
  automatic('自动选择'),
  webApi('Web API Key'),
  client('Steam 客户端'),
  web('公开网页');

  final String label;
  const SteamQueryMode(this.label);
}

/// 全局应用与本地备份配置模型
class AppSettings {
  final String steamApiKey;
  final SteamQueryMode steamQueryMode;
  final bool useDarkTheme;
  final int pollIntervalHours; // 0 = 仅手动, 2 / 6 / 12 / 24 小时
  final bool minimizeToTrayOnClose;
  final bool autoBackupAfterChange;
  final int downloadConcurrency;
  final String httpProxyUrl;
  final String localBackupDir;
  final int maxLocalZipKeep;

  const AppSettings({
    this.steamApiKey = '',
    this.steamQueryMode = SteamQueryMode.automatic,
    this.useDarkTheme = false,
    this.pollIntervalHours = 6,
    this.minimizeToTrayOnClose = true,
    this.autoBackupAfterChange = true,
    this.downloadConcurrency = 4,
    this.httpProxyUrl = '',
    this.localBackupDir = '',
    this.maxLocalZipKeep = 10,
  });

  AppSettings copyWith({
    String? steamApiKey,
    SteamQueryMode? steamQueryMode,
    bool? useDarkTheme,
    int? pollIntervalHours,
    bool? minimizeToTrayOnClose,
    bool? autoBackupAfterChange,
    int? downloadConcurrency,
    String? httpProxyUrl,
    String? localBackupDir,
    int? maxLocalZipKeep,
  }) {
    return AppSettings(
      steamApiKey: steamApiKey ?? this.steamApiKey,
      steamQueryMode: steamQueryMode ?? this.steamQueryMode,
      useDarkTheme: useDarkTheme ?? this.useDarkTheme,
      pollIntervalHours: pollIntervalHours ?? this.pollIntervalHours,
      minimizeToTrayOnClose:
          minimizeToTrayOnClose ?? this.minimizeToTrayOnClose,
      autoBackupAfterChange:
          autoBackupAfterChange ?? this.autoBackupAfterChange,
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      httpProxyUrl: httpProxyUrl ?? this.httpProxyUrl,
      localBackupDir: localBackupDir ?? this.localBackupDir,
      maxLocalZipKeep: maxLocalZipKeep ?? this.maxLocalZipKeep,
    );
  }

  Map<String, dynamic> toNonSensitiveJson() {
    return {
      'steam_query_mode': steamQueryMode.name,
      'use_dark_theme': useDarkTheme,
      'poll_interval_hours': pollIntervalHours,
      'minimize_to_tray_on_close': minimizeToTrayOnClose,
      'auto_backup_after_change': autoBackupAfterChange,
      'download_concurrency': downloadConcurrency,
      'http_proxy_url': httpProxyUrl,
      'local_backup_dir': localBackupDir,
      'max_local_zip_keep': maxLocalZipKeep,
    };
  }

  factory AppSettings.fromNonSensitiveJson(
    Map<String, dynamic> json, {
    String steamApiKey = '',
  }) {
    return AppSettings(
      steamApiKey: steamApiKey,
      steamQueryMode: SteamQueryMode.values.firstWhere(
          (mode) => mode.name == json['steam_query_mode'],
          orElse: () => SteamQueryMode.automatic),
      useDarkTheme: json['use_dark_theme'] as bool? ?? false,
      pollIntervalHours: json['poll_interval_hours'] as int? ?? 6,
      minimizeToTrayOnClose: json['minimize_to_tray_on_close'] as bool? ?? true,
      autoBackupAfterChange: json['auto_backup_after_change'] as bool? ?? true,
      downloadConcurrency: json['download_concurrency'] as int? ?? 4,
      httpProxyUrl: json['http_proxy_url'] as String? ?? '',
      localBackupDir: json['local_backup_dir'] as String? ?? '',
      maxLocalZipKeep: json['max_local_zip_keep'] as int? ?? 10,
    );
  }
}

/// 同步批次结果统计报告
class SyncReport {
  final String syncBatchId;
  final String creatorSteamId;
  final String creatorName;
  final bool isBaselineRun;
  final int baselineCount;
  final int addedCount;
  final int modifiedCount;
  final int missingCount;
  final int restoredCount;

  const SyncReport({
    required this.syncBatchId,
    required this.creatorSteamId,
    required this.creatorName,
    required this.isBaselineRun,
    this.baselineCount = 0,
    this.addedCount = 0,
    this.modifiedCount = 0,
    this.missingCount = 0,
    this.restoredCount = 0,
  });

  bool get hasAnyChange =>
      isBaselineRun ||
      addedCount > 0 ||
      modifiedCount > 0 ||
      missingCount > 0 ||
      restoredCount > 0;
}

/// Steam 创作者输入智能解析器（支持直接输入 64 位 SteamID、profiles 链接、id 个性链接）
class SteamInputParser {
  /// Only accept item URLs from Steam; bare IDs are enabled by the item tab.
  static String? parseWorkshopFileId(String input, {bool allowBareId = false}) {
    final value = input.trim();
    if (allowBareId && RegExp(r'^[1-9]\d{0,19}$').hasMatch(value)) {
      return value;
    }
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme == 'steam' && uri.host == 'url') {
      final parts = uri.pathSegments;
      if (parts.length == 2 &&
          parts.first == 'CommunityFilePage' &&
          RegExp(r'^[1-9]\d{0,19}$').hasMatch(parts.last)) {
        return parts.last;
      }
      return null;
    }
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.toLowerCase() != 'steamcommunity.com' ||
        ![
          '/sharedfiles/filedetails',
          '/sharedfiles/filedetails/',
          '/workshop/filedetails',
          '/workshop/filedetails/'
        ].contains(uri.path)) {
      return null;
    }
    final id = uri.queryParameters['id'];
    return id != null && RegExp(r'^[1-9]\d{0,19}$').hasMatch(id) ? id : null;
  }

  static final RegExp _steamId64Regex = RegExp(r'^\d{17}$');
  static final RegExp _profilesUrlRegex =
      RegExp(r'steamcommunity\.com/profiles/(\d{17})');
  static final RegExp _vanityUrlRegex =
      RegExp(r'steamcommunity\.com/id/([a-zA-Z0-9_\-]+)');

  static ({String? steamId64, String? vanityName}) parseCreatorInput(
    String rawInput,
  ) {
    final trimmed = rawInput.trim();
    if (_steamId64Regex.hasMatch(trimmed)) {
      return (steamId64: trimmed, vanityName: null);
    }
    final profileMatch = _profilesUrlRegex.firstMatch(trimmed);
    if (profileMatch != null) {
      return (steamId64: profileMatch.group(1), vanityName: null);
    }
    final vanityMatch = _vanityUrlRegex.firstMatch(trimmed);
    if (vanityMatch != null) {
      return (steamId64: null, vanityName: vanityMatch.group(1));
    }
    return (steamId64: null, vanityName: trimmed);
  }
}
