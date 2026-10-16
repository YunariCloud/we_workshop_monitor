import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'workspace_widgets.dart';
import 'workshop_models.dart';
import 'workshop_timeline.dart';

/// History has its own navigation and never inherits gallery display filters.
class WorkshopHistoryView extends StatefulWidget {
  final List<Creator> creators;
  final List<WorkshopItem> items;
  final List<ItemChangeLog> logs;
  final Widget Function(Creator) avatarBuilder;
  final void Function(ItemChangeLog, String) onShowDetails;
  const WorkshopHistoryView(
      {super.key,
      required this.creators,
      required this.items,
      required this.logs,
      required this.avatarBuilder,
      required this.onShowDetails});

  @override
  State<WorkshopHistoryView> createState() => _WorkshopHistoryViewState();
}

class _WorkshopHistoryViewState extends State<WorkshopHistoryView> {
  String? _creatorId;
  String? _itemId;
  String? _batchId;
  bool _showWorks = false;
  ChangeType? _type;

  TextStyle get _secondary =>
      TextStyle(fontSize: 12, height: 1.4, color: AppPalette.textSecondary);

  Map<String, String> _titles = {};
  String _title(String id) => _titles[id] ?? '未命名作品';

  Widget _back(String label, VoidCallback action) => Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
          onPressed: action,
          icon: const Icon(Icons.arrow_back_rounded, size: 18),
          label: Text(label)));

  @override
  Widget build(BuildContext context) {
    _titles = {
      for (final item in widget.items) item.publishedFileId: item.title
    };
    for (final log in widget.logs) {
      final saved =
          log.changedFields['title'] ?? log.changedFields['last_known_title'];
      final name = saved is String
          ? saved
          : saved is Map
              ? (saved['new'] ?? saved['old'])?.toString()
              : null;
      if (name != null) _titles.putIfAbsent(log.publishedFileId, () => name);
    }
    final creator = widget.creators
        .where((creator) => creator.steamId == _creatorId)
        .firstOrNull;
    if (creator == null) {
      return ListView(padding: const EdgeInsets.all(28), children: [
        Text('按创作者查看动态', style: _secondary),
        const SizedBox(height: 16),
        if (widget.creators.isEmpty)
          Padding(
              padding: const EdgeInsets.all(24),
              child: Text('添加创作者后，即可在这里查看更新记录。', style: _secondary)),
        for (final creator in widget.creators)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: WorkspaceSurface(
                  padding: EdgeInsets.zero,
                  onTap: () => setState(() {
                        _creatorId = creator.steamId;
                        _itemId = null;
                        _batchId = null;
                        _showWorks = false;
                        _type = null;
                      }),
                  child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 16),
                      leading: widget.avatarBuilder(creator),
                      title: Text(creator.personaName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                              '${widget.logs.where((log) => log.creatorSteamId == creator.steamId).length} 条变更记录',
                              style: _secondary)),
                      trailing:
                          const Icon(Icons.chevron_right_rounded, size: 20)))),
      ]);
    }

    final authorLogs = widget.logs
        .where((log) => log.creatorSteamId == _creatorId)
        .toList()
      ..sort((a, b) => b.detectedAt.compareTo(a.detectedAt));
    final filtered = authorLogs
        .where((log) => _type == null || log.changeType == _type)
        .toList();
    final itemLogs =
        filtered.where((log) => log.publishedFileId == _itemId).toList();
    final batches = <String, List<ItemChangeLog>>{};
    for (final log in filtered) {
      // The author is selected before grouping, so shared batch IDs cannot mix users.
      (batches[log.syncBatchId] ??= []).add(log);
    }
    final batchIds = batches.keys.toList()
      ..sort((a, b) =>
          batches[b]!.first.detectedAt.compareTo(batches[a]!.first.detectedAt));
    final workIds = {
      if (_batchId == null)
        ...widget.items
            .where((item) => item.creatorSteamId == _creatorId)
            .map((item) => item.publishedFileId),
      ...authorLogs
          .where((log) => _batchId == null || log.syncBatchId == _batchId)
          .map((log) => log.publishedFileId),
    }.toList()
      ..sort((a, b) => _title(a).compareTo(_title(b)));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _back(
                _itemId != null ? '返回作品列表' : '所有创作者',
                () => setState(() {
                      if (_itemId != null) {
                        _itemId = null;
                        _showWorks = true;
                        _type = null;
                      } else {
                        _creatorId = null;
                        _batchId = null;
                        _showWorks = false;
                        _type = null;
                      }
                    })),
            const SizedBox(height: 12),
            Row(children: [
              widget.avatarBuilder(creator),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(creator.personaName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(_itemId == null ? '创作者动态' : _title(_itemId!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _secondary),
                  ]))
            ]),
            const SizedBox(height: 20),
            if (_itemId == null)
              SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('汇总时间线')),
                    ButtonSegment(value: true, label: Text('作品时间线'))
                  ],
                  selected: {_showWorks},
                  onSelectionChanged: (values) => setState(() {
                        _showWorks = values.single;
                        _batchId = null;
                        _type = null;
                      })),
            if (!_showWorks || _itemId != null) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                ChoiceChip(
                    label: const Text('全部事件'),
                    selected: _type == null,
                    onSelected: (_) => setState(() => _type = null)),
                for (final type in ChangeType.values)
                  ChoiceChip(
                      label: Text(type.label),
                      selected: _type == type,
                      onSelected: (_) => setState(() => _type = type)),
              ]),
            ],
            if (_showWorks && _batchId != null && _itemId == null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('本次同步涉及的作品', style: _secondary)),
          ])),
      const SizedBox(height: 20),
      Expanded(
          child: _showWorks && _itemId == null
              ? ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  children: [
                      for (final id in workIds)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: WorkspaceSurface(
                                padding: EdgeInsets.zero,
                                onTap: () => setState(() {
                                      _itemId = id;
                                      _type = null;
                                    }),
                                child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 20, vertical: 8),
                                    title: Text(_title(id),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 14)),
                                    subtitle: Text(
                                        '${authorLogs.where((log) => log.publishedFileId == id).length} 条记录',
                                        style: _secondary),
                                    trailing: const Icon(
                                        Icons.chevron_right_rounded,
                                        size: 20)))),
                      if (workIds.isEmpty) _empty(),
                    ])
              : _itemId != null
                  ? ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      itemCount: itemLogs.isEmpty ? 1 : itemLogs.length,
                      itemBuilder: (_, index) => itemLogs.isEmpty
                          ? _empty()
                          : WorkshopTimelineEntry(
                              log: itemLogs[index],
                              title: _title(_itemId!),
                              isFirst: index == 0,
                              isLast: index == itemLogs.length - 1,
                              onTap: () => widget.onShowDetails(
                                  itemLogs[index], _title(_itemId!))))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      itemCount: batchIds.isEmpty ? 1 : batchIds.length,
                      itemBuilder: (_, index) {
                        if (batchIds.isEmpty) return _empty();
                        final id = batchIds[index];
                        final logs = batches[id]!;
                        const labels = {
                          ChangeType.baseline: '建档',
                          ChangeType.added: '新增',
                          ChangeType.modified: '修改',
                          ChangeType.missing: '下架',
                          ChangeType.restored: '恢复'
                        };
                        final summary = [
                          for (final type in ChangeType.values)
                            if (logs.any((log) => log.changeType == type))
                              '${labels[type]} ${logs.where((log) => log.changeType == type).length} 件'
                        ].join(' · ');
                        return WorkshopTimelineEntry(
                            log: logs.first,
                            eventLabel: '同步汇总',
                            eventIcon: Icons.sync_rounded,
                            title: summary,
                            isFirst: index == 0,
                            isLast: index == batchIds.length - 1,
                            onTap: () => setState(() {
                                  _batchId = id;
                                  _showWorks = true;
                                  _type = null;
                                }));
                      })),
    ]);
  }

  Widget _empty() => Padding(
      padding: const EdgeInsets.all(24),
      child: Text('暂无对应的变更记录', style: _secondary));
}
