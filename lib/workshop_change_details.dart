import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'workshop_models.dart';

/// Only user-facing metadata belongs in the change viewer. Cache paths, hashes,
/// image URLs, API names and internal IDs stay in storage.
class WorkshopChangeDetails extends StatelessWidget {
  final ItemChangeLog log;
  const WorkshopChangeDetails({super.key, required this.log});

  static const _labels = {
    'title': '标题',
    'last_known_title': '作品名称',
    'description': '简介',
    'tags': '标签',
    'file_size_bytes': '文件大小',
    'status': '作品状态'
  };

  String _format(String key, Object? value) {
    if (value == null || value == '') return '未填写';
    if (value is List) return value.join(' · ');
    if (key == 'status') return ItemStatus.fromCode(value.toString()).label;
    if (key == 'file_size_bytes' && value is num) {
      var size = value.toDouble();
      var unit = 0;
      const units = ['B', 'KB', 'MB', 'GB'];
      while (size >= 1024 && unit < units.length - 1) {
        size /= 1024;
        unit++;
      }
      return '${size.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 16, runSpacing: 8, children: [
          Text(log.changeType.label,
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
          Text(log.detectedAt.toLocal().toString().substring(0, 16),
              style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
        ]),
        for (final entry in log.changedFields.entries
            .where((entry) => _labels.containsKey(entry.key)))
          Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_labels[entry.key]!,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    if (entry.value is Map &&
                        ((entry.value as Map).containsKey('old') ||
                            (entry.value as Map).containsKey('new')))
                      LayoutBuilder(builder: (_, constraints) {
                        final before = _value('修改前',
                            _format(entry.key, (entry.value as Map)['old']));
                        final after = _value('修改后',
                            _format(entry.key, (entry.value as Map)['new']));
                        return constraints.maxWidth >= 480
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    Expanded(child: before),
                                    const SizedBox(width: 12),
                                    Expanded(child: after)
                                  ])
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                    before,
                                    const SizedBox(height: 12),
                                    after
                                  ]);
                      })
                    else
                      SelectableText(_format(entry.key, entry.value),
                          style: const TextStyle(fontSize: 14, height: 1.5)),
                  ])),
        if (log.changedFields.keys.any((key) => key.startsWith('preview_')))
          Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                  log.changeType == ChangeType.modified ? '封面已更新' : '已保存封面',
                  style: TextStyle(
                      fontSize: 14, color: AppPalette.textSecondary))),
      ]);

  Widget _value(String label, String value) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppPalette.bgInput, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: AppPalette.textSecondary)),
        const SizedBox(height: 8),
        SelectableText(value,
            style: const TextStyle(fontSize: 14, height: 1.5)),
      ]));
}
