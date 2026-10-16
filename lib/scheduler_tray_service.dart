import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'backup_service.dart';
import 'diff_engine.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';
import 'webdav_backup.dart';

const desktopMinimumSize = Size(960, 680);

Future<void> configureDesktopWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(desktopMinimumSize);
  final size = await windowManager.getSize();
  if (size.width < desktopMinimumSize.width ||
      size.height < desktopMinimumSize.height) {
    await windowManager.setSize(Size(
      size.width < desktopMinimumSize.width
          ? desktopMinimumSize.width
          : size.width,
      size.height < desktopMinimumSize.height
          ? desktopMinimumSize.height
          : size.height,
    ));
  }
}

/// 桌面端系统托盘驻留与后台定时轮询守护服务
class SchedulerAndTrayService with WindowListener, TrayListener {
  final WorkshopDatabase database;
  final WorkshopDiffEngine diffEngine;
  final BackupService backupService;
  final Future<void> Function(String bannerMessage) onBackgroundSyncEvent;

  bool _running = false;
  final void Function(bool busy)? onBusyChanged;
  final void Function(
          String creatorId, int completed, int total, bool finished)?
      onCreatorProgress;
  Timer? _pollingTimer;
  AppSettings _currentSettings;

  SchedulerAndTrayService({
    required this.database,
    required this.diffEngine,
    required this.backupService,
    required AppSettings initialSettings,
    required this.onBackgroundSyncEvent,
    this.onBusyChanged,
    this.onCreatorProgress,
  }) : _currentSettings = initialSettings;

  /// 初始化桌面窗口拦截与系统托盘菜单
  Future<void> initializeDesktopIntegration() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return;
    }

    try {
      await configureDesktopWindow();
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);

      trayManager.addListener(this);
      final menu = Menu(
        items: [
          MenuItem(key: 'show_window', label: '显示 WE 工坊监测主窗口'),
          MenuItem(key: 'sync_all_now', label: '立即轮询所有创作者'),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: '彻底退出程序'),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (_) {
      // 若在未配置系统托盘图标资源的开发调试环境下运行，静默降级不影响主窗口使用
    }

    applyPollingSchedule(_currentSettings);
  }

  /// 更新配置并重设定时轮询周期
  void applyPollingSchedule(AppSettings newSettings) {
    _currentSettings = newSettings;
    _pollingTimer?.cancel();
    _pollingTimer = null;

    if (newSettings.pollIntervalHours > 0) {
      _pollingTimer = Timer.periodic(
        Duration(hours: newSettings.pollIntervalHours),
        (_) => runScheduledSyncAllCreators(),
      );
    }
  }

  Future<SyncReport> _syncOne(Creator creator) async {
    var completed = 0;
    var total = 0;
    onCreatorProgress?.call(creator.steamId, 0, 0, false);
    try {
      return await diffEngine.syncCreator(
          creator: creator,
          apiKey: _currentSettings.steamApiKey,
          queryMode: _currentSettings.steamQueryMode,
          onProgress: (count, all) {
            completed = count;
            total = all;
            onCreatorProgress?.call(creator.steamId, count, all, false);
          });
    } finally {
      onCreatorProgress?.call(creator.steamId, completed, total, true);
    }
  }

  Future<SyncReport> syncCreatorNow(Creator creator) async {
    if (_running) throw StateError('已有同步任务正在运行');
    _running = true;
    onBusyChanged?.call(true);
    try {
      return await _syncOne(creator);
    } finally {
      _running = false;
      onBusyChanged?.call(false);
    }
  }

  Future<void> runAutomaticBackup() async {
    if (!_currentSettings.autoBackupAfterChange) return;
    final errors = <String>[];
    if (_currentSettings.localBackupDir.trim().isNotEmpty) {
      try {
        await backupService.runLocalMirrorSync(
            targetMirrorDir: _currentSettings.localBackupDir.trim(),
            lightweight: _currentSettings.lightweightBackup);
      } catch (_) {
        errors.add('本地自动备份失败');
      }
    }
    if (_currentSettings.webdavEnabled) {
      try {
        await runWebDavBackup(
            database: database,
            backups: backupService,
            settings: _currentSettings);
      } catch (_) {
        errors.add('WebDAV 自动备份失败');
      }
    }
    if (errors.isNotEmpty) throw Exception(errors.join('；'));
  }

  Future<void> runScheduledSyncAllCreators() async {
    if (_running) return;
    _running = true;
    onBusyChanged?.call(true);
    final errors = <String>[];
    var changed = false;
    try {
      for (final creator in await database.getAllCreators()) {
        try {
          changed = (await _syncOne(creator)).hasAnyChange || changed;
        } catch (_) {
          errors.add('${creator.personaName} 同步失败');
        }
        await onBackgroundSyncEvent('');
      }
      if (changed) {
        try {
          await runAutomaticBackup();
        } catch (_) {
          errors.add('自动备份失败，请检查备份设置');
        }
      }
    } finally {
      _running = false;
      onBusyChanged?.call(false);
      await onBackgroundSyncEvent(errors.join('；'));
    }
  }

  @override
  void onWindowClose() async {
    if (_currentSettings.minimizeToTrayOnClose) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show_window':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'sync_all_now':
        await runScheduledSyncAllCreators();
        break;
      case 'exit_app':
        _pollingTimer?.cancel();
        await windowManager.destroy();
        break;
    }
  }

  void dispose() {
    _pollingTimer?.cancel();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }
}
