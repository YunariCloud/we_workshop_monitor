import 'dart:io';

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

  int _selectedNavIndex = 0;
  ItemStatus? _galleryStatusFilter;
  bool _onlyModifiedFilter = false;
  String? _selectedCreatorId;
  String _searchQuery = '';
  final double _galleryCardMaxExtent = 340;
  ChangeType? _logTypeFilter;

  String _syncProgressBanner = '';
  bool _isBusy = false;
  bool _obscureApiKey = true;
  bool _testingApiKey = false;
  String? _apiTestResult;
  bool _apiTestFailed = false;

  List<Creator> _creators = [];
  List<WorkshopItem> _items = [];
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
      onBackgroundSyncEvent: (bannerMsg) async {
        if (!mounted) return;
        setState(() => _syncProgressBanner = bannerMsg);
        await _refreshData();
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
      try {
        apiKey = await _secureStorage.read(key: _kSteamApiKeyStorageKey) ?? '';
      } catch (_) {}

      if (savedMap != null) {
        _settings = AppSettings.fromNonSensitiveJson(
          savedMap,
          steamApiKey: apiKey,
        );
      } else {
        _settings = _settings.copyWith(
          steamApiKey: apiKey,
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
    await widget.database.saveConfigJson(updated.toNonSensitiveJson());
    try {
      await _secureStorage.write(
        key: _kSteamApiKeyStorageKey,
        value: updated.steamApiKey,
      );
    } catch (_) {}
    appThemeMode.value =
        updated.useDarkTheme ? ThemeMode.dark : ThemeMode.light;
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
    final logs = await widget.database.getChangeLogs(
      creatorSteamId: _selectedCreatorId,
      changeTypeFilter: _logTypeFilter,
    );
    final backups = await widget.database.getBackupRecords();

    if (!mounted) return;
    setState(() {
      _creators = creators;
      _items = items;
      _logs = logs;
      _backupRecords = backups;
    });
  }

  Future<void> _triggerCreatorSync(Creator creator) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _syncProgressBanner = '正在准备同步创作者【${creator.personaName}】...';
    });

    try {
      final report = await _diffEngine.syncCreator(
        creator: creator,
        apiKey: _settings.steamApiKey,
        queryMode: _settings.steamQueryMode,
        onStatusUpdate: (msg) {
          if (mounted) {
            setState(() => _syncProgressBanner = msg);
          }
        },
      );

      // Publish saved records before an optional backup can fail, and reveal
      // the newly built archive instead of leaving the user on stale filters.
      if (report.isBaselineRun && mounted) {
        setState(() {
          _selectedNavIndex = 1;
          _selectedCreatorId = creator.steamId;
          _galleryStatusFilter = null;
          _onlyModifiedFilter = false;
          _searchQuery = '';
          _searchCtrl.clear();
        });
      }
      await _refreshData();
      String? backupWarning;
      if (report.hasAnyChange &&
          _settings.autoBackupAfterChange &&
          _settings.localBackupDir.trim().isNotEmpty) {
        try {
          if (mounted) setState(() => _syncProgressBanner = '正在备份到本地目录…');
          await _backupService.runLocalMirrorSync(
              targetMirrorDir: _settings.localBackupDir.trim());
        } catch (_) {
          backupWarning = '作品已保存，但本地自动备份失败，请检查备份目录';
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
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _syncProgressBanner = '';
        });
      }
    }
  }

  void _showToast(
    String message, {
    bool isError = false,
    bool isWarning = false,
  }) {
    final bgColor = isError
        ? AppPalette.statusMissing
        : isWarning
            ? AppPalette.statusModified
            : AppPalette.bgCardHover;
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
              color: Colors.white,
              size: 20,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Colors.white,
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

    return Scaffold(
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
                if (_syncProgressBanner.isNotEmpty) _buildTopProgressStrip(),
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
  }

  void _selectWorkspace(int index) {
    setState(() => _selectedNavIndex = index);
    _refreshData();
  }

  Widget _buildCompactNavigation() => _buildNavigation(compact: true);
  Widget _buildCustomSidebar(
          {required int totalActive, required int totalMissing}) =>
      _buildNavigation();

  Widget _buildNavigation({bool compact = false}) {
    final labels = ['创作者', '作品资料库', '变更记录', '设置与备份'];
    final icons = [
      Icons.people_outline_rounded,
      Icons.photo_library_outlined,
      Icons.history_rounded,
      Icons.tune_rounded
    ];
    return Container(
      width: compact ? 72 : 218,
      decoration: BoxDecoration(
          color: AppPalette.bgSidebar,
          border: Border(right: BorderSide(color: AppPalette.borderSubtle))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: EdgeInsets.fromLTRB(compact ? 16 : 22, 28, 16, 30),
            child: Row(children: [
              Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: AppPalette.accentCyan,
                      borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.layers_outlined,
                      size: 21,
                      color:
                          AppPalette.dark ? Color(0xFF211A38) : Colors.white)),
              if (!compact) ...[
                SizedBox(width: 10),
                Text('工坊档案',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.textPrimary))
              ],
            ])),
        if (!compact)
          Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 0, 12),
              child: Text('工作空间',
                  style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.textMuted,
                      letterSpacing: 1))),
        for (var i = 0; i < labels.length; i++)
          Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12, vertical: 3),
              child: Tooltip(
                  message: compact ? labels[i] : '',
                  child: Material(
                    color: _selectedNavIndex == i
                        ? AppPalette.accentCyan.withValues(alpha: .10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _selectWorkspace(i),
                      child: Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: compact ? 14 : 12, vertical: 13),
                          child: Row(children: [
                            Icon(icons[i],
                                size: 20,
                                color: _selectedNavIndex == i
                                    ? AppPalette.accentCyan
                                    : AppPalette.textSecondary),
                            if (!compact) ...[
                              SizedBox(width: 12),
                              Expanded(
                                  child: Text(labels[i],
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: _selectedNavIndex == i
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: _selectedNavIndex == i
                                              ? AppPalette.accentCyan
                                              : AppPalette.textSecondary))),
                              if (i == 0)
                                Text('${_creators.length}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: AppPalette.textMuted))
                            ],
                          ])),
                    ),
                  ))),
        Spacer(),
        if (!compact)
          Padding(
              padding: EdgeInsets.all(20),
              child: Container(
                  padding: EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: AppPalette.bgCard.withValues(alpha: .6),
                      borderRadius: BorderRadius.circular(10)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.shield_outlined,
                              size: 16, color: AppPalette.statusActive),
                          SizedBox(width: 8),
                          Text('本地档案',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppPalette.textPrimary))
                        ]),
                        SizedBox(height: 8),
                        Text('作品信息与历史封面\n保存在你的电脑中',
                            style: TextStyle(
                                fontSize: 11,
                                height: 1.7,
                                color: AppPalette.textSecondary)),
                      ]))),
        Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 10 : 12, 0, compact ? 10 : 12, 20),
            child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  IconButton(
                      tooltip: AppPalette.dark ? '切换浅色主题' : '切换深色主题',
                      onPressed: () => _persistSettings(
                          _settings.copyWith(useDarkTheme: !AppPalette.dark)),
                      icon: Icon(
                          AppPalette.dark
                              ? Icons.light_mode_outlined
                              : Icons.dark_mode_outlined,
                          size: 19,
                          color: AppPalette.textSecondary)),
                  if (!compact)
                    Text(AppPalette.dark ? '深色外观' : '浅色外观',
                        style: TextStyle(
                            fontSize: 12, color: AppPalette.textSecondary)),
                ])),
      ]),
    );
  }

  Widget _buildWorkspaceToolbar() {
    final labels = ['创作者', '作品资料库', '变更记录', '设置与备份'];
    return Container(
        height: 66,
        padding: EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
            color: AppPalette.bgCard,
            border: Border(bottom: BorderSide(color: AppPalette.borderSubtle))),
        child: Row(children: [
          Icon(Icons.folder_open_rounded,
              size: 17, color: AppPalette.textMuted),
          SizedBox(width: 10),
          Text('工作空间',
              style: TextStyle(fontSize: 12, color: AppPalette.textMuted)),
          Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child:
                  Text('/', style: TextStyle(color: AppPalette.borderSubtle))),
          Text(labels[_selectedNavIndex],
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppPalette.textPrimary)),
          Spacer(),
          if (MediaQuery.sizeOf(context).width > 900) ...[
            Icon(Icons.circle,
                size: 6,
                color: _isBusy
                    ? AppPalette.statusModified
                    : AppPalette.statusActive),
            SizedBox(width: 7),
            Text(_isBusy ? '同步中' : '已就绪',
                style:
                    TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
            SizedBox(width: 22),
          ],
          IconButton(
              tooltip: '同步全部创作者',
              onPressed: _isBusy || _creators.isEmpty
                  ? null
                  : () => _schedulerTrayService.runScheduledSyncAllCreators(),
              icon: Icon(Icons.sync_rounded, size: 20)),
        ]));
  }

  Widget _buildTopProgressStrip() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppPalette.accentCyan.withValues(alpha: 0.18),
            AppPalette.accentIndigo.withValues(alpha: 0.18),
          ],
        ),
        border: Border(
          bottom: BorderSide(color: AppPalette.borderSubtle),
        ),
      ),
      child: Row(
        children: [
          if (_isBusy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AppPalette.accentCyan,
              ),
            )
          else
            Icon(
              Icons.notifications_active_outlined,
              size: 18,
              color: AppPalette.statusModified,
            ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              _syncProgressBanner,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppPalette.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _syncProgressBanner = ''),
            child: Text('隐藏', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 视图 1：创作者监测中心 (Bento KPI 仪表盘 + 创作者高密度状态卡片)
  // ==========================================================================
  Widget _buildCreatorsView(
      {required int totalActive, required int totalMissing}) {
    final ready = _creators.where((c) => c.isBaselineCompleted).length;
    final stats = [
      _buildBentoKpiCard(
          title: '监测创作者',
          value: '${_creators.length}',
          subtitle: '已建立档案 $ready 位',
          icon: Icons.people_alt_outlined,
          accent: AppPalette.accentCyan),
      _buildBentoKpiCard(
          title: '归档作品',
          value: '${totalActive + totalMissing}',
          subtitle: '作品信息与历史封面',
          icon: Icons.inventory_2_outlined,
          accent: AppPalette.accentIndigo),
      _buildBentoKpiCard(
          title: '可访问作品',
          value: '$totalActive',
          subtitle: '最近一次同步可访问',
          icon: Icons.cloud_done_outlined,
          accent: AppPalette.statusActive),
      _buildBentoKpiCard(
          title: '消失 / 下架',
          value: '$totalMissing',
          subtitle: '查看已保存的历史档案',
          icon: Icons.shield_outlined,
          accent: AppPalette.statusMissing,
          onTap: () {
            setState(() {
              _selectedNavIndex = 1;
              _galleryStatusFilter = ItemStatus.missing;
              _onlyModifiedFilter = false;
            });
            _refreshData();
          }),
    ];
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(24, 28, 24, 0),
          sliver: SliverToBoxAdapter(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                _AdaptiveHeader(
                  title: '关注的创作者',
                  subtitle: '在这里管理关注，记录作品的每一次变化。',
                  action: FilledButton.icon(
                    onPressed: _isBusy ? null : _showAddCreatorDialog,
                    icon: Icon(Icons.add, size: 19),
                    label: Text('添加创作者'),
                    style: FilledButton.styleFrom(
                        padding:
                            EdgeInsets.symmetric(horizontal: 20, vertical: 18)),
                  ),
                ),
                SizedBox(height: 24),
                LayoutBuilder(builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 920
                      ? 4
                      : constraints.maxWidth >= 460
                          ? 2
                          : 1;
                  return Wrap(spacing: 12, runSpacing: 12, children: [
                    for (final stat in stats)
                      SizedBox(
                          width: (constraints.maxWidth - 12 * (columns - 1)) /
                              columns,
                          child: stat),
                  ]);
                }),
                SizedBox(height: 28),
                Row(children: [
                  Text('正在关注',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(width: 10),
                  _buildStatusPill(
                      label: '${_creators.length} 位创作者',
                      color: AppPalette.textSecondary),
                ]),
                SizedBox(height: 14),
              ])),
        ),
        if (_creators.isEmpty)
          SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.all(24),
                child: _buildEmptyStateCard(
                    icon: Icons.person_add_alt,
                    title: '从一张喜欢的壁纸开始',
                    subtitle:
                        '粘贴 Wallpaper Engine 壁纸的创意工坊链接，即可识别作者。也支持 SteamID 和作者主页。',
                    actionLabel: '添加第一位创作者',
                    onAction: _showAddCreatorDialog),
              ))
        else
          SliverPadding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
              sliver: SliverList.separated(
                itemCount: _creators.length,
                separatorBuilder: (_, __) => SizedBox(height: 12),
                itemBuilder: (context, i) => _buildCreatorRowCard(_creators[i]),
              )),
      ],
    );
  }

  Widget _buildBentoKpiCard(
      {required String title,
      required String value,
      required String subtitle,
      required IconData icon,
      required Color accent,
      VoidCallback? onTap}) {
    return Material(
        color: AppPalette.bgCard,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
                padding: EdgeInsets.all(18),
                decoration: BoxDecoration(
                    border: Border.all(color: AppPalette.borderSubtle),
                    borderRadius: BorderRadius.circular(10)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(title,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: AppPalette.textSecondary))),
                        Icon(icon, size: 17, color: AppPalette.textMuted)
                      ]),
                      SizedBox(height: 10),
                      Text(value,
                          style: TextStyle(
                              fontSize: 28,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: AppPalette.textPrimary)),
                      SizedBox(height: 7),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: AppPalette.textMuted)),
                    ]))));
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
          FilledButton.tonalIcon(
            onPressed: _isBusy ? null : () => _triggerCreatorSync(creator),
            icon: Icon(Icons.sync, size: 17),
            label: Text(creator.isBaselineCompleted ? '同步' : '建立档案'),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) async {
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
      Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppPalette.accentCyan.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(12)),
          child: Text(
              creator.personaName.isEmpty
                  ? '?'
                  : creator.personaName.characters.first.toUpperCase(),
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.accentCyan))),
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
        SizedBox(height: 7),
        Text(creator.steamId,
            style: TextStyle(fontSize: 11, color: AppPalette.textMuted)),
      ])),
    ]);
    final metrics = Row(mainAxisSize: MainAxisSize.min, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${creator.totalActiveCount}',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppPalette.textPrimary)),
        SizedBox(height: 4),
        Text('已归档作品',
            style: TextStyle(fontSize: 10, color: AppPalette.textMuted)),
      ]),
      SizedBox(width: 28),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.circle,
              size: 6,
              color: creator.isBaselineCompleted
                  ? AppPalette.statusActive
                  : AppPalette.statusModified),
          SizedBox(width: 6),
          Text(creator.isBaselineCompleted ? '已建立档案' : '等待同步',
              style: TextStyle(fontSize: 11, color: AppPalette.textSecondary))
        ]),
        SizedBox(height: 5),
        Text(
            creator.lastSyncedAt == null
                ? '尚未同步'
                : creator.lastSyncedAt!.toLocal().toString().substring(0, 16),
            style: TextStyle(fontSize: 10, color: AppPalette.textMuted)),
      ]),
    ]);
    return Material(
        color: AppPalette.bgCard,
        borderRadius: BorderRadius.circular(10),
        child: Container(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
                border: Border.all(color: AppPalette.borderSubtle),
                borderRadius: BorderRadius.circular(10)),
            child: LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth < 1020) {
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
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ==========================================================================
  // 视图 2：作品图鉴画廊 (含悬停微动效卡片、多维状态筛选、卡片尺寸调节滑块)
  // ==========================================================================
  Widget _buildGalleryView(
      {required int totalActive, required int totalMissing}) {
    return Padding(
        padding: EdgeInsets.all(28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _AdaptiveHeader(
              title: '作品资料库',
              subtitle: '作品信息、历史封面，以及值得留存的每一次更新。',
              action: Text('${_items.length} 件作品',
                  style: TextStyle(
                      fontSize: 12, color: AppPalette.textSecondary))),
          SizedBox(height: 24),
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
                        SizedBox(
                            width: 180,
                            child: DropdownButtonFormField<String>(
                                initialValue: _selectedCreatorId ?? '',
                                isExpanded: true,
                                decoration: InputDecoration(
                                    prefixIcon: Icon(
                                        Icons.person_outline_rounded,
                                        size: 18)),
                                items: [
                                  DropdownMenuItem(
                                      value: '', child: Text('全部创作者')),
                                  for (final c in _creators)
                                    DropdownMenuItem(
                                        value: c.steamId,
                                        child: Text(c.personaName,
                                            overflow: TextOverflow.ellipsis))
                                ],
                                onChanged: (value) {
                                  setState(() => _selectedCreatorId =
                                      value == '' ? null : value);
                                  _refreshData();
                                })),
                        SizedBox(
                            width: 175,
                            child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue:
                                    _galleryStatusFilter?.name ?? 'all',
                                decoration: InputDecoration(
                                    prefixIcon: Icon(Icons.filter_list_rounded,
                                        size: 18)),
                                items: [
                                  DropdownMenuItem(
                                      value: 'all', child: Text('全部状态')),
                                  DropdownMenuItem(
                                      value: 'active', child: Text('正常在线')),
                                  DropdownMenuItem(
                                      value: 'missing', child: Text('消失 / 下架'))
                                ],
                                onChanged: (value) {
                                  setState(() {
                                    _galleryStatusFilter = value == 'all'
                                        ? null
                                        : ItemStatus.values
                                            .firstWhere((s) => s.name == value);
                                  });
                                  _refreshData();
                                })),
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
                      subtitle: '先同步一位创作者，或调整筛选条件。')
                  : GridView.builder(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: _galleryCardMaxExtent,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 18,
                          childAspectRatio: .96),
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

  Widget _buildFilterTabPill({
    required String label,
    required bool isSelected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color:
              isSelected ? accent.withValues(alpha: 0.2) : AppPalette.bgInput,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? accent : AppPalette.borderSubtle,
            width: isSelected ? 1.3 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? accent : AppPalette.textSecondary,
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // 作品时光机可视化对比弹窗 (Visual Diff & Multi-Cover Time Machine Modal)
  // ==========================================================================
  Future<void> _showItemTimeMachineDialog(WorkshopItem item) async {
    final historyLogs = await widget.database.getChangeLogs(
      publishedFileId: item.publishedFileId,
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
                            'PublishedFileID: ${item.publishedFileId}  ·  创作者 SteamID: ${item.creatorSteamId}  ·  大小: ${item.formattedFileSize}',
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
                                '本地归档预览图时光机 (${historicalPreviewPaths.length} 个历史封面版本)',
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
                                  Container(
                                    width: 240,
                                    margin: EdgeInsets.only(right: 14),
                                    decoration: BoxDecoration(
                                      color: AppPalette.bgCanvas,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: relPath == item.previewLocalPath
                                            ? AppPalette.accentCyan
                                            : AppPalette.borderSubtle,
                                      ),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Expanded(
                                          child: Image.file(
                                            File(
                                              p.join(
                                                widget.database.dataRootDir,
                                                relPath,
                                              ),
                                            ),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                Center(
                                              child: Icon(Icons.broken_image),
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          color: AppPalette.bgCard,
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                relPath == item.previewLocalPath
                                                    ? '当前封面'
                                                    : '历史旧版封面',
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: relPath ==
                                                          item.previewLocalPath
                                                      ? AppPalette.accentCyan
                                                      : AppPalette
                                                          .statusModified,
                                                ),
                                              ),
                                              Text(
                                                p.basename(relPath),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: AppPalette.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
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
                                            fontSize: 12.5,
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
                                          fontSize: 11.5,
                                          color: AppPalette.accentCyan,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              SizedBox(height: 12),
                              Text(
                                '作品简介 (Description)：',
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
                                  fontSize: 13,
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
                              '时光机变更历史记录 (Before / After 字段对比)',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 10),
                        for (final log in historyLogs)
                          _buildVisualDiffLogCard(log),
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
                    SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text('完成查看'),
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

  /// 将变更日志渲染为直观的“修改前 vs 修改后”视觉卡片
  Widget _buildVisualDiffLogCard(ItemChangeLog log) {
    final fields = log.changedFields;
    final diffRows = <Widget>[];

    fields.forEach((fieldKey, value) {
      if (value is Map &&
          (value.containsKey('old') || value.containsKey('new'))) {
        final oldVal = value['old']?.toString() ?? '（空）';
        final newVal = value['new']?.toString() ?? '（空）';
        diffRows.add(
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '字段变更：$fieldKey',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textSecondary,
                  ),
                ),
                SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color:
                              AppPalette.statusMissing.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                AppPalette.statusMissing.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          '修改前：$oldVal',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFFDA4AF),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Icon(
                        Icons.arrow_forward,
                        size: 15,
                        color: AppPalette.textMuted,
                      ),
                    ),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppPalette.statusActive.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color:
                                AppPalette.statusActive.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          '修改后：$newVal',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF6EE7B7),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      } else {
        diffRows.add(
          Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '$fieldKey: $value',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
        );
      }
    });

    return Container(
      margin: EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppPalette.bgCanvas,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(log.changeType.icon, size: 17, color: log.changeType.color),
              SizedBox(width: 8),
              _buildStatusPill(
                label: log.changeType.label,
                color: log.changeType.color,
              ),
              SizedBox(width: 10),
              Text(
                log.detectedAt.toLocal().toString().substring(0, 19),
                style: TextStyle(
                  fontSize: 12,
                  color: AppPalette.textSecondary,
                ),
              ),
              Spacer(),
              Text(
                '批次: ${log.syncBatchId}',
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.textMuted,
                ),
              ),
            ],
          ),
          ...diffRows,
        ],
      ),
    );
  }

  // ==========================================================================
  // 视图 3：变更与下架告警时间轴 (Git 风格垂直时间轴视图)
  // ==========================================================================
  Widget _buildChangeLogView() {
    return Padding(
      padding: EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AdaptiveHeader(
            title: '变更记录',
            subtitle: '追踪新作发布、作品修改与下架事件。',
            action: Wrap(
              spacing: 8,
              children: [
                _buildFilterTabPill(
                  label: '全部事件',
                  isSelected: _logTypeFilter == null,
                  accent: AppPalette.accentCyan,
                  onTap: () {
                    setState(() => _logTypeFilter = null);
                    _refreshData();
                  },
                ),
                for (final t in [
                  ChangeType.added,
                  ChangeType.modified,
                  ChangeType.missing,
                  ChangeType.restored,
                ])
                  _buildFilterTabPill(
                    label: t.label,
                    isSelected: _logTypeFilter == t,
                    accent: t.color,
                    onTap: () {
                      setState(() => _logTypeFilter = t);
                      _refreshData();
                    },
                  ),
              ],
            ),
          ),
          SizedBox(height: 20),
          Expanded(
            child: _logs.isEmpty
                ? _buildEmptyStateCard(
                    icon: Icons.history_edu_outlined,
                    title: '当前筛选条件下暂无变更记录',
                    subtitle: '当检测到创作者发布新作、修改作品信息或作品下架时，将自动在此处生成审计时间轴。',
                  )
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, idx) {
                      final log = _logs[idx];
                      return Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 左侧时间轴节点线
                            Column(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: log.changeType.color
                                        .withValues(alpha: 0.16),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: log.changeType.color,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Icon(
                                    log.changeType.icon,
                                    size: 16,
                                    color: log.changeType.color,
                                  ),
                                ),
                                if (idx < _logs.length - 1)
                                  Container(
                                    width: 2,
                                    height: 64,
                                    color: AppPalette.borderSubtle,
                                  ),
                              ],
                            ),
                            SizedBox(width: 16),
                            Expanded(
                              child: Card(
                                margin: EdgeInsets.only(bottom: 12),
                                child: Padding(
                                  padding: EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          _buildStatusPill(
                                            label: log.changeType.label,
                                            color: log.changeType.color,
                                          ),
                                          SizedBox(width: 10),
                                          Text(
                                            '作品 ID: ${log.publishedFileId}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13.5,
                                            ),
                                          ),
                                          SizedBox(width: 12),
                                          Text(
                                            '创作者: ${log.creatorSteamId}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppPalette.textSecondary,
                                            ),
                                          ),
                                          Spacer(),
                                          Text(
                                            log.detectedAt
                                                .toLocal()
                                                .toString()
                                                .substring(0, 19),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppPalette.textMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SizedBox(height: 6),
                                      _buildVisualDiffLogCard(log),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 视图 4：本地备份与同步设置
  // ==========================================================================
  Widget _buildBackupSettingsView() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '设置与备份',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: AppPalette.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            '选择同步方式，并为作品档案设置本地备份。',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          SizedBox(height: 22),
          // 第一行：左卡片（Steam 采集与后台守护） + 右卡片（本地双模式备份）
          LayoutBuilder(builder: (context, constraints) {
            if (constraints.maxWidth < 1000) {
              return Column(children: [
                _buildSteamAndScheduleCard(),
                SizedBox(height: 18),
                _buildLocalBackupCard()
              ]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _buildSteamAndScheduleCard()),
              SizedBox(width: 18),
              Expanded(child: _buildLocalBackupCard())
            ]);
          }),
          SizedBox(height: 18),
          // 第三行：备份执行历史记录审计表
          if (_backupRecords.isNotEmpty) _buildBackupHistoryTableCard(),
        ],
      ),
    );
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
      final items = await _steamService.fetchAllCreatorItems(
          steamId: creator.steamId,
          apiKey: key,
          queryMode: SteamQueryMode.webApi);
      if (!mounted) return;
      setState(() {
        _apiTestFailed = false;
        _apiTestResult =
            '连接成功 · ${creator.personaName} · ${items.length} 条可查询作品。请在创作者页点击同步，将作品保存到资料库。';
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
                  DropdownButtonFormField<SteamQueryMode>(
                      initialValue: _settings.steamQueryMode,
                      decoration: InputDecoration(labelText: '查询方式'),
                      isExpanded: true,
                      items: [
                        for (final mode in SteamQueryMode.values)
                          DropdownMenuItem(value: mode, child: Text(mode.label))
                      ],
                      onChanged: _isBusy || _testingApiKey
                          ? null
                          : (mode) {
                              if (mode != null) {
                                _persistSettings(_settings.copyWith(
                                    steamQueryMode: mode,
                                    steamApiKey: _apiKeyCtrl.text.trim()));
                              }
                            }),
                  SizedBox(height: 10),
                  Text(descriptions[_settings.steamQueryMode]!,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.7,
                          color: AppPalette.textSecondary)),
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
                  DropdownButtonFormField<int>(
                      initialValue: _settings.pollIntervalHours,
                      decoration: InputDecoration(labelText: '检查间隔'),
                      items: [
                        for (final hours in [0, 2, 6, 12, 24])
                          DropdownMenuItem(
                              value: hours,
                              child: Text(hours == 0 ? '仅手动同步' : '每 $hours 小时'))
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _persistSettings(
                              _settings.copyWith(pollIntervalHours: value));
                        }
                      }),
                  SizedBox(height: 12),
                  SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('变更后自动备份', style: TextStyle(fontSize: 13)),
                      subtitle: Text('需要先配置本地备份目录',
                          style: TextStyle(
                              fontSize: 11, color: AppPalette.textMuted)),
                      value: _settings.autoBackupAfterChange,
                      onChanged: (value) => _persistSettings(
                          _settings.copyWith(autoBackupAfterChange: value))),
                  SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title:
                          Text('关闭窗口时保留后台运行', style: TextStyle(fontSize: 13)),
                      value: _settings.minimizeToTrayOnClose,
                      onChanged: (value) => _persistSettings(
                          _settings.copyWith(minimizeToTrayOnClose: value))),
                ])));
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
            SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isBusy
                        ? null
                        : () async {
                            await _persistSettings(
                              _settings.copyWith(
                                localBackupDir: _localDirCtrl.text.trim(),
                              ),
                            );
                            final targetDir = _settings.localBackupDir.isEmpty
                                ? p.join(
                                    widget.database.dataRootDir,
                                    'local_backups',
                                  )
                                : _settings.localBackupDir;
                            final zipFile =
                                await _backupService.runLocalZipBackup(
                              targetBackupDir: targetDir,
                              maxKeepCount: _settings.maxLocalZipKeep,
                            );
                            await _refreshData();
                            if (!mounted) return;
                            _showToast('本地全量 ZIP 备份已生成：${zipFile.path}');
                          },
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
                    onPressed: _isBusy
                        ? null
                        : () async {
                            await _persistSettings(
                              _settings.copyWith(
                                localBackupDir: _localDirCtrl.text.trim(),
                              ),
                            );
                            final targetDir = _settings.localBackupDir.isEmpty
                                ? p.join(
                                    widget.database.dataRootDir,
                                    'local_mirror',
                                  )
                                : _settings.localBackupDir;
                            final count =
                                await _backupService.runLocalMirrorSync(
                              targetMirrorDir: targetDir,
                            );
                            await _refreshData();
                            if (!mounted) return;
                            _showToast(
                              '本地增量镜像同步完成：更新 $count 个文件至 $targetDir',
                            );
                          },
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
                          fontSize: 12.5,
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
                fontSize: 12.5,
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
                await widget.database.upsertCreator(Creator(
                  steamId: resolved.steamId64,
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

class _AdaptiveHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget action;
  const _AdaptiveHeader(
      {required this.title, required this.subtitle, required this.action});
  @override
  Widget build(BuildContext context) {
    final heading =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: AppPalette.textPrimary)),
      SizedBox(height: 8),
      Text(subtitle,
          style: TextStyle(
              fontSize: 13, height: 1.5, color: AppPalette.textSecondary)),
    ]);
    return LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 760
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, SizedBox(height: 16), action])
            : Row(children: [
                Expanded(child: heading),
                SizedBox(width: 24),
                action
              ]));
  }
}

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
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _isHovered
                      ? AppPalette.accentCyan.withValues(alpha: .5)
                      : AppPalette.borderSubtle)),
          clipBehavior: Clip.antiAlias,
          child: Material(
              color: Colors.transparent,
              child: InkWell(
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
                                            fontSize: 10,
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
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppPalette.textPrimary)),
                                  SizedBox(height: 7),
                                  Text('作品 ${item.publishedFileId}',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppPalette.textMuted)),
                                  SizedBox(height: 12),
                                  Row(children: [
                                    Icon(Icons.favorite_border_rounded,
                                        size: 13, color: AppPalette.textMuted),
                                    SizedBox(width: 4),
                                    Text('${item.favoritesCount}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppPalette.textSecondary)),
                                    Spacer(),
                                    Text(item.formattedFileSize,
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: AppPalette.textMuted))
                                  ]),
                                ])),
                      ]))),
        ));
  }
}
