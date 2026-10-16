import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// A missing or corrupt local cover must not leave an otherwise valid archive
/// invisible. Network previews are a display fallback; sync repairs the cache.
class WorkshopPreview extends StatelessWidget {
  final String dataRootDir;
  final String? localPath;
  final String remoteUrl;

  const WorkshopPreview(
      {super.key,
      required this.dataRootDir,
      required this.localPath,
      required this.remoteUrl});

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
            child: Icon(Icons.wallpaper_outlined,
                size: 36,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: .5))));
    Widget remote() {
      final uri = Uri.tryParse(remoteUrl);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        return placeholder();
      }
      return Image.network(remoteUrl,
          fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder());
    }

    final file = localPath == null || localPath!.isEmpty
        ? null
        : File(p.join(dataRootDir, localPath!));
    if (file == null || !file.existsSync()) return remote();
    return Image.file(file,
        fit: BoxFit.cover, errorBuilder: (_, __, ___) => remote());
  }
}
