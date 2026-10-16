import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';
import 'backup_service.dart';
import 'diff_engine.dart';
import 'scheduler_tray_service.dart';
import 'steam_api_service.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';
import 'workshop_preview.dart';
import 'workspace_widgets.dart';
import 'workshop_timeline.dart';
import 'workshop_history_view.dart';
import 'workshop_change_details.dart';
import 'webdav_backup.dart';
import 'webdav_settings_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await WorkshopDatabase.initialize();
  runApp(WorkshopMonitorApp(database: database));
}

class WorkshopMonitorApp extends StatelessWidget {
  final WorkshopDatabase database;
  const WorkshopMonitorApp({super.key, required this.database});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, mode, _) => MaterialApp(
            title: '工坊档案 · Workshop Library',
            debugShowCheckedModeBanner: false,
            themeAnimationDuration: Duration.zero,
            theme: buildWorkshopTheme(),
            home: MainDesktopShell(database: database)),
      );
}

class MainDesktopShell extends StatefulWidget {
  final WorkshopDatabase database;

  const MainDesktopShell({super.key, required this.database});

  @override
  State<MainDesktopShell> createState() => _MainDesktopShellState();
}

class _MainDesktopShellState extends State<MainDesktopShell> {
  static final _secureStorage = FlutterSecureStorage();
  static final _kSteamApiKeyStorageKey = 'we_monitor_steam_api_key';
  static const _webdavPasswordKey = 'we_monitor_webdav_password';

  int _selectedNavIndex = 0;
  String? _settingsPage;
  int _settingsReturnNav = 3;
  bool _choosingCreator = false;
  final Set<ContentRating> _visibleRatings = {ContentRating.safe};
  final _workspaceCaptureKey = GlobalKey();
  ui.Image? _previousThemeFrame;
  bool _switchingTheme = false;
  ItemStatus? _galleryStatusFilter;
  bool _onlyModifiedFilter = false;
  String? _selectedCreatorId;
  String _searchQuery = '';
  final double _galleryCardMaxExtent = 340;

  final Map<String, ({int completed, int total})> _creatorProgress = {};
  bool _backupBusy = false;
  bool _isBusy = false;
  bool _obscureApiKey = true;
  bool _testingApiKey = false;
  String? _apiTestResult;
  bool _apiTestFailed = false;

  List<Creator> _creators = [];
  List<WorkshopItem> _items = [];
  List<WorkshopItem> _archiveItems = [];
  List<ItemChangeLog> _logs = [];
  List<BackupRecord> _backupRecords = [];
  AppSettings _settings = AppSettings();

  late final TextEditingController _searchCtrl;
  late final TextEditingController _apiKeyCtrl;
  late final TextEditingController _localDirCtrl;

  late final SteamWorkshopService _steamService;
  late final WorkshopDiffEngine _diffEngine;
  late final BackupService _backupService;
  late final SchedulerAndTrayService _schedulerTrayService;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    _apiKeyCtrl = TextEditingController();
    _localDirCtrl = TextEditingController();

    _steamService = SteamWorkshopService(
      dataRootDir: widget.database.dataRootDir,
    );
    _diffEngine = WorkshopDiffEngine(
      database: widget.database,
      steamService: _steamService,
    );
    _backupService = BackupService(database: widget.database);
    _schedulerTrayService = SchedulerAndTrayService(
      database: widget.database,
      diffEngine: _diffEngine,
      backupService: _backupService,
      initialSettings: _settings,
      onBackgroundSyncEvent: (message) async {
        if (!mounted) return;
        if (message.isNotEmpty) _showToast(message, isWarning: true);
        await _refreshData();
      },
      onBusyChanged: (busy) {
        if (mounted) setState(() => _isBusy = busy);
      },
      onCreatorProgress: (id, completed, total, finished) {
        if (!mounted) return;
        setState(() {
          if (finished) {
            _creatorProgress.remove(id);
          } else {
            _creatorProgress[id] = (completed: completed, total: total);
          }
        });
      },
    );
    _initializeSettingsAndData();
  }

  void _syncControllersFromSettings() {
    _apiKeyCtrl.text = _settings.steamApiKey;
    _localDirCtrl.text = _settings.localBackupDir;
  }

  Future<void> _initializeSettingsAndData() async {
    try {
      final savedMap = await widget.database.loadConfigJson();
      String apiKey = '';
      String webdavPassword = '';
      try {
        apiKey = await _secureStorage.read(key: _kSteamApiKeyStorageKey) ?? '';
        webdavPassword =
            await _secureStorage.read(key: _webdavPasswordKey) ?? '';
      } catch (_) {}

      if (savedMap != null) {
        _settings = AppSettings.fromNonSensitiveJson(
          savedMap,
          steamApiKey: apiKey,
          webdavPassword: webdavPassword,
        );
      } else {
        _settings = _settings.copyWith(
          steamApiKey: apiKey,
          webdavPassword: webdavPassword,
        );
      }
      _syncControllersFromSettings();
      appThemeMode.value =
          _settings.useDarkTheme ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {}

    await _schedulerTrayService.initializeDesktopIntegration();
    _schedulerTrayService.applyPollingSchedule(_settings);
    await _refreshData();
  }

  Future<void> _persistSettings(AppSettings updated) async {
    setState(() => _settings = updated);
    appThemeMode.value =
        updated.useDarkTheme ? ThemeMode.dark : ThemeMode.light;
    await widget.database.saveConfigJson(updated.toNonSensitiveJson());
    try {
      await _secureStorage.write(
        key: _kSteamApiKeyStorageKey,
        value: updated.steamApiKey,
      );
    } catch (_) {}
    _schedulerTrayService.applyPollingSchedule(updated);
  }

  Future<void> _refreshData() async {
    final creators = await widget.database.getAllCreators();
    final items = await widget.database.queryItems(
      creatorSteamId: _selectedCreatorId,
      statusFilter: _galleryStatusFilter,
      searchQuery: _searchQuery,
      onlyModified: _onlyModifiedFilter,
    );
    final allItems = await widget.database.queryItems();
    final logs = await widget.database.getChangeLogs(limit: -1);
    final backups = await widget.database.getBackupRecords();

    if (!mounted) return;
    setState(() {
      _creators = creators;
      _items = items
          .where((item) => _visibleRatings.contains(item.contentRating))
          .toList();
      _archiveItems = allItems;
      _logs = logs;
      _backupRecords = backups;
    });
  }

  Future<void> _triggerCreatorSync(Creator creator) async {
    if (_isBusy) return;
    try {
      final report = await _schedulerTrayService.syncCreatorNow(creator);

      // Publish saved records before an optional backup can fail, and reveal
      // the newly built archive instead of leaving the user on stale filters.
      if (report.isBaselineRun && mounted) {
        setState(() {
          _selectedNavIndex = 1;
          _selectedCreatorId = null;
          _galleryStatusFilter = null;
          _onlyModifiedFilter = false;
          _searchQuery = '';
          _searchCtrl.clear();
        });
      }
      await _refreshData();
      try {
        await _refreshCreatorAvatar(creator);
      } catch (_) {}
      String? backupWarning;
      if (report.hasAnyChange) {
        try {
          await _schedulerTrayService.runAutomaticBackup();
        } catch (_) {
          backupWarning = '作品已保存，但自动备份失败，请检查备份设置';
        }
      }

      await _refreshData();
      if (!mounted) return;
      final summary = report.isBaselineRun
          ? '首次全量基线建档完成：共归档 ${report.baselineCount} 件作品及预览图'
          : '增量同步完成：新增 ${report.addedCount} · 修改 ${report.modifiedCount} · 消失下架 ${report.missingCount} · 恢复 ${report.restoredCount}';
      _showToast(
        '$summary（${_steamService.lastFetchSourceLabel}）${backupWarning == null ? '' : '。$backupWarning'}',
        isWarning: report.missingCount > 0 || backupWarning != null,
      );
    } catch (e) {
      if (!mounted) return;
      _showToast('同步失败: $e', isError: true);
    }
  }

  void _showToast(
    String message, {
    bool isError = false,
    bool isWarning = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bgColor = isError
        ? scheme.errorContainer
        : isWarning
            ? scheme.tertiaryContainer
            : scheme.secondaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : isWarning
            ? scheme.onTertiaryContainer
            : scheme.onSecondaryContainer;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: bgColor,
        margin: EdgeInsets.all(20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline
                  : isWarning
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
              color: foreground,
              size: 20,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _previousThemeFrame?.dispose();
    _previousThemeFrame = null;
    _searchCtrl.dispose();
    _apiKeyCtrl.dispose();
    _localDirCtrl.dispose();
    _schedulerTrayService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalActive =
        _creators.fold<int>(0, (sum, c) => sum + c.totalActiveCount);
    final totalMissing =
        _creators.fold<int>(0, (sum, c) => sum + c.totalMissingCount);

    final workspace = Scaffold(
      body: Row(
        children: [
          if (MediaQuery.sizeOf(context).width >= 1200)
            _buildCustomSidebar(
                totalActive: totalActive, totalMissing: totalMissing)
          else
            _buildCompactNavigation(),
          Expanded(
            child: Column(
              children: [
                _buildWorkspaceToolbar(),
                Expanded(
                  child: <Widget Function()>[
                    () => _buildCreatorsView(
                          totalActive: totalActive,
                          totalMissing: totalMissing,
                        ),
                    () => _buildGalleryView(
                          totalActive: totalActive,
                          totalMissing: totalMissing,
                        ),
                    _buildChangeLogView,
                    _buildBackupSettingsView,
                  ][_selectedNavIndex](),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Stack(fit: StackFit.expand, children: [
      RepaintBoundary(key: _workspaceCaptureKey, child: workspace),
      if (_previousThemeFrame != null)
        IgnorePointer(
            child: TweenAnimationBuilder<double>(
          key: ValueKey(_previousThemeFrame),
          tween: Tween(begin: 1, end: 0),
          duration: Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          onEnd: () {
            final frame = _previousThemeFrame;
            if (mounted) {
              setState(() {
                _previousThemeFrame = null;
                _switchingTheme = false;
              });
            }
            WidgetsBinding.instance
                .addPostFrameCallback((_) => frame?.dispose());
          },
          builder: (_, opacity, child) =>
              Opacity(opacity: opacity, child: child),
          child: RawImage(image: _previousThemeFrame, fit: BoxFit.fill),
        )),
    ]);
  }

  Future<void> _changeTheme(bool dark) async {
    if (_switchingTheme || dark == AppPalette.dark) return;
    _switchingTheme = true;
    final boundary = _workspaceCaptureKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;
    ui.Image? frame;
    try {
      frame = await boundary?.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context));
    } catch (_) {}
    if (!mounted) {
      frame?.dispose();
      return;
    }
    setState(() => _previousThemeFrame = frame);
    await _persistSettings(_settings.copyWith(useDarkTheme: dark));
    if (frame == null) _switchingTheme = false;
  }

  void _openSettingsPage(String page, {int returnNav = 3}) {
    setState(() {
      _settingsPage = page;
      _settingsReturnNav = returnNav;
      _selectedNavIndex = 3;
    });
  }

  void _selectWorkspace(int index) {
    setState(() {
      _selectedNavIndex = index;
      _settingsPage = null;
      _choosingCreator = false;
    });
    _refreshData();
  }

  Widget _buildCompactNavigation() => _buildNavigation(compact: true);
  Widget _buildCustomSidebar(
          {required int totalActive, required int totalMissing}) =>
      _buildNavigation();

  Widget _buildNavigation({bool compact = false}) {
    final labels = ['创作者', '作品资料库', '变更记录', '设置与备份'];
    final icons = [
      Icons.dashboard_outlined,
      Icons.wallpaper_outlined,
      Icons.history_rounded,
      Icons.settings_outlined
    ];
    return Container(
      width: compact ? 88 : 208,
      color: AppPalette.bgSidebar,
      child: Column(children: [
        SizedBox(height: 26),
        Padding(
            padding: EdgeInsets.symmetric(horizontal: 22),
            child: Row(children: [
              Icon(Icons.layers_rounded,
                  size: 28, color: AppPalette.accentCyan),
              if (!compact) ...[
                SizedBox(width: 12),
                Text('工坊档案',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))
              ],
            ])),
        SizedBox(height: 36),
        for (var i = 0; i < labels.length; i++)
          Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Tooltip(
                  message: labels[i],
                  child: Material(
                    color: _selectedNavIndex == i
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(compact ? 20 : 16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => _selectWorkspace(i),
                      child: Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: compact ? 8 : 16, vertical: 15),
                          child: compact
                              ? Column(children: [
                                  Icon(icons[i], size: 23),
                                  SizedBox(height: 5),
                                  Text(['概览', '作品', '动态', '设置'][i],
                                      style: TextStyle(fontSize: 12)),
                                ])
                              : Row(children: [
                                  Icon(icons[i], size: 22),
                                  SizedBox(width: 14),
                                  Text(i == 0 ? '概览' : labels[i],
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: _selectedNavIndex == i
                                              ? FontWeight.w600
                                              : FontWeight.w400)),
                                ])),
                    ),
                  ))),
        Spacer(),
        IconButton(
            tooltip: AppPalette.dark ? '切换浅色主题' : '切换深色主题',
            onPressed: () => _changeTheme(!AppPalette.dark),
            icon: Icon(AppPalette.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined)),
        SizedBox(height: 10),
        if (!compact)
          Text('Wallpaper Engine · 本地档案',
              style: TextStyle(fontSize: 12, color: AppPalette.textMuted)),
        SizedBox(height: 24),
      ]),
    );
  }

  Widget _buildWorkspaceToolbar() {
    final titles = ['概览', '作品资料库', '变更记录', '设置与备份'];
    return Padding(
      padding: EdgeInsets.fromLTRB(28, 22, 28, 8),
      child: Row(children: [
        if (_settingsPage != null || _choosingCreator) ...[
          IconButton(
              tooltip: '返回',
              icon: Icon(Icons.arrow_back_rounded),
              onPressed: () => setState(() {
                    if (_settingsPage != null) {
                      _settingsPage = null;
                      _selectedNavIndex = _settingsReturnNav;
                    }
                    _choosingCreator = false;
                  })),
          SizedBox(width: 8),
        ],
        Text(
            _selectedNavIndex == 3 && _settingsPage != null
                ? {
                    'query': '作品查询与同步',
                    'backup': '本地备份',
                    'webdav': 'WebDAV 云端备份',
                    'appearance': '外观',
                    'content': '内容分级'
                  }[_settingsPage]!
                : _choosingCreator
                    ? '选择创作者'
                    : titles[_selectedNavIndex],
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500)),
        Spacer(),
        if (_selectedNavIndex == 0) ...[
          IconButton.filledTonal(
              tooltip: '同步全部创作者',
              onPressed: _isBusy || _creators.isEmpty
                  ? null
                  : () => _schedulerTrayService.runScheduledSyncAllCreators(),
              icon: Icon(Icons.sync_rounded, size: 21)),
          SizedBox(width: 10),
          IconButton.filledTonal(
              tooltip: '添加创作者',
              onPressed: _isBusy ? null : _showAddCreatorDialog,
              icon: Icon(Icons.add_rounded, size: 21)),
        ] else
          Icon(Icons.layers_outlined, color: AppPalette.textMuted, size: 23),
      ]),
    );
  }

  // ==========================================================================
  // 视图 1：概览与创作者
  // ==========================================================================
  Widget _buildCreatorsView(
      {required int totalActive, required int totalMissing}) {
    final ready = _creators.where((c) => c.isBaselineCompleted).length;
    final scheme = Theme.of(context).colorScheme;
    final archive = WorkspaceSurface(
        tonal: true,
        onTap: () => _selectWorkspace(1),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.inventory_2_outlined, size: 20),
            SizedBox(width: 10),
            Text('作品档案', style: TextStyle(fontSize: 14)),
            Spacer(),
            Icon(Icons.arrow_outward_rounded, size: 20)
          ]),
          SizedBox(height: 24),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${totalActive + totalMissing}',
                style: TextStyle(
                    fontSize: 48,
                    height: 1,
                    fontWeight: FontWeight.w400,
                    color: scheme.onSecondaryContainer)),
            Padding(
                padding: EdgeInsets.only(left: 10, bottom: 5),
                child: Text('件已归档',
                    style: TextStyle(color: scheme.onSecondaryContainer))),
          ]),
          SizedBox(height: 24),
          ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                  value: totalActive + totalMissing == 0
                      ? 0
                      : totalActive / (totalActive + totalMissing),
                  minHeight: 7,
                  color: AppPalette.accentCyan,
                  backgroundColor:
                      scheme.onSecondaryContainer.withValues(alpha: .10))),
          SizedBox(height: 14),
          Row(children: [
            Text('$totalActive 可访问', style: TextStyle(fontSize: 12)),
            Spacer(),
            Text('$totalMissing 消失 / 下架', style: TextStyle(fontSize: 12))
          ]),
        ]));
    final connection = WorkspaceSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.hub_outlined, size: 20),
        SizedBox(width: 10),
        Text('查询与同步', style: TextStyle(fontSize: 14)),
        Spacer(),
        Icon(Icons.circle,
            size: 8,
            color:
                _isBusy ? AppPalette.statusModified : AppPalette.statusActive)
      ]),
      SizedBox(height: 24),
      Text(_settings.steamQueryMode.label,
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w500)),
      SizedBox(height: 8),
      Text(
          _settings.pollIntervalHours == 0
              ? '手动同步 · 按需检查作品更新'
              : '每 ${_settings.pollIntervalHours} 小时自动检查',
          style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
      SizedBox(height: 22),
      Row(children: [
        Text('$ready / ${_creators.length} 位已建档',
            style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
        Spacer(),
        TextButton(onPressed: () => _selectWorkspace(3), child: Text('管理设置'))
      ]),
    ]));
    return ListView(padding: EdgeInsets.fromLTRB(28, 20, 28, 28), children: [
      LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 760
              ? IntrinsicHeight(
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      Expanded(flex: 3, child: archive),
                      SizedBox(width: 16),
                      Expanded(flex: 2, child: connection)
                    ]))
              : Column(children: [archive, SizedBox(height: 16), connection])),
      SizedBox(height: 28),
      Row(children: [
        Text('创作者',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        SizedBox(width: 10),
        Text('${_creators.length}',
            style: TextStyle(color: AppPalette.textMuted)),
        Spacer(),
        TextButton.icon(
            onPressed: _isBusy ? null : _showAddCreatorDialog,
            icon: Icon(Icons.add_rounded, size: 18),
            label: Text('添加创作者'))
      ]),
      SizedBox(height: 12),
      if (_creators.isEmpty)
        _buildEmptyStateCard(
            icon: Icons.person_add_alt,
            title: '从一张喜欢的壁纸开始',
            subtitle: '粘贴作品链接，识别并关注创作者。',
            actionLabel: '添加第一位创作者',
            onAction: _showAddCreatorDialog)
      else
        WorkspaceSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < _creators.length; i++) ...[
                if (i > 0)
                  Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24),
                      child: Divider()),
                _buildCreatorRowCard(_creators[i]),
              ],
            ])),
      SizedBox(height: 20),
      Row(children: [
        Icon(Icons.shield_outlined, size: 15, color: AppPalette.textMuted),
        SizedBox(width: 8),
        Expanded(
            child: Text('作品信息与历史预览图保存在本机',
                style: TextStyle(fontSize: 12, color: AppPalette.textMuted)))
      ]),
    ]);
  }

  Widget _creatorAvatar(Creator creator) {
    final initial = creator.personaName.isEmpty
        ? '?'
        : creator.personaName.characters.first.toUpperCase();
    final placeholder = ColoredBox(
        color: AppPalette.accentCyan.withValues(alpha: .12),
        child: Center(
            child: Text(initial,
                style: TextStyle(fontSize: 19, color: AppPalette.accentCyan))));
    final path = creator.avatarLocalPath;
    return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
            width: 44,
            height: 44,
            child: path == null
                ? placeholder
                : Image.file(File(p.join(widget.database.dataRootDir, path)),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder)));
  }

  Future<void> _refreshCreatorAvatar(Creator creator,
      {bool notify = false}) async {
    final identity = await _steamService.resolveCreatorIdentity(
        rawInput: creator.steamId, apiKey: _settings.steamApiKey);
    final path = await _steamService.downloadCreatorAvatar(
        steamId: creator.steamId, avatarUrl: identity.avatarUrl);
    if (path != null) {
      final current = (await widget.database.getAllCreators())
          .where((c) => c.steamId == creator.steamId)
          .firstOrNull;
      if (current != null) {
        await widget.database
            .upsertCreator(current.copyWith(avatarLocalPath: path));
      }
      await _refreshData();
    }
    if (mounted && notify) {
      _showToast(path == null ? '暂时无法获取头像，已保留现有头像' : '头像已更新');
    }
  }

  Widget _buildCreatorRowCard(Creator creator) {
    final actions = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _selectedCreatorId = creator.steamId;
                _selectedNavIndex = 1;
              });
              _refreshData();
            },
            icon: Icon(Icons.grid_view_rounded, size: 16),
            label: Text('查看作品'),
          ),
          SizedBox(
              width: 116,
              child: FilledButton.tonalIcon(
                onPressed: _isBusy ? null : () => _triggerCreatorSync(creator),
                icon: Icon(Icons.sync, size: 17),
                label: Text(creator.isBaselineCompleted ? '同步' : '建立档案'),
              )),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) async {
              if (value == 'avatar') {
                await _refreshCreatorAvatar(creator, notify: true);
              }
              if (value == 'open') {
                await launchUrl(Uri.parse(creator.profileUrl));
              }
              if (value == 'copy') {
                await Clipboard.setData(ClipboardData(text: creator.steamId));
                if (mounted) _showToast('已复制 SteamID');
              }
              if (value == 'remove') {
                if (!mounted) return;
                final remove = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                          title: Text('移除创作者？'),
                          content:
                              Text('将移除「${creator.personaName}」的监测及本地作品记录。'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: Text('取消')),
                            TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: Text('移除'))
                          ],
                        ));
                if (remove == true) {
                  await widget.database.deleteCreator(creator.steamId);
                  if (_selectedCreatorId == creator.steamId && mounted) {
                    setState(() => _selectedCreatorId = null);
                  }
                  await _refreshData();
                }
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'open', child: Text('打开创意工坊')),
              PopupMenuItem(value: 'copy', child: Text('复制 SteamID')),
              PopupMenuItem(value: 'avatar', child: Text('更新头像')),
              PopupMenuItem(
                  value: 'remove',
                  enabled: !_isBusy,
                  child: Text('移除监测',
                      style: TextStyle(color: AppPalette.statusMissing))),
            ],
          ),
        ]);
    final identity =
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      _creatorAvatar(creator),
      SizedBox(width: 14),
      Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(creator.personaName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary)),
      ])),
    ]);
    Widget metric(Widget value, String caption, {double indent = 0}) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              height: 22,
              child: Align(alignment: Alignment.centerLeft, child: value)),
          SizedBox(height: 4),
          Padding(
              padding: EdgeInsets.only(left: indent),
              child: Text(caption,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppPalette.textSecondary))),
        ]);
    final progress = _creatorProgress[creator.steamId];
    final metrics = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 84,
              child: metric(
                  Text(
                      '${creator.totalActiveCount + creator.totalMissingCount}',
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          fontWeight: FontWeight.w600)),
                  '已归档作品')),
          SizedBox(width: 24),
          SizedBox(
              width: 142,
              child: metric(
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.circle,
                        size: 6,
                        color: creator.isBaselineCompleted
                            ? AppPalette.statusActive
                            : AppPalette.statusModified),
                    SizedBox(width: 6),
                    Text(
                        progress != null
                            ? '${progress.completed} / ${progress.total > 0 ? progress.total : '—'}'
                            : creator.isBaselineCompleted
                                ? '已建立档案'
                                : '等待同步',
                        style: TextStyle(fontSize: 14, height: 1.4)),
                  ]),
                  progress != null
                      ? '同步中'
                      : creator.lastSyncedAt == null
                          ? '尚未同步'
                          : creator.lastSyncedAt!
                              .toLocal()
                              .toString()
                              .substring(0, 16),
                  indent: 12)),
        ]);
    return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: Container(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
            child: LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth < 940) {
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      identity,
                      SizedBox(height: 18),
                      Wrap(
                          spacing: 24,
                          runSpacing: 14,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [metrics, actions]),
                    ]);
              }
              return Row(children: [
                Expanded(child: identity),
                SizedBox(width: 28),
                metrics,
                SizedBox(width: 32),
                actions
              ]);
            })));
  }

  Widget _buildStatusPill({required String label, required Color color}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ==========================================================================
  // 视图 2：作品资料库
  // ==========================================================================
  Widget _buildGalleryView(
      {required int totalActive, required int totalMissing}) {
    if (_choosingCreator) {
      return ListView(padding: EdgeInsets.all(28), children: [
        WorkspaceSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              ListTile(
                  title: Text('全部创作者'),
                  trailing:
                      _selectedCreatorId == null ? Icon(Icons.check) : null,
                  onTap: () {
                    setState(() {
                      _selectedCreatorId = null;
                      _choosingCreator = false;
                    });
                    _refreshData();
                  }),
              for (final creator in _creators)
                ListTile(
                    leading: _creatorAvatar(creator),
                    title: Text(creator.personaName),
                    subtitle: Text(creator.steamId),
                    trailing: _selectedCreatorId == creator.steamId
                        ? Icon(Icons.check)
                        : null,
                    onTap: () {
                      setState(() {
                        _selectedCreatorId = creator.steamId;
                        _choosingCreator = false;
                      });
                      _refreshData();
                    }),
            ])),
      ]);
    }
    return Padding(
        padding: EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('所有作品', style: TextStyle(fontSize: 14)),
            Spacer(),
            Text('显示 ${_items.length} 件 · 全部归档 ${totalActive + totalMissing} 件',
                style: TextStyle(fontSize: 12, color: AppPalette.textSecondary))
          ]),
          SizedBox(height: 18),
          LayoutBuilder(
              builder: (context, constraints) => Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                            width: constraints.maxWidth < 700
                                ? constraints.maxWidth
                                : 300,
                            child: TextField(
                                controller: _searchCtrl,
                                decoration: InputDecoration(
                                    prefixIcon:
                                        Icon(Icons.search_rounded, size: 19),
                                    hintText: '搜索标题、简介或作品 ID',
                                    suffixIcon: _searchQuery.isEmpty
                                        ? null
                                        : IconButton(
                                            icon: Icon(Icons.close, size: 16),
                                            onPressed: () {
                                              _searchCtrl.clear();
                                              setState(() => _searchQuery = '');
                                              _refreshData();
                                            })),
                                onChanged: (value) {
                                  setState(() => _searchQuery = value);
                                  _refreshData();
                                })),
                        ActionChip(
                            avatar: Icon(Icons.person_outline, size: 18),
                            label: Text(_selectedCreatorId == null
                                ? '全部创作者'
                                : _creators
                                    .firstWhere(
                                        (c) => c.steamId == _selectedCreatorId)
                                    .personaName),
                            onPressed: () =>
                                setState(() => _choosingCreator = true)),
                        for (final status in <ItemStatus?>[
                          null,
                          ItemStatus.active,
                          ItemStatus.missing
                        ])
                          ChoiceChip(
                              label: Text(status?.label ?? '全部状态'),
                              selected: _galleryStatusFilter == status,
                              onSelected: (_) {
                                setState(() => _galleryStatusFilter = status);
                                _refreshData();
                              }),
                        ActionChip(
                            avatar: Icon(Icons.shield_outlined, size: 18),
                            label: Text(_visibleRatings.length == 1 &&
                                    _visibleRatings.contains(ContentRating.safe)
                                ? '仅安全'
                                : '内容分级 (${_visibleRatings.length})'),
                            onPressed: () =>
                                _openSettingsPage('content', returnNav: 1)),
                        FilterChip(
                            label: Text('有修改记录'),
                            selected: _onlyModifiedFilter,
                            onSelected: (value) {
                              setState(() => _onlyModifiedFilter = value);
                              _refreshData();
                            }),
                      ])),
          SizedBox(height: 20),
          Expanded(
              child: _items.isEmpty
                  ? _buildEmptyStateCard(
                      icon: Icons.photo_library_outlined,
                      title: '这里将展示归档的壁纸',
                      subtitle: '当前仅显示所选内容分级。请同步作品，或调整分级与其他筛选条件。')
                  : GridView.builder(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: _galleryCardMaxExtent,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 18,
                          childAspectRatio: 1.10),
                      itemCount: _items.length,
                      itemBuilder: (context, i) {
                        final item = _items[i];
                        return _WorkshopGalleryHoverCard(
                            item: item,
                            dataRootDir: widget.database.dataRootDir,
                            onTap: () => _showItemTimeMachineDialog(item),
                            onCopyId: () {
                              Clipboard.setData(
                                  ClipboardData(text: item.publishedFileId));
                              _showToast('已复制作品 ID');
                            });
                      })),
        ]));
  }

  // ==========================================================================
  // 作品时光机可视化对比弹窗 (Visual Diff & Multi-Cover Time Machine Modal)
  // ==========================================================================
  Future<void> _showItemTimeMachineDialog(WorkshopItem item) async {
    final historyLogs = await widget.database.getChangeLogs(
      publishedFileId: item.publishedFileId,
      limit: -1,
    );
    if (!mounted) return;

    final historicalPreviewPaths = <String>{};
    if (item.previewLocalPath != null) {
      historicalPreviewPaths.add(item.previewLocalPath!);
    }
    for (final log in historyLogs) {
      final previewDiff = log.changedFields['preview_local_path'];
      if (previewDiff is Map) {
        if (previewDiff['old'] is String &&
            (previewDiff['old'] as String).isNotEmpty) {
          historicalPreviewPaths.add(previewDiff['old'] as String);
        }
        if (previewDiff['new'] is String &&
            (previewDiff['new'] as String).isNotEmpty) {
          historicalPreviewPaths.add(previewDiff['new'] as String);
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: 48, vertical: 36),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 880, maxHeight: 740),
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 弹窗顶部标题栏
                Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: item.status.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        item.status == ItemStatus.missing
                            ? Icons.history_toggle_off
                            : Icons.auto_awesome_motion,
                        color: item.status.color,
                      ),
                    ),
                    SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.textPrimary,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '${item.formattedFileSize} · ${item.contentRating.label}',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppPalette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildStatusPill(
                      label: item.status.label,
                      color: item.status.color,
                    ),
                    SizedBox(width: 8),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: Icon(Icons.close),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Divider(height: 1),
                SizedBox(height: 16),
                // 主体滚动内容区
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. 历代封面预览图时光机对比
                        if (historicalPreviewPaths.isNotEmpty) ...[
                          Row(
                            children: [
                              Icon(
                                Icons.collections_outlined,
                                size: 17,
                                color: AppPalette.accentCyan,
                              ),
                              SizedBox(width: 8),
                              Text(
                                '封面历史 · ${historicalPreviewPaths.length} 个版本',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 12),
                          SizedBox(
                            height: 195,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final relPath in historicalPreviewPaths)
                                  Padding(
                                    padding: EdgeInsets.only(right: 14),
                                    child: SizedBox(
                                        width: 280,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                                child: ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              child: SizedBox.expand(
                                                  child: WorkshopPreview(
                                                dataRootDir:
                                                    widget.database.dataRootDir,
                                                localPath: relPath,
                                                remoteUrl: relPath ==
                                                        item.previewLocalPath
                                                    ? item.previewRemoteUrl
                                                    : '',
                                              )),
                                            )),
                                            SizedBox(height: 8),
                                            Text(
                                                relPath == item.previewLocalPath
                                                    ? '当前封面'
                                                    : '历史封面',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: AppPalette
                                                        .textSecondary)),
                                          ],
                                        )),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(height: 20),
                        ],
                        // 2. 元数据摘要与标签面板
                        Container(
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppPalette.bgCanvas,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppPalette.borderSubtle),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (item.disappearedAt != null) ...[
                                Container(
                                  padding: EdgeInsets.all(10),
                                  margin: EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: AppPalette.statusMissing
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: AppPalette.statusMissing
                                          .withValues(alpha: 0.4),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.shield_outlined,
                                        color: AppPalette.statusMissing,
                                        size: 18,
                                      ),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '该作品已于 ${item.disappearedAt!.toLocal().toString().substring(0, 19)} 从创意工坊消失/下架，本地已完整锁定其最后已知元数据与预览图。',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: AppPalette.statusMissing,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final tag in item.tags)
                                    Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppPalette.accentIndigo
                                            .withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '#$tag',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppPalette.accentCyan,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                '作品简介',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.textSecondary,
                                ),
                              ),
                              SizedBox(height: 6),
                              SelectableText(
                                item.description.isEmpty
                                    ? '（作者未填写简介）'
                                    : item.description,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: AppPalette.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(height: 20),
                        // 3. 结构化时光机变更对比列表 (Before vs After Diff Cards)
                        Row(
                          children: [
                            Icon(
                              Icons.compare_arrows_rounded,
                              size: 18,
                              color: AppPalette.statusModified,
                            ),
                            SizedBox(width: 8),
                            Text(
                              '变更历史',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 10),
                        for (var i = 0; i < historyLogs.length; i++)
                          WorkshopTimelineEntry(
                              log: historyLogs[i],
                              title: item.title,
                              isFirst: i == 0,
                              isLast: i == historyLogs.length - 1,
                              onTap: () => _showChangeDetails(
                                  historyLogs[i], item.title)),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 16),
                // 底部操作按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: item.publishedFileId),
                        );
                        _showToast('已复制作品 ID 到剪贴板');
                      },
                      icon: Icon(Icons.copy, size: 16),
                      label: Text('复制作品 ID'),
                    ),
                    SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () {
                        launchUrl(
                          Uri.parse(
                            'https://steamcommunity.com/sharedfiles/filedetails/?id=${item.publishedFileId}',
                          ),
                        );
                      },
                      icon: Icon(Icons.open_in_new, size: 16),
                      label: Text('访问 Steam 创意工坊页面'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showChangeDetails(ItemChangeLog log, String title) =>
      showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
                title:
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                content: SizedBox(
                    width: 720,
                    child: SingleChildScrollView(
                        child: _buildVisualDiffLogCard(log))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx), child: Text('关闭'))
                ],
              ));

  Widget _buildVisualDiffLogCard(ItemChangeLog log) =>
      WorkshopChangeDetails(log: log);

  // ==========================================================================
  // 视图 3：变更与下架告警时间轴 (Git 风格垂直时间轴视图)
  // ==========================================================================
  Widget _buildChangeLogView() => WorkshopHistoryView(
        creators: _creators,
        items: _archiveItems,
        logs: _logs,
        avatarBuilder: _creatorAvatar,
        onShowDetails: _showChangeDetails,
      );

  // ==========================================================================
  // 视图 4：本地备份与同步设置
  // ==========================================================================
  Widget _buildBackupSettingsView() {
    if (_settingsPage == 'webdav') {
      return WebDavSettingsView(
          settings: _settings,
          onSave: (settings) async {
            try {
              await _secureStorage.write(
                  key: _webdavPasswordKey, value: settings.webdavPassword);
            } catch (_) {
              throw const FormatException('无法保存到系统安全存储，请稍后重试');
            }
            await _persistSettings(settings);
          },
          onBackup: (settings, progress) async {
            if (_backupBusy || _isBusy) {
              throw const FormatException('请等待当前任务完成后再备份');
            }
            setState(() => _backupBusy = true);
            try {
              await runWebDavBackup(
                  database: widget.database,
                  backups: _backupService,
                  settings: settings,
                  onProgress: progress);
              await _refreshData();
            } finally {
              if (mounted) setState(() => _backupBusy = false);
            }
          });
    }
    if (_settingsPage == 'query') {
      return SingleChildScrollView(
          padding: EdgeInsets.all(28), child: _buildSteamAndScheduleCard());
    }
    if (_settingsPage == 'backup') {
      return ListView(padding: EdgeInsets.all(28), children: [
        _buildLocalBackupCard(),
        SizedBox(height: 20),
        if (_backupRecords.isNotEmpty) _buildBackupHistoryTableCard()
      ]);
    }
    if (_settingsPage == 'appearance') {
      return ListView(padding: EdgeInsets.all(28), children: [
        WorkspaceSurface(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('选择外观', style: TextStyle(fontSize: 16)),
          SizedBox(height: 20),
          SegmentedButton<bool>(segments: [
            ButtonSegment(
                value: false,
                icon: Icon(Icons.light_mode_outlined),
                label: Text('浅色')),
            ButtonSegment(
                value: true,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text('深色'))
          ], selected: {
            AppPalette.dark
          }, onSelectionChanged: (value) => _changeTheme(value.single)),
          SizedBox(height: 24),
          Text('字体', style: TextStyle(fontSize: 14)),
          SizedBox(height: 8),
          Text('Material 默认字体 · 中文 Microsoft YaHei UI',
              style: TextStyle(color: AppPalette.textSecondary)),
          SizedBox(height: 12),
          Text('工坊档案 Workshop Library 0123456789',
              style: TextStyle(fontSize: 22)),
        ])),
      ]);
    }
    if (_settingsPage == 'content') {
      return ListView(padding: EdgeInsets.all(28), children: [
        WorkspaceSurface(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              for (final rating in ContentRating.values)
                CheckboxListTile(
                    title: Text(rating.label),
                    subtitle: Text({
                      ContentRating.safe: 'Everyone',
                      ContentRating.questionable: 'Questionable',
                      ContentRating.mature: 'Mature',
                      ContentRating.unrated: '来源未提供明确分级'
                    }[rating]!),
                    value: _visibleRatings.contains(rating),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _visibleRatings.add(rating);
                        } else {
                          _visibleRatings.remove(rating);
                        }
                      });
                      _refreshData();
                    }),
            ])),
        SizedBox(height: 20),
        Text('每次启动仅显示安全内容。分级只影响作品资料库，不影响变更记录、同步与备份。未分级作品默认隐藏。',
            style: TextStyle(color: AppPalette.textSecondary, height: 1.7)),
      ]);
    }
    return ListView(padding: EdgeInsets.all(28), children: [
      WorkspaceSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            WorkspaceSettingTile(
                icon: Icons.hub_outlined,
                title: '查询方式',
                subtitle: _settings.steamQueryMode.label,
                onTap: () => _openSettingsPage('query')),
            Divider(indent: 24, endIndent: 24),
            WorkspaceSettingTile(
                icon: Icons.folder_outlined,
                title: '本地备份',
                subtitle: 'ZIP 归档与目录镜像',
                onTap: () => _openSettingsPage('backup')),
            Divider(indent: 24, endIndent: 24),
            WorkspaceSettingTile(
                icon: Icons.cloud_outlined,
                title: 'WebDAV 云端备份',
                subtitle: '默认轻量备份',
                onTap: () => _openSettingsPage('webdav')),
          ])),
      SizedBox(height: 20),
      WorkspaceSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            WorkspaceSettingTile(
                icon: Icons.palette_outlined,
                title: '外观',
                subtitle: AppPalette.dark ? '深色' : '浅色',
                onTap: () => _openSettingsPage('appearance')),
            Divider(indent: 24, endIndent: 24),
            WorkspaceSettingTile(
                icon: Icons.shield_outlined,
                title: '内容分级',
                subtitle: '每次启动默认仅安全 · 不影响同步',
                onTap: () => _openSettingsPage('content')),
          ])),
    ]);
  }

  Future<void> _testWebApiKey() async {
    if (_testingApiKey || _isBusy) return;
    final key = _apiKeyCtrl.text.trim();
    if (_creators.isEmpty) {
      setState(() {
        _apiTestFailed = true;
        _apiTestResult = '请先添加一位创作者，再测试作品查询。';
      });
      return;
    }
    setState(() {
      _testingApiKey = true;
      _apiTestResult = null;
    });
    try {
      await _persistSettings(_settings.copyWith(steamApiKey: key));
      final creator = _creators.first;
      final tested = await _steamService.testWebApiKey(
          steamId: creator.steamId, apiKey: key);
      if (!mounted) return;
      setState(() {
        _apiTestFailed = false;
        _apiTestResult = '连接成功 · 已测试 $tested 条作品。测试不会导入作品，请在创作者页同步。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _apiTestFailed = true;
        _apiTestResult = error
            .toString()
            .replaceFirst(RegExp(r'^(Exception|FormatException): '), '');
      });
    } finally {
      if (mounted) setState(() => _testingApiKey = false);
    }
  }

  Widget _buildSteamAndScheduleCard() {
    final descriptions = {
      SteamQueryMode.automatic: '填写 Key 后优先使用 Web API；否则尝试客户端，再使用公开网页。',
      SteamQueryMode.webApi: '直接使用 Key 查询，无需打开或登录 Steam 客户端。不同来源的可见作品数量可能不同。',
      SteamQueryMode.client: '使用本机 Steam 登录状态获取作者作品列表，需要安装 Wallpaper Engine。',
      SteamQueryMode.web: '无需 Key 或客户端，但公开网页可能只展示部分作品。',
    };
    return Card(
        child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Icon(Icons.hub_outlined,
                        size: 19, color: AppPalette.accentCyan),
                    SizedBox(width: 10),
                    Text('作品查询',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600))
                  ]),
                  SizedBox(height: 8),
                  Text('选择作品列表的获取方式',
                      style: TextStyle(
                          fontSize: 12, color: AppPalette.textSecondary)),
                  SizedBox(height: 22),
                  RadioGroup<SteamQueryMode>(
                      groupValue: _settings.steamQueryMode,
                      onChanged: (mode) {
                        if (mode != null && !_isBusy && !_testingApiKey) {
                          _persistSettings(_settings.copyWith(
                              steamQueryMode: mode,
                              steamApiKey: _apiKeyCtrl.text.trim()));
                        }
                      },
                      child: Column(children: [
                        for (final mode in SteamQueryMode.values)
                          RadioListTile<SteamQueryMode>(
                              value: mode,
                              enabled: !_isBusy && !_testingApiKey,
                              contentPadding: EdgeInsets.zero,
                              title: Text(mode.label),
                              subtitle: Text(descriptions[mode]!,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppPalette.textSecondary))),
                      ])),
                  SizedBox(height: 22),
                  TextField(
                      controller: _apiKeyCtrl,
                      obscureText: _obscureApiKey,
                      enabled: !_testingApiKey,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                          labelText: 'Steam Web API Key',
                          hintText: '粘贴 32 位 Key',
                          suffixIcon: IconButton(
                              tooltip: _obscureApiKey ? '显示 Key' : '隐藏 Key',
                              onPressed: () => setState(
                                  () => _obscureApiKey = !_obscureApiKey),
                              icon: Icon(
                                  _obscureApiKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 18))),
                      onSubmitted: (_) => _persistSettings(_settings.copyWith(
                          steamApiKey: _apiKeyCtrl.text.trim()))),
                  SizedBox(height: 12),
                  Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton(
                            onPressed: _isBusy || _testingApiKey
                                ? null
                                : _testWebApiKey,
                            child: Text(_testingApiKey ? '正在查询…' : '保存并测试')),
                        TextButton.icon(
                            onPressed: () => launchUrl(Uri.parse(
                                'https://steamcommunity.com/dev/apikey')),
                            icon: Icon(Icons.open_in_new_rounded, size: 14),
                            label: Text('获取 Key')),
                      ]),
                  if (_apiTestResult != null) ...[
                    SizedBox(height: 14),
                    Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: (_apiTestFailed
                                    ? AppPalette.statusMissing
                                    : AppPalette.statusActive)
                                .withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(_apiTestResult!,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color: _apiTestFailed
                                    ? AppPalette.statusMissing
                                    : AppPalette.statusActive)))
                  ],
                  SizedBox(height: 24),
                  Divider(),
                  SizedBox(height: 24),
                  Text('自动同步',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final hours in [0, 2, 6, 12, 24])
                      ChoiceChip(
                          label: Text(hours == 0 ? '仅手动' : '每 $hours 小时'),
                          selected: _settings.pollIntervalHours == hours,
                          onSelected: (_) => _persistSettings(
                              _settings.copyWith(pollIntervalHours: hours))),
                  ]),
                  SizedBox(height: 12),
                  SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('变更后自动备份', style: TextStyle(fontSize: 14)),
                      subtitle: Text('需要先配置本地备份目录',
                          style: TextStyle(
                              fontSize: 12, color: AppPalette.textMuted)),
                      value: _settings.autoBackupAfterChange,
                      onChanged: (value) => _persistSettings(
                          _settings.copyWith(autoBackupAfterChange: value))),
                  SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title:
                          Text('关闭窗口时保留后台运行', style: TextStyle(fontSize: 14)),
                      value: _settings.minimizeToTrayOnClose,
                      onChanged: (value) => _persistSettings(
                          _settings.copyWith(minimizeToTrayOnClose: value))),
                ])));
  }

  Future<void> _runLocalBackup({required bool mirror}) async {
    if (_backupBusy || _isBusy) return;
    setState(() => _backupBusy = true);
    try {
      await _persistSettings(
          _settings.copyWith(localBackupDir: _localDirCtrl.text.trim()));
      final target = _settings.localBackupDir.isNotEmpty
          ? _settings.localBackupDir
          : p.join(widget.database.dataRootDir,
              mirror ? 'local_mirror' : 'local_backups');
      if (mirror) {
        await _backupService.runLocalMirrorSync(
            targetMirrorDir: target, lightweight: _settings.lightweightBackup);
        if (mounted) _showToast('本地镜像备份已完成');
      } else {
        final archive = await _backupService.runLocalZipBackup(
            targetBackupDir: target,
            maxKeepCount: _settings.maxLocalZipKeep,
            lightweight: _settings.lightweightBackup);
        final size = (await archive.length() / 1024 / 1024).toStringAsFixed(1);
        if (mounted) {
          _showToast(
              '${_settings.lightweightBackup ? '轻量' : '原图'} ZIP 备份已完成 · $size MB');
        }
      }
      await _refreshData();
    } catch (_) {
      if (mounted) _showToast('本地备份失败，请检查目录或稍后重试', isError: true);
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  Widget _buildLocalBackupCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppPalette.statusActive.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.folder_special_outlined,
                    size: 18,
                    color: AppPalette.statusActive,
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '本地备份',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text('轻量备份')),
                  ButtonSegment(value: false, label: Text('原图备份'))
                ],
                selected: {_settings.lightweightBackup},
                onSelectionChanged: _backupBusy
                    ? null
                    : (values) => _persistSettings(
                        _settings.copyWith(lightweightBackup: values.single))),
            SizedBox(height: 12),
            Text(
                _settings.lightweightBackup
                    ? '动图转静态封面，最长边 1280px；作品与历史记录完整保留，本机原图不变。轻量镜像单独保存到 lightweight 子目录。'
                    : '保留原始预览图与动图，文件较大。',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppPalette.textSecondary)),
            SizedBox(height: 20),
            TextField(
              controller: _localDirCtrl,
              decoration: InputDecoration(
                labelText: '本地备份输出目录路径',
                hintText: '留空则默认保存在应用数据目录 local_backups 下',
              ),
              onChanged: (v) => _persistSettings(
                _settings.copyWith(localBackupDir: v.trim()),
              ),
            ),
            SizedBox(height: 12),
            Text(
              '备份作品信息、历史预览图及可读报表。可以创建 ZIP 归档，或同步到本地目录。',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.textSecondary,
                height: 1.4,
              ),
            ),
            if (_backupBusy)
              Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator()),
            SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isBusy || _backupBusy
                        ? null
                        : () => _runLocalBackup(mirror: false),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.accentCyan,
                      foregroundColor: AppPalette.bgCanvas,
                      padding: EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: Icon(Icons.folder_zip_outlined, size: 18),
                    label: Text(
                      '创建 ZIP 备份',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy || _backupBusy
                        ? null
                        : () => _runLocalBackup(mirror: true),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: Icon(Icons.drive_folder_upload_outlined, size: 18),
                    label: Text('同步到本地目录'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupHistoryTableCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最近备份与恢复审计记录',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 12),
            for (final rec in _backupRecords.take(8))
              Container(
                padding: EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                margin: EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: AppPalette.bgCanvas,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.borderSubtle),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_zip_outlined,
                      size: 18,
                      color: AppPalette.statusActive,
                    ),
                    SizedBox(width: 10),
                    _buildStatusPill(
                      label: '${rec.targetType} · ${rec.backupMode}',
                      color: AppPalette.statusActive,
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        rec.location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.textPrimary,
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      rec.createdAt.toLocal().toString().substring(0, 19),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyStateCard({
    required IconData icon,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: SingleChildScrollView(
          child: Container(
        constraints: BoxConstraints(maxWidth: 460),
        padding: EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: AppPalette.bgCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.borderSubtle),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppPalette.accentCyan.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: AppPalette.accentCyan),
            ),
            SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.textSecondary,
                height: 1.5,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.accentCyan,
                  foregroundColor: AppPalette.bgCanvas,
                ),
                icon: Icon(Icons.add, size: 18),
                label: Text(
                  actionLabel,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      )),
    );
  }

  Future<void> _showAddCreatorDialog() async {
    final inputCtrl = TextEditingController();
    final aliasCtrl = TextEditingController();
    bool isResolving = false;
    bool fromWorkshop = true;
    String? errorText;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) {
            Future<void> submit() async {
              if (isResolving) return;
              if (inputCtrl.text.trim().isEmpty) {
                setDialogState(() => errorText = '请先粘贴链接或输入 ID');
                return;
              }
              setDialogState(() {
                isResolving = true;
                errorText = null;
              });
              try {
                final resolved = fromWorkshop
                    ? await _steamService.resolveCreatorFromWorkshopItem(
                        rawInput: inputCtrl.text, apiKey: _settings.steamApiKey)
                    : await _steamService.resolveCreatorIdentity(
                        rawInput: inputCtrl.text,
                        apiKey: _settings.steamApiKey);
                if (_creators.any((c) => c.steamId == resolved.steamId64)) {
                  throw Exception('这位创作者已在监测列表中，无需重复添加');
                }
                final avatarPath = await _steamService.downloadCreatorAvatar(
                    steamId: resolved.steamId64, avatarUrl: resolved.avatarUrl);
                await widget.database.upsertCreator(Creator(
                  steamId: resolved.steamId64,
                  avatarLocalPath: avatarPath,
                  personaName: aliasCtrl.text.trim().isEmpty
                      ? resolved.personaName
                      : aliasCtrl.text.trim(),
                  profileUrl:
                      'https://steamcommunity.com/profiles/${resolved.steamId64}/myworkshopfiles/?appid=$kWallpaperEngineAppId',
                  isBaselineCompleted: false,
                  totalActiveCount: 0,
                  totalMissingCount: 0,
                  createdAt: DateTime.now().toUtc(),
                ));
                await _refreshData();
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (!ctx.mounted) return;
                setDialogState(() {
                  isResolving = false;
                  errorText = e.toString().replaceFirst(
                      RegExp(r'^(Exception|FormatException): '), '');
                });
              }
            }

            return PopScope(
              canPop: !isResolving,
              child: AlertDialog(
                title: Text('添加创作者'),
                content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(
                                value: true,
                                icon: Icon(Icons.wallpaper_outlined),
                                label: Text('从壁纸识别')),
                            ButtonSegment(
                                value: false,
                                icon: Icon(Icons.person_outline),
                                label: Text('通过作者添加')),
                          ],
                          selected: {fromWorkshop},
                          onSelectionChanged: isResolving
                              ? null
                              : (values) => setDialogState(() {
                                    fromWorkshop = values.single;
                                    errorText = null;
                                    inputCtrl.clear();
                                  }),
                        ),
                        SizedBox(height: 20),
                        Text(
                            fromWorkshop
                                ? '在 Wallpaper Engine 中打开作者任意一张壁纸的创意工坊页面，复制链接即可识别作者。'
                                : '支持 SteamID64、个人主页链接和自定义主页名称。',
                            style: TextStyle(
                                color: AppPalette.textSecondary, height: 1.6)),
                        SizedBox(height: 18),
                        TextField(
                          controller: inputCtrl,
                          enabled: !isResolving,
                          autofocus: true,
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            labelText: fromWorkshop
                                ? '壁纸作品链接或作品 ID'
                                : 'SteamID64 或作者主页链接',
                            hintText: fromWorkshop
                                ? 'https://steamcommunity.com/sharedfiles/filedetails/?id=…'
                                : '76561198… 或 https://steamcommunity.com/id/…',
                            prefixIcon: Icon(fromWorkshop
                                ? Icons.link
                                : Icons.person_search_outlined),
                          ),
                        ),
                        SizedBox(height: 16),
                        TextField(
                          controller: aliasCtrl,
                          enabled: !isResolving,
                          decoration: InputDecoration(
                              labelText: '作者备注（可选）',
                              hintText: '昵称不可读取时，可填写便于识别的名称'),
                        ),
                        SizedBox(height: 18),
                        Container(
                          padding: EdgeInsets.all(14),
                          decoration: BoxDecoration(
                              color: AppPalette.bgInput,
                              borderRadius: BorderRadius.circular(10)),
                          child: Text(
                              '作者主页隐藏时，可尝试从公开壁纸识别作者。完整作品列表仍取决于 Steam 的访问权限；无法读取时会提示，且不会将作品误标为下架。',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: AppPalette.textSecondary)),
                        ),
                        if (errorText != null) ...[
                          SizedBox(height: 14),
                          Text(errorText!,
                              style: TextStyle(
                                  color: AppPalette.statusMissing,
                                  height: 1.5)),
                        ],
                      ],
                    ),
                  ),
                ),
                actionsPadding: EdgeInsets.fromLTRB(24, 0, 24, 20),
                actions: [
                  TextButton(
                      onPressed: isResolving ? null : () => Navigator.pop(ctx),
                      child: Text('取消')),
                  FilledButton.icon(
                    onPressed: isResolving ? null : submit,
                    icon: isResolving
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.person_add_alt_1, size: 18),
                    label: Text(isResolving ? '正在识别作者…' : '识别并添加'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      // Wait for the route's exit animation before disposing its text fields.
      await Future<void>.delayed(Duration(milliseconds: 300));
      inputCtrl.dispose();
      aliasCtrl.dispose();
    }
  }
}

// ============================================================================
// 3. 桌面端交互式悬停壁纸卡片组件 (_WorkshopGalleryHoverCard)
// ============================================================================

class _WorkshopGalleryHoverCard extends StatefulWidget {
  final WorkshopItem item;
  final String dataRootDir;
  final VoidCallback onTap;
  final VoidCallback onCopyId;

  const _WorkshopGalleryHoverCard({
    required this.item,
    required this.dataRootDir,
    required this.onTap,
    required this.onCopyId,
  });

  @override
  State<_WorkshopGalleryHoverCard> createState() =>
      _WorkshopGalleryHoverCardState();
}

class _WorkshopGalleryHoverCardState extends State<_WorkshopGalleryHoverCard> {
  bool _isHovered = false;
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AnimatedContainer(
          duration: Duration(milliseconds: 160),
          decoration: BoxDecoration(
              color: AppPalette.bgCard,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: _isHovered
                      ? AppPalette.accentCyan.withValues(alpha: .5)
                      : AppPalette.borderSubtle)),
          clipBehavior: Clip.antiAlias,
          child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: widget.onTap,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                            child: Stack(fit: StackFit.expand, children: [
                          WorkshopPreview(
                              dataRootDir: widget.dataRootDir,
                              localPath: item.previewLocalPath,
                              remoteUrl: item.previewRemoteUrl),
                          if (item.status != ItemStatus.active)
                            Positioned(
                                top: 10,
                                left: 10,
                                child: Container(
                                    padding: EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                        color: AppPalette.bgCard,
                                        borderRadius: BorderRadius.circular(6)),
                                    child: Text(item.status.label,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: AppPalette.statusMissing)))),
                          if (_isHovered)
                            Positioned(
                                right: 8,
                                top: 8,
                                child: IconButton.filledTonal(
                                    tooltip: '复制作品 ID',
                                    onPressed: widget.onCopyId,
                                    icon: Icon(Icons.copy_rounded, size: 16))),
                        ])),
                        Padding(
                            padding: EdgeInsets.fromLTRB(14, 12, 14, 13),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppPalette.textPrimary)),
                                  SizedBox(height: 7),
                                  Text(item.contentRating.label,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: AppPalette.textSecondary)),
                                  SizedBox(height: 12),
                                  Row(children: [
                                    Icon(Icons.favorite_border_rounded,
                                        size: 13, color: AppPalette.textMuted),
                                    SizedBox(width: 4),
                                    Text('${item.favoritesCount}',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: AppPalette.textSecondary)),
                                    Spacer(),
                                    Text(item.formattedFileSize,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: AppPalette.textMuted))
                                  ]),
                                ])),
                      ]))),
        ));
  }
}
