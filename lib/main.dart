import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'backup_service.dart';
import 'diff_engine.dart';
import 'scheduler_tray_service.dart';
import 'steam_api_service.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await WorkshopDatabase.initialize();
  runApp(WorkshopMonitorApp(database: database));
}

class WorkshopMonitorApp extends StatelessWidget {
  final WorkshopDatabase database;

  const WorkshopMonitorApp({super.key, required this.database});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wallpaper Engine 创意工坊创作者监测与双端备份客户端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF38BDF8),
      ),
      home: MainDesktopShell(database: database),
    );
  }
}

class MainDesktopShell extends StatefulWidget {
  final WorkshopDatabase database;

  const MainDesktopShell({super.key, required this.database});

  @override
  State<MainDesktopShell> createState() => _MainDesktopShellState();
}

class _MainDesktopShellState extends State<MainDesktopShell> {
  static const _secureStorage = FlutterSecureStorage();
  static const _kSteamApiKeyStorageKey = 'we_monitor_steam_api_key';
  static const _kWebDavPasswordStorageKey = 'we_monitor_webdav_password';

  int _selectedNavIndex = 0;
  ItemStatus? _galleryStatusFilter;
  bool _onlyModifiedFilter = false;
  String? _selectedCreatorId;
  String _searchQuery = '';
  ChangeType? _logTypeFilter;

  String _syncProgressBanner = '';
  bool _isBusy = false;

  List<Creator> _creators = [];
  List<WorkshopItem> _items = [];
  List<ItemChangeLog> _logs = [];
  List<BackupRecord> _backupRecords = [];
  AppSettings _settings = const AppSettings();

  late final SteamWorkshopService _steamService;
  late final WorkshopDiffEngine _diffEngine;
  late final BackupService _backupService;
  late final SchedulerAndTrayService _schedulerTrayService;

  @override
  void initState() {
    super.initState();
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

  Future<void> _initializeSettingsAndData() async {
    try {
      final savedMap = await widget.database.loadConfigJson();
      String apiKey = '';
      String webdavPass = '';
      try {
        apiKey =
            await _secureStorage.read(key: _kSteamApiKeyStorageKey) ?? '';
        webdavPass =
            await _secureStorage.read(key: _kWebDavPasswordStorageKey) ?? '';
      } catch (_) {}

      if (savedMap != null) {
        _settings = AppSettings.fromNonSensitiveJson(
          savedMap,
          steamApiKey: apiKey,
          webdavPassword: webdavPass,
        );
      } else {
        _settings = _settings.copyWith(
          steamApiKey: apiKey,
          webdavPassword: webdavPass,
        );
      }
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
      await _secureStorage.write(
        key: _kWebDavPasswordStorageKey,
        value: updated.webdavPassword,
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
        onStatusUpdate: (msg) {
          if (mounted) {
            setState(() => _syncProgressBanner = msg);
          }
        },
      );

      // 若发现变更且启用了同步后自动增量备份，则触发本地镜像与 WebDAV 增量备份
      if (report.hasAnyChange && _settings.autoBackupAfterChange) {
        if (_settings.localBackupDir.trim().isNotEmpty) {
          setState(() => _syncProgressBanner = '正在执行本地目录增量镜像备份...');
          await _backupService.runLocalMirrorSync(
            targetMirrorDir: _settings.localBackupDir.trim(),
          );
        }
        if (_settings.webdavUrl.trim().isNotEmpty &&
            _settings.webdavUsername.trim().isNotEmpty &&
            _settings.webdavPassword.isNotEmpty) {
          await _backupService.runWebDavIncrementalSync(
            settings: _settings,
            onProgress: (msg) {
              if (mounted) setState(() => _syncProgressBanner = msg);
            },
          );
        }
      }

      await _refreshData();
      if (!mounted) return;
      final summary = report.isBaselineRun
          ? '首次全量基线建档完成：共归档 ${report.baselineCount} 件作品及预览图'
          : '增量同步完成：新增 ${report.addedCount} | 修改 ${report.modifiedCount} | 消失下架 ${report.missingCount} | 恢复 ${report.restoredCount}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(summary),
          backgroundColor:
              report.missingCount > 0 ? Colors.redAccent.shade700 : null,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('同步失败: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _syncProgressBanner = '';
        });
      }
    }
  }

  @override
  void dispose() {
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
          NavigationRail(
            extended: true,
            selectedIndex: _selectedNavIndex,
            onDestinationSelected: (idx) {
              setState(() => _selectedNavIndex = idx);
              _refreshData();
            },
            leading: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.radar, color: Colors.lightBlueAccent),
                      const SizedBox(width: 10),
                      Text(
                        'WE 创意工坊监测器',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '在线归档: $totalActive  |  已下架: $totalMissing',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: Text('创作者监测中心'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.grid_view_outlined),
                selectedIcon: Icon(Icons.grid_view_rounded),
                label: Text('作品图鉴与时光机'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.history_edu_outlined),
                selectedIcon: Icon(Icons.history_edu),
                label: Text('变更与下架时间轴'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.cloud_sync_outlined),
                selectedIcon: Icon(Icons.cloud_sync),
                label: Text('本地与 WebDAV 备份'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                if (_syncProgressBanner.isNotEmpty)
                  MaterialBanner(
                    content: Text(_syncProgressBanner),
                    leading: _isBusy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Icon(
                            Icons.notification_important,
                            color: Colors.amberAccent,
                          ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            setState(() => _syncProgressBanner = ''),
                        child: const Text('收起'),
                      ),
                    ],
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedNavIndex,
                    children: [
                      _buildCreatorsView(),
                      _buildGalleryView(),
                      _buildChangeLogView(),
                      _buildBackupSettingsView(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 视图 1：创作者监测中心
  // ==========================================================================
  Widget _buildCreatorsView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '创作者监测中心 (${_creators.length})',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '首次同步将全量记录创作者当前所有作品与预览图作为基线，后续同步在此之上识别新增、修改与下架消失。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _isBusy || _creators.isEmpty
                        ? null
                        : () =>
                            _schedulerTrayService.runScheduledSyncAllCreators(),
                    icon: const Icon(Icons.sync_alt),
                    label: const Text('全部增量轮询'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _isBusy ? null : _showAddCreatorDialog,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('添加创作者 (SteamID / 主页链接)'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _creators.isEmpty
                ? const Center(
                    child: Text(
                      '尚未添加任何创作者。\n点击右上角【添加创作者】输入 64 位 SteamID 或 Steam 个人主页链接即可建立基线档案。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    itemCount: _creators.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, idx) {
                      final creator = _creators[idx];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                child: Text(
                                  creator.personaName.characters.first
                                      .toUpperCase(),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          creator.personaName,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Chip(
                                          label: Text(
                                            creator.isBaselineCompleted
                                                ? '基线已锁定 (增量监测中)'
                                                : '待首次全量建档',
                                          ),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        if (creator.totalMissingCount > 0) ...[
                                          const SizedBox(width: 8),
                                          Chip(
                                            backgroundColor: Colors.redAccent
                                                .withValues(alpha: 0.25),
                                            label: Text(
                                              '已消失/下架: ${creator.totalMissingCount}',
                                              style: const TextStyle(
                                                color: Colors.redAccent,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'SteamID64: ${creator.steamId}  |  当前在线作品: ${creator.totalActiveCount}  |  最近同步: ${creator.lastSyncedAt?.toLocal().toString().substring(0, 19) ?? "尚未同步"}',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              TextButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _selectedCreatorId = creator.steamId;
                                    _selectedNavIndex = 1;
                                  });
                                  _refreshData();
                                },
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('查看作品图鉴'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                onPressed: _isBusy
                                    ? null
                                    : () => _triggerCreatorSync(creator),
                                icon: const Icon(Icons.sync),
                                label: Text(
                                  creator.isBaselineCompleted
                                      ? '执行增量比对'
                                      : '执行首次全量获取',
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: '移除创作者监测',
                                onPressed: _isBusy
                                    ? null
                                    : () async {
                                        await widget.database
                                            .deleteCreator(creator.steamId);
                                        await _refreshData();
                                      },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddCreatorDialog() async {
    final inputCtrl = TextEditingController();
    final aliasCtrl = TextEditingController();
    bool isResolving = false;
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加 Wallpaper Engine 创作者监测'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: inputCtrl,
                  decoration: InputDecoration(
                    labelText: '64 位 SteamID 或 Steam 个人主页链接',
                    hintText:
                        '例如：76561198xxxxxxxxx 或 https://steamcommunity.com/id/xxx',
                    errorText: errorText,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: aliasCtrl,
                  decoration: const InputDecoration(
                    labelText: '自定义备注名称（可选，留空则自动拉取 Steam 昵称）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isResolving ? null : () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed: isResolving
                  ? null
                  : () async {
                      final raw = inputCtrl.text.trim();
                      if (raw.isEmpty) return;
                      setDialogState(() {
                        isResolving = true;
                        errorText = null;
                      });
                      try {
                        final resolved =
                            await _steamService.resolveCreatorIdentity(
                          rawInput: raw,
                          apiKey: _settings.steamApiKey,
                        );
                        final displayName = aliasCtrl.text.trim().isNotEmpty
                            ? aliasCtrl.text.trim()
                            : resolved.personaName;

                        final creator = Creator(
                          steamId: resolved.steamId64,
                          personaName: displayName,
                          profileUrl:
                              'https://steamcommunity.com/profiles/${resolved.steamId64}/myworkshopfiles/?appid=$kWallpaperEngineAppId',
                          isBaselineCompleted: false,
                          totalActiveCount: 0,
                          totalMissingCount: 0,
                          createdAt: DateTime.now().toUtc(),
                        );
                        await widget.database.upsertCreator(creator);
                        await _refreshData();
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setDialogState(() {
                          isResolving = false;
                          errorText = e.toString();
                        });
                      }
                    },
              icon: isResolving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: const Text('解析并添加'),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // 视图 2：作品图鉴画廊与时光机历史版本对比
  // ==========================================================================
  Widget _buildGalleryView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索当前/历史旧标题、简介或作品 ID...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (val) {
                    _searchQuery = val;
                    _refreshData();
                  },
                ),
              ),
              DropdownButton<String?>(
                value: _selectedCreatorId,
                hint: const Text('全部创作者'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('全部创作者'),
                  ),
                  for (final c in _creators)
                    DropdownMenuItem<String?>(
                      value: c.steamId,
                      child: Text(c.personaName),
                    ),
                ],
                onChanged: (val) {
                  setState(() => _selectedCreatorId = val);
                  _refreshData();
                },
              ),
              ChoiceChip(
                label: const Text('全部状态'),
                selected: _galleryStatusFilter == null && !_onlyModifiedFilter,
                onSelected: (_) {
                  setState(() {
                    _galleryStatusFilter = null;
                    _onlyModifiedFilter = false;
                  });
                  _refreshData();
                },
              ),
              ChoiceChip(
                label: const Text('正常在线 (ACTIVE)'),
                selected: _galleryStatusFilter == ItemStatus.active,
                onSelected: (_) {
                  setState(() {
                    _galleryStatusFilter = ItemStatus.active;
                    _onlyModifiedFilter = false;
                  });
                  _refreshData();
                },
              ),
              ChoiceChip(
                label: const Text('曾发生修改 (MODIFIED)'),
                selected: _onlyModifiedFilter,
                onSelected: (v) {
                  setState(() {
                    _onlyModifiedFilter = v;
                    if (v) _galleryStatusFilter = null;
                  });
                  _refreshData();
                },
              ),
              ChoiceChip(
                label: const Text('已消失/下架 (MISSING)'),
                selected: _galleryStatusFilter == ItemStatus.missing,
                selectedColor: Colors.redAccent.withValues(alpha: 0.35),
                onSelected: (_) {
                  setState(() {
                    _galleryStatusFilter = ItemStatus.missing;
                    _onlyModifiedFilter = false;
                  });
                  _refreshData();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('当前筛选条件下暂无归档作品'))
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 290,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.80,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (context, idx) {
                      final item = _items[idx];
                      final absPreviewFile = item.previewLocalPath != null
                          ? File(
                              p.join(
                                widget.database.dataRootDir,
                                item.previewLocalPath!,
                              ),
                            )
                          : null;

                      return Card(
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: item.status == ItemStatus.missing
                              ? const BorderSide(
                                  color: Colors.redAccent,
                                  width: 1.5,
                                )
                              : BorderSide.none,
                        ),
                        child: InkWell(
                          onTap: () => _showItemTimeMachineDialog(item),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (absPreviewFile != null &&
                                        absPreviewFile.existsSync())
                                      Image.file(
                                        absPreviewFile,
                                        fit: BoxFit.cover,
                                      )
                                    else
                                      Container(
                                        color: Colors.blueGrey.shade900,
                                        child: const Icon(
                                          Icons.wallpaper,
                                          size: 48,
                                        ),
                                      ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: item.status.color.withValues(
                                            alpha: 0.9,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          item.status.label,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'ID: ${item.publishedFileId} • ${item.formattedFileSize}',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                    if (item.tags.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        item.tags.take(3).join(' / '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: Colors.lightBlueAccent,
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 作品详情与“时光机”并排对比弹窗（展示历代旧标题、旧简介与旧版封面图）
  Future<void> _showItemTimeMachineDialog(WorkshopItem item) async {
    final historyLogs = await widget.database.getChangeLogs(
      publishedFileId: item.publishedFileId,
    );
    if (!mounted) return;

    // 收集该作品历史上归档过的所有不同版本的封面图路径
    final historicalPreviewPaths = <String>{};
    if (item.previewLocalPath != null) {
      historicalPreviewPaths.add(item.previewLocalPath!);
    }
    for (final log in historyLogs) {
      final previewDiff = log.changedFields['preview_local_path'];
      if (previewDiff is Map) {
        if (previewDiff['old'] is String) {
          historicalPreviewPaths.add(previewDiff['old'] as String);
        }
        if (previewDiff['new'] is String) {
          historicalPreviewPaths.add(previewDiff['new'] as String);
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text('作品档案与时光机：《${item.title}》'),
            ),
            Chip(
              backgroundColor: item.status.color.withValues(alpha: 0.25),
              label: Text(item.status.label),
            ),
          ],
        ),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部：历代归档预览图画廊
                if (historicalPreviewPaths.isNotEmpty) ...[
                  Text(
                    '本地已归档封面预览图版本 (${historicalPreviewPaths.length} 个版本)：',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final relPath in historicalPreviewPaths)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Column(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      File(
                                        p.join(
                                          widget.database.dataRootDir,
                                          relPath,
                                        ),
                                      ),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const Icon(Icons.broken_image),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  relPath == item.previewLocalPath
                                      ? '当前最新封面'
                                      : '历史旧版封面',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 24),
                ],
                Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    Text('PublishedFileID: ${item.publishedFileId}'),
                    Text('创作者 SteamID: ${item.creatorSteamId}'),
                    Text('源文件大小: ${item.formattedFileSize}'),
                    Text('订阅数: ${item.subscriptionsCount}'),
                    Text('收藏数: ${item.favoritesCount}'),
                    Text('首次建档: ${item.firstSeenAt.toLocal()}'),
                    if (item.disappearedAt != null)
                      Text(
                        '确认消失/下架时间: ${item.disappearedAt!.toLocal()}',
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('标签: ${item.tags.join(", ")}'),
                const SizedBox(height: 8),
                Text('作品简介:\n${item.description.isEmpty ? "（无简介）" : item.description}'),
                const Divider(height: 24),
                const Text(
                  '时光机变更历史记录 (Change History Diff)：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (final log in historyLogs)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(log.changeType.icon,
                          color: log.changeType.color),
                      title: Text(
                        '${log.changeType.label} — ${log.detectedAt.toLocal().toString().substring(0, 19)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: SelectableText(
                        const JsonEncoder.withIndent('  ')
                            .convert(log.changedFields),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: item.publishedFileId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制作品 ID 到剪贴板')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制作品 ID'),
          ),
          TextButton.icon(
            onPressed: () {
              launchUrl(
                Uri.parse(
                  'https://steamcommunity.com/sharedfiles/filedetails/?id=${item.publishedFileId}',
                ),
              );
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('打开 Steam 创意工坊原页面'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // 视图 3：变更与下架告警时间轴
  // ==========================================================================
  Widget _buildChangeLogView() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '作品变更与下架告警时间轴 (${_logs.length})',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('全部事件'),
                    selected: _logTypeFilter == null,
                    onSelected: (_) {
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
                    ChoiceChip(
                      label: Text(t.label),
                      selected: _logTypeFilter == t,
                      onSelected: (_) {
                        setState(() => _logTypeFilter = t);
                        _refreshData();
                      },
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _logs.isEmpty
                ? const Center(child: Text('当前筛选条件下暂无变更日志'))
                : ListView.separated(
                    itemCount: _logs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, idx) {
                      final log = _logs[idx];
                      return ListTile(
                        leading: Icon(
                          log.changeType.icon,
                          color: log.changeType.color,
                        ),
                        title: Text(
                          '[${log.changeType.label}] 作品 ID: ${log.publishedFileId} (创作者: ${log.creatorSteamId})',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: log.changeType == ChangeType.missing
                                ? Colors.redAccent
                                : null,
                          ),
                        ),
                        subtitle: Text(jsonEncode(log.changedFields)),
                        trailing: Text(
                          log.detectedAt.toLocal().toString().substring(0, 19),
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
  // 视图 4：本地与 WebDAV 双通道备份及系统设置页
  // ==========================================================================
  Widget _buildBackupSettingsView() {
    final apiKeyCtrl = TextEditingController(text: _settings.steamApiKey);
    final localDirCtrl = TextEditingController(text: _settings.localBackupDir);
    final webdavUrlCtrl = TextEditingController(text: _settings.webdavUrl);
    final webdavUserCtrl =
        TextEditingController(text: _settings.webdavUsername);
    final webdavPassCtrl =
        TextEditingController(text: _settings.webdavPassword);
    final webdavRootCtrl =
        TextEditingController(text: _settings.webdavRemoteRoot);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '采集配置与双通道备份中心 (Local + WebDAV)',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          // 1. Steam 采集与后台轮询设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. Steam 创意工坊采集与后台定时监测设置',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: apiKeyCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText:
                          'Steam Web API Key（推荐填写；若留空则自动降级为网页 HTML 解析模式）',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) =>
                        _persistSettings(_settings.copyWith(steamApiKey: v)),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 24,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('后台自动轮询间隔：'),
                          const SizedBox(width: 8),
                          DropdownButton<int>(
                            value: _settings.pollIntervalHours,
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('仅手动同步')),
                              DropdownMenuItem(
                                  value: 2, child: Text('每 2 小时')),
                              DropdownMenuItem(
                                  value: 6, child: Text('每 6 小时')),
                              DropdownMenuItem(
                                  value: 12, child: Text('每 12 小时')),
                              DropdownMenuItem(
                                  value: 24, child: Text('每 24 小时')),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                _persistSettings(
                                  _settings.copyWith(pollIntervalHours: val),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                      FilterChip(
                        label: const Text('发现作品新增/修改/下架后自动触发增量备份'),
                        selected: _settings.autoBackupAfterChange,
                        onSelected: (v) => _persistSettings(
                          _settings.copyWith(autoBackupAfterChange: v),
                        ),
                      ),
                      FilterChip(
                        label: const Text('关闭窗口时最小化驻留系统托盘'),
                        selected: _settings.minimizeToTrayOnClose,
                        onSelected: (v) => _persistSettings(
                          _settings.copyWith(minimizeToTrayOnClose: v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 2. 本地归档与镜像备份
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '2. 本地双模式备份（SQLite 无锁热备快照 + 历代预览图 + 已消失作品 CSV 清单）',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: localDirCtrl,
                    decoration: const InputDecoration(
                      labelText: '本地备份目标文件夹路径',
                      hintText: '例如：D:\\Backups\\WallpaperEngineWorkshopMonitor',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _settings =
                        _settings.copyWith(localBackupDir: v.trim()),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                await _persistSettings(
                                  _settings.copyWith(
                                    localBackupDir: localDirCtrl.text.trim(),
                                  ),
                                );
                                final targetDir =
                                    _settings.localBackupDir.isEmpty
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
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content:
                                        Text('本地全量 ZIP 备份成功：${zipFile.path}'),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.folder_zip_outlined),
                        label: const Text('生成本地全量 ZIP 压缩包'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                await _persistSettings(
                                  _settings.copyWith(
                                    localBackupDir: localDirCtrl.text.trim(),
                                  ),
                                );
                                final targetDir =
                                    _settings.localBackupDir.isEmpty
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
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '本地增量镜像同步完成：共更新 $count 个文件至 $targetDir',
                                    ),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.drive_folder_upload_outlined),
                        label: const Text('执行本地增量镜像目录同步'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 3. WebDAV 远端备份与灾难恢复
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '3. WebDAV 云端备份与一键恢复（兼容坚果云 / Nextcloud / Alist / 群晖 NAS）',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: webdavUrlCtrl,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV 服务器地址 (Endpoint URL)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: webdavRootCtrl,
                          decoration: const InputDecoration(
                            labelText: '远端根目录路径',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: webdavUserCtrl,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV 用户名 / 邮箱',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: webdavPassCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV 应用专用密码 (加密存储于系统凭据库)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                final updated = _settings.copyWith(
                                  steamApiKey: apiKeyCtrl.text.trim(),
                                  localBackupDir: localDirCtrl.text.trim(),
                                  webdavUrl: webdavUrlCtrl.text.trim(),
                                  webdavUsername: webdavUserCtrl.text.trim(),
                                  webdavPassword: webdavPassCtrl.text,
                                  webdavRemoteRoot: webdavRootCtrl.text.trim(),
                                );
                                await _persistSettings(updated);
                                try {
                                  await _backupService
                                      .testWebDavConnection(updated);
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'WebDAV 连通性测试成功 (PROPFIND & MKCOL 权限正常)！',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('WebDAV 连接失败: $e'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('保存并测试 WebDAV 连通性'),
                      ),
                      FilledButton.icon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                final updated = _settings.copyWith(
                                  webdavUrl: webdavUrlCtrl.text.trim(),
                                  webdavUsername: webdavUserCtrl.text.trim(),
                                  webdavPassword: webdavPassCtrl.text,
                                  webdavRemoteRoot: webdavRootCtrl.text.trim(),
                                );
                                await _persistSettings(updated);
                                setState(() => _isBusy = true);
                                try {
                                  final count = await _backupService
                                      .runWebDavIncrementalSync(
                                    settings: updated,
                                    onProgress: (msg) {
                                      if (mounted) {
                                        setState(
                                            () => _syncProgressBanner = msg);
                                      }
                                    },
                                  );
                                  await _refreshData();
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'WebDAV 增量镜像同步完成：共上传/更新 $count 个文件',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('WebDAV 增量同步失败: $e'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isBusy = false;
                                      _syncProgressBanner = '';
                                    });
                                  }
                                }
                              },
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('WebDAV 增量镜像同步 (推荐)'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                final updated = _settings.copyWith(
                                  webdavUrl: webdavUrlCtrl.text.trim(),
                                  webdavUsername: webdavUserCtrl.text.trim(),
                                  webdavPassword: webdavPassCtrl.text,
                                  webdavRemoteRoot: webdavRootCtrl.text.trim(),
                                );
                                await _persistSettings(updated);
                                setState(() => _isBusy = true);
                                try {
                                  final remoteZip = await _backupService
                                      .runWebDavFullZipBackup(
                                    settings: updated,
                                    onProgress: (msg) {
                                      if (mounted) {
                                        setState(
                                            () => _syncProgressBanner = msg);
                                      }
                                    },
                                  );
                                  await _refreshData();
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'WebDAV 全量 ZIP 上传成功：$remoteZip',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('WebDAV 全量上传失败: $e'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isBusy = false;
                                      _syncProgressBanner = '';
                                    });
                                  }
                                }
                              },
                        icon: const Icon(Icons.archive_outlined),
                        label: const Text('上传全量 ZIP 至 WebDAV'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                final updated = _settings.copyWith(
                                  webdavUrl: webdavUrlCtrl.text.trim(),
                                  webdavUsername: webdavUserCtrl.text.trim(),
                                  webdavPassword: webdavPassCtrl.text,
                                  webdavRemoteRoot: webdavRootCtrl.text.trim(),
                                );
                                await _persistSettings(updated);
                                setState(() => _isBusy = true);
                                try {
                                  final restoredPreviews = await _backupService
                                      .restoreFromWebDav(
                                    settings: updated,
                                    onProgress: (msg) {
                                      if (mounted) {
                                        setState(
                                            () => _syncProgressBanner = msg);
                                      }
                                    },
                                  );
                                  await _refreshData();
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已从 WebDAV 完整恢复本地数据库与 $restoredPreviews 张缺失预览图！',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('WebDAV 恢复失败: $e'),
                                      backgroundColor: Colors.redAccent,
                                    ),
                                  );
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isBusy = false;
                                      _syncProgressBanner = '';
                                    });
                                  }
                                }
                              },
                        icon: const Icon(Icons.cloud_download_outlined),
                        label: const Text('从 WebDAV 一键恢复本地档案'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 4. 最近备份执行记录表
          if (_backupRecords.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '4. 最近备份与恢复执行记录',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final rec in _backupRecords.take(8))
                      ListTile(
                        dense: true,
                        leading: Icon(
                          rec.targetType == 'WEBDAV'
                              ? Icons.cloud_done_outlined
                              : Icons.snippet_folder_outlined,
                          color: Colors.tealAccent,
                        ),
                        title: Text(
                          '[${rec.targetType} • ${rec.backupMode}] ${rec.location}',
                        ),
                        trailing: Text(
                          rec.createdAt.toLocal().toString().substring(0, 19),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
