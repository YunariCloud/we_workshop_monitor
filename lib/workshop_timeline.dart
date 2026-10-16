import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'workspace_widgets.dart';
import 'workshop_models.dart';

/// Each rail stretches to the next row, including the space below its card.
class WorkshopTimelineEntry extends StatelessWidget {
  final ItemChangeLog log;
  final String title;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;
  final String? eventLabel;
  final IconData? eventIcon;
  const WorkshopTimelineEntry(
      {super.key,
      required this.log,
      required this.title,
      required this.isFirst,
      required this.isLast,
      this.eventLabel,
      this.eventIcon,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
          width: 32,
          child: Stack(children: [
            if (!isFirst)
              Positioned(
                  top: 0,
                  left: 15,
                  width: 2,
                  height: 32,
                  child: ColoredBox(
                      key: const ValueKey('timeline-before'),
                      color: AppPalette.borderSubtle)),
            if (!isLast)
              Positioned(
                  top: 32,
                  bottom: 0,
                  left: 15,
                  width: 2,
                  child: ColoredBox(
                      key: const ValueKey('timeline-after'),
                      color: AppPalette.borderSubtle)),
            Positioned(
                top: 16,
                left: 0,
                child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        shape: BoxShape.circle),
                    child: Icon(eventIcon ?? log.changeType.icon,
                        size: 17, color: scheme.onSecondaryContainer))),
          ])),
      const SizedBox(width: 16),
      Expanded(
          child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: WorkspaceSurface(
                  onTap: onTap,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(eventLabel ?? log.changeType.label,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppPalette.textSecondary)),
                          const Spacer(),
                          Text(
                              log.detectedAt
                                  .toLocal()
                                  .toString()
                                  .substring(0, 16),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppPalette.textSecondary))
                        ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                              child: Text(title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500))),
                          const SizedBox(width: 12),
                          Icon(Icons.chevron_right_rounded,
                              size: 18, color: AppPalette.textSecondary)
                        ]),
                      ])))),
    ]));
  }
}
