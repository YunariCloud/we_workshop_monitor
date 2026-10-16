import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Convert a private staging copy only. The live archive and its original media
/// are never rewritten, and every referenced historical cover is retained.
Future<Map<String, Object>> prepareLightweightArchive({
  required String dataRoot,
  required String stagingRoot,
  required Set<String> previewPaths,
}) async {
  final result = await Isolate.run(() async {
    final replacements = <String, Map<String, String>>{};
    var originalBytes = 0;
    var outputBytes = 0;
    var converted = 0;
    var preserved = 0;
    var missing = 0;
    final previewRoot = p.normalize(p.absolute(dataRoot, 'previews'));
    for (final relative in previewPaths) {
      if (p.isAbsolute(relative)) {
        missing++;
        continue;
      }
      final sourcePath = p.normalize(p.absolute(dataRoot, relative));
      if (!p.isWithin(previewRoot, sourcePath)) {
        missing++;
        continue;
      }
      final source = File(sourcePath);
      if (!await source.exists()) {
        missing++;
        continue;
      }
      final bytes = await source.readAsBytes();
      originalBytes += bytes.length;
      try {
        final decoder = img.findDecoderForData(bytes);
        final decoded = decoder?.decode(bytes, frame: 0);
        final isGif = decoder is img.GifDecoder;
        if (decoded == null) throw const FormatException('Unsupported preview');
        var frame = img.bakeOrientation(decoded);
        if (frame.width > 1280 || frame.height > 1280) {
          frame = img.copyResize(frame,
              width: frame.width >= frame.height ? 1280 : null,
              height: frame.height > frame.width ? 1280 : null,
              interpolation: img.Interpolation.average);
        }
        final canvas =
            img.Image(width: frame.width, height: frame.height, numChannels: 3)
              ..clear(img.ColorRgb8(255, 255, 255));
        img.compositeImage(canvas, frame);
        var output =
            img.encodeJpg(canvas, quality: 80, chroma: img.JpegChroma.yuv420);
        var extension = 'jpg';
        if (isGif) {
          final png = img.encodePng(frame, singleFrame: true);
          if (png.length < output.length) {
            output = png;
            extension = 'png';
          }
        }
        // Tiny already-compressed stills need not become larger in light mode.
        if (output.length >= bytes.length &&
            !isGif &&
            decoded.width <= 1280 &&
            decoded.height <= 1280) {
          throw const FormatException('Original still is smaller');
        }
        final name =
            sha256.convert(utf8.encode(relative)).toString().substring(0, 20);
        final targetRelative = p.join('previews',
            p.basename(p.dirname(relative)), '${name}_light.$extension');
        final target = File(p.join(stagingRoot, targetRelative));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(output, flush: true);
        replacements[relative] = {
          'path': targetRelative,
          'sha256': sha256.convert(output).toString()
        };
        converted++;
        outputBytes += output.length;
      } catch (_) {
        // Preserve undecodable media instead of silently dropping a cover.
        final target = File(p.join(stagingRoot, relative));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes, flush: true);
        preserved++;
        outputBytes += bytes.length;
      }
    }
    return (
      replacements: replacements,
      originalBytes: originalBytes,
      outputBytes: outputBytes,
      converted: converted,
      preserved: preserved,
      missing: missing
    );
  });

  final snapshot = await databaseFactoryFfi
      .openDatabase(p.join(stagingRoot, 'workshop_monitor_snapshot.db'));
  List<Map<String, Object?>> items;
  try {
    await snapshot.rawQuery('PRAGMA journal_mode=DELETE');
    await snapshot.transaction((txn) async {
      for (final item in await txn.query('workshop_items')) {
        final replacement = result.replacements[item['preview_local_path']];
        if (replacement != null) {
          await txn.update(
              'workshop_items',
              {
                'preview_local_path': replacement['path'],
                'preview_sha256': replacement['sha256'],
              },
              where: 'published_file_id = ?',
              whereArgs: [item['published_file_id']]);
        }
      }
      for (final log in await txn.query('item_change_logs')) {
        final raw = log['changed_fields_json'] as String?;
        final fields = (raw == null || raw.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(raw)) as Map<String, dynamic>;
        final preview = fields['preview_local_path'];
        if (preview is String && result.replacements.containsKey(preview)) {
          fields['preview_local_path'] = result.replacements[preview]!['path'];
        } else if (preview is Map) {
          fields['preview_local_path'] = {
            for (final entry in preview.entries)
              entry.key:
                  result.replacements[entry.value]?['path'] ?? entry.value
          };
        } else {
          continue;
        }
        await txn.update(
            'item_change_logs', {'changed_fields_json': jsonEncode(fields)},
            where: 'log_id = ?', whereArgs: [log['log_id']]);
      }
    });
    items = await snapshot.query('workshop_items');
  } finally {
    await snapshot.close();
  }
  await File(p.join(stagingRoot, 'exports', 'items_all.json'))
      .writeAsString(const JsonEncoder.withIndent('  ').convert(items));
  String csv(Object? value) =>
      '"${(value ?? '').toString().replaceAll('"', '""')}"';
  final report = StringBuffer(
      'published_file_id,creator_steam_id,title,tags,first_seen_at,disappeared_at,preview_local_path\n');
  for (final item in items.where((item) => item['status'] == 'MISSING')) {
    report.writeln([
      item['published_file_id'],
      item['creator_steam_id'],
      item['title'],
      (jsonDecode(item['tags_json'] as String) as List).join(';'),
      item['first_seen_at'],
      item['disappeared_at'],
      item['preview_local_path']
    ].map(csv).join(','));
  }
  await File(p.join(stagingRoot, 'exports', 'items_missing_alert.csv'))
      .writeAsString(report.toString());
  return {
    'mode': 'lightweight',
    'max_image_dimension': 1280,
    'jpeg_quality': 80,
    'animation': 'first_frame',
    'converted_previews': result.converted,
    'preserved_previews': result.preserved,
    'missing_previews': result.missing,
    'original_preview_bytes': result.originalBytes,
    'archived_preview_bytes': result.outputBytes
  };
}
