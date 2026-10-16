import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'backup_service.dart';
import 'diff_engine.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';

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

  Timer? _pollingTimer;
  AppSettings _currentSettings;

  SchedulerAndTrayService({
    required this.database,
    required this.diffEngine,
    required this.backupService,
    required AppSettings initialSettings,
    required this.onBackgroundSyncEvent,
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

  /// 后台批量轮询所有已添加的创作者，并在发现变更时自动触发本地增量备份
  Future<void> runScheduledSyncAllCreators() async {
    final creators = await database.getAllCreators();
    if (creators.isEmpty) return;

    bool anyChanged = false;
    int totalMissingDetected = 0;

    for (final creator in creators) {
      try {
        final report = await diffEngine.syncCreator(
          creator: creator,
          apiKey: _currentSettings.steamApiKey,
          queryMode: _currentSettings.steamQueryMode,
          onStatusUpdate: (msg) => onBackgroundSyncEvent(msg),
        );
        if (report.hasAnyChange) {
          anyChanged = true;
        }
        totalMissingDetected += report.missingCount;
      } catch (_) {}
    }

    // 若检测到新增、修改或下架，且开启了自动备份，则自动执行本地镜像增量同步
    if (anyChanged && _currentSettings.autoBackupAfterChange) {
      try {
        if (_currentSettings.localBackupDir.trim().isNotEmpty) {
          await backupService.runLocalMirrorSync(
            targetMirrorDir: _currentSettings.localBackupDir.trim(),
          );
        }
      } catch (_) {}
    }

    if (totalMissingDetected > 0) {
      await onBackgroundSyncEvent(
        '告警：后台轮询发现 $totalMissingDetected 件创意工坊作品已消失/下架，本地档案已锁定保留！',
      );
    } else {
      await onBackgroundSyncEvent('');
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
