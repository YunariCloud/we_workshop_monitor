import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Shared, low-contrast surfaces for the desktop workspace.
class WorkspaceSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool tonal;
  final VoidCallback? onTap;
  const WorkspaceSurface(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(24),
      this.tonal = false,
      this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: tonal
            ? Theme.of(context).colorScheme.secondaryContainer
            : AppPalette.bgCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
                color: AppPalette.borderSubtle.withValues(alpha: .65))),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(24),
                child: Padding(padding: padding, child: child)),
      );
}

class WorkspaceSettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  const WorkspaceSettingTile(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle,
      this.onTap,
      this.trailing});

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        leading: Icon(icon, color: AppPalette.textSecondary),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(subtitle,
                style:
                    TextStyle(fontSize: 12, color: AppPalette.textSecondary))),
        trailing: trailing ?? const Icon(Icons.chevron_right_rounded, size: 20),
        onTap: onTap,
      );
}
