import 'dart:io';
import 'package:path/path.dart' as p;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:we_workshop_monitor/main.dart';
import 'package:we_workshop_monitor/app_theme.dart';
import 'package:we_workshop_monitor/workshop_database.dart';
import 'package:we_workshop_monitor/workshop_models.dart';

class PreviewDatabase implements WorkshopDatabase {
  final bool dark;
  PreviewDatabase({this.dark = false});
  @override
  Future<void> saveConfigJson(Map<String, dynamic> config) async {}
  @override
  String get dataRootDir => '.';
  @override
  Future<Map<String, dynamic>?> loadConfigJson() async =>
      AppSettings(pollIntervalHours: 0, useDarkTheme: dark)
          .toNonSensitiveJson();
  @override
  Future<List<Creator>> getAllCreators() async => [
        Creator(
            steamId: '76561199182487944',
            personaName: '云烟',
            profileUrl:
                'https://steamcommunity.com/profiles/76561199182487944/',
            isBaselineCompleted: true,
            totalActiveCount: 456,
            totalMissingCount: 0,
            lastSyncedAt: DateTime(2026, 10, 16, 10, 30),
            createdAt: DateTime(2026)),
        Creator(
            steamId: '76561198000000000',
            personaName: 'Moonlight Studio · 长名称创作者作品集',
            profileUrl: '',
            isBaselineCompleted: false,
            totalActiveCount: 0,
            totalMissingCount: 0,
            createdAt: DateTime(2026)),
      ];
  @override
  Future<List<WorkshopItem>> queryItems(
          {String? creatorSteamId,
          ItemStatus? statusFilter,
          String? tagFilter,
          String searchQuery = '',
          bool onlyModified = false}) async =>
      List.generate(
          6,
          (i) => WorkshopItem(
              publishedFileId: '${3200000000 + i}',
              creatorSteamId: '76561199182487944',
              title: [
                '山间回声 · Mountain Echoes',
                '浮光之城',
                'Rainy Night',
                '森与海',
                'Orbital',
                '夏日留白'
              ][i],
              description: '界面预览数据',
              tags: [
                'Scene',
                i == 4
                    ? 'Mature'
                    : i == 5
                        ? 'Questionable'
                        : 'Everyone'
              ],
              fileSizeBytes: 24800000 + i * 12000000,
              previewRemoteUrl: '',
              previewLocalPath: '.dart_tool/ui-preview/art-$i.png',
              timeCreated: 0,
              timeUpdated: 0,
              subscriptionsCount: 1200 + i * 225,
              favoritesCount: 80 + i * 62,
              status: i == 4 ? ItemStatus.missing : ItemStatus.active,
              contentHash: '',
              firstSeenAt: DateTime(2026),
              lastSeenAt: DateTime(2026)));
  @override
  Future<List<ItemChangeLog>> getChangeLogs(
          {String? publishedFileId,
          String? creatorSteamId,
          ChangeType? changeTypeFilter,
          int limit = 300}) async =>
      [
        ItemChangeLog(
            publishedFileId: '3200000000',
            creatorSteamId: '76561199182487944',
            syncBatchId: 'test-batch',
            changeType: ChangeType.modified,
            changedFields: {
              'title': {'old': '旧作品名', 'new': '山间回声 · Mountain Echoes'},
              'description': {'old': '旧的简介', 'new': '新的简介，仅在详情显示'},
              'preview_local_path': {
                'old': 'previews/private-old.png',
                'new': 'previews/private-new.png'
              },
              'preview_url': 'https://example.com/private-image.png',
              'verified_by': 'internal API'
            },
            detectedAt: DateTime(2026, 10, 16, 12)),
        ItemChangeLog(
            publishedFileId: '3200000001',
            creatorSteamId: '76561199182487944',
            syncBatchId: 'test-batch',
            changeType: ChangeType.added,
            changedFields: {'title': '浮光之城'},
            detectedAt: DateTime(2026, 10, 16, 11)),
        ItemChangeLog(
            publishedFileId: '3300000000',
            creatorSteamId: '76561198000000000',
            syncBatchId: 'test-batch',
            changeType: ChangeType.added,
            changedFields: {'title': '另一位作者的作品'},
            detectedAt: DateTime(2026, 10, 16, 13)),
        ItemChangeLog(
            publishedFileId: '3200000004',
            creatorSteamId: '76561199182487944',
            syncBatchId: 'test-batch',
            changeType: ChangeType.missing,
            changedFields: {'last_known_title': 'Orbital'},
            detectedAt: DateTime(2026, 10, 16, 10)),
      ]
          .where((log) =>
              (publishedFileId == null ||
                  log.publishedFileId == publishedFileId) &&
              (changeTypeFilter == null || log.changeType == changeTypeFilter))
          .toList();
  @override
  Future<List<BackupRecord>> getBackupRecords({int limit = 50}) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> saveHistoryPreview(
        WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('.dart_tool/ui-preview/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }).then((_) {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (_) async =>
                throw PlatformException(code: 'test_no_native_window'));
  });
  setUpAll(() async {
    if (const bool.fromEnvironment('SAVE_UI_PREVIEW')) {
      final sdk = (Platform.environment['PATH'] ?? '')
          .split(';')
          .where((entry) => File(p.join(entry, 'flutter.bat')).existsSync())
          .first;
      final roboto = File(p.join(
          sdk, 'cache', 'artifacts', 'material_fonts', 'roboto-regular.ttf'));
      final latinLoader = FontLoader('Roboto')
        ..addFont(roboto.readAsBytes().then((b) => ByteData.sublistView(b)));
      await latinLoader.load();
      final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('Microsoft YaHei UI')
          ..addFont(
              font.readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      await Directory('.dart_tool/ui-preview').create(recursive: true);
      for (var i = 0; i < 6; i++) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final palettes = [
          [0xFFBFD4DE, 0xFF526F8A],
          [0xFFD4BDCC, 0xFF655A82],
          [0xFF617F9D, 0xFF1D2E51],
          [0xFFA8C5AC, 0xFF3F6C5A],
          [0xFF665A93, 0xFF29203F],
          [0xFFEAD7B5, 0xFFA78672]
        ];
        canvas.drawRect(
            Rect.fromLTWH(0, 0, 640, 360),
            Paint()
              ..shader = ui.Gradient.linear(Offset.zero, Offset(640, 360),
                  palettes[i].map((c) => Color(c)).toList()));
        canvas.drawCircle(Offset(465, 110), 58,
            Paint()..color = Colors.white.withValues(alpha: .22));
        for (var layer = 0; layer < 4; layer++) {
          final path = Path()
            ..moveTo(0, 360)
            ..lineTo(0, 210 + layer * 28.0)
            ..cubicTo(180, 110 + layer * 33.0, 280, 360 - layer * 7.0, 640,
                170 + layer * 45.0)
            ..lineTo(640, 360)
            ..close();
          canvas.drawPath(
              path,
              Paint()
                ..color = Color(palettes[i].last)
                    .withValues(alpha: .2 + layer * .15));
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(640, 360);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('.dart_tool/ui-preview/art-$i.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      }
    }
  });
  for (final dark in [false, true]) {
    for (final size in [
      const Size(1440, 900),
      const Size(900, 700),
      const Size(960, 680),
      const Size(720, 620)
    ]) {
      testWidgets(
          'desktop pages ${dark ? 'dark' : 'light'} fit ${size.width} x ${size.height}',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appThemeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
        final preview = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: preview,
            child: WorkshopMonitorApp(database: PreviewDatabase(dark: dark))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size.width < 760) {
          await tester.scrollUntilVisible(find.text('云烟'), 180,
              scrollable: find.byType(Scrollable).first);
        }
        expect(find.text('云烟'), findsOneWidget);
        expect(tester.getTopLeft(find.text('已归档作品').first).dx,
            tester.getTopLeft(find.text('已归档作品').last).dx);
        expect(tester.getTopLeft(find.text('2026-10-16 10:30')).dx,
            tester.getTopLeft(find.text('尚未同步')).dx);
        expect(tester.getTopLeft(find.text('已归档作品').first).dy,
            tester.getTopLeft(find.text('2026-10-16 10:30')).dy);
        expect(tester.widget<Text>(find.text('456').last).style!.fontSize,
            tester.widget<Text>(find.text('已建立档案')).style!.fontSize);

        if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
            size.width == 1440) {
          final boundary = preview.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('.dart_tool/ui-preview').create(recursive: true);
            await File(
                    '.dart_tool/ui-preview/creators-${dark ? 'dark' : 'light'}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
            size.width == 1440) {
          final gesture =
              await tester.startGesture(tester.getCenter(find.text('作品档案')));
          await tester.pump(const Duration(milliseconds: 150));
          await tester.runAsync(() async {
            final image = await (preview.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
                    '.dart_tool/ui-preview/pressed-${dark ? 'dark' : 'light'}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await gesture.cancel();
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('添加创作者'));
        await tester.pumpAndSettle();
        expect(find.text('从壁纸识别'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('通过作者添加'));
        await tester.pumpAndSettle();
        expect(find.text('SteamID64 或作者主页链接'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        for (final label in ['作品资料库', '变更记录', '设置与备份']) {
          final target = find.byTooltip(label);
          if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
              label == '作品资料库') {
            await tester.runAsync(() async {
              for (var i = 0; i < 6; i++) {
                final file =
                    File(p.join('.', '.dart_tool/ui-preview/art-$i.png'));
                final codec =
                    await ui.instantiateImageCodec(await file.readAsBytes());
                final frame = await codec.getNextFrame();
                final provider = FileImage(file);
                PaintingBinding.instance.imageCache.putIfAbsent(
                    provider,
                    () => OneFrameImageStreamCompleter(
                        Future.value(ImageInfo(image: frame.image))));
                codec.dispose();
              }
            });
          }
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: label);
          if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
              label == '作品资料库') {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 150)));
            await tester.pumpAndSettle();
          }
          if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
              size.width == 1440) {
            await tester.runAsync(() async {
              final image = await (preview.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
              final bytes =
                  await image.toByteData(format: ui.ImageByteFormat.png);
              final name = label == '作品资料库'
                  ? 'gallery'
                  : label == '设置与备份'
                      ? 'settings'
                      : 'history';
              await File(
                      '.dart_tool/ui-preview/$name-${dark ? 'dark' : 'light'}.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          if (label == '作品资料库') {
            expect(find.text('Orbital'), findsNothing);
            expect(find.text('夏日留白'), findsNothing);
            await tester.tap(find.text('全部创作者'));
            await tester.pumpAndSettle();
            expect(find.text('选择创作者'), findsOneWidget);
            await tester.tap(find.byTooltip('返回'));
            await tester.pumpAndSettle();
          }
          if (label == '作品资料库' && size.width >= 960) {
            await tester.tap(find.text('山间回声 · Mountain Echoes'));
            await tester.pumpAndSettle();
            expect(find.text('变更历史'), findsOneWidget);
            if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
                size.width == 1440) {
              await tester.runAsync(() async {
                final image = await (preview.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
                final bytes =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                await File(
                        '.dart_tool/ui-preview/details-${dark ? 'dark' : 'light'}.png')
                    .writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            expect(tester.takeException(), isNull);
            await tester.tap(find.byIcon(Icons.close).last);
            await tester.pumpAndSettle();
          }
          if (label == '变更记录') {
            expect(find.text('云烟'), findsOneWidget);
            expect(find.text('Moonlight Studio · 长名称创作者作品集'), findsOneWidget);
            await tester.tap(find.text('云烟'));
            await tester.pumpAndSettle();
            expect(find.text('另一位作者的作品'), findsNothing);
            expect(find.text('新增 1 件 · 修改 1 件 · 下架 1 件'), findsOneWidget);
            if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
                size.width == 1440) {
              await saveHistoryPreview(
                  tester, preview, 'history-author-${dark ? 'dark' : 'light'}');
            }
            await tester.tap(find.text('新增 1 件 · 修改 1 件 · 下架 1 件'));
            await tester.pumpAndSettle();
            // A mature work remains visible in history while the gallery is safe-only.
            expect(find.text('Orbital'), findsOneWidget);
            expect(find.text('另一位作者的作品'), findsNothing);
            await tester.tap(find.text('山间回声 · Mountain Echoes'));
            await tester.pumpAndSettle();
            expect(find.text('Orbital'), findsNothing);
            expect(find.text('浮光之城'), findsNothing);
            if (const bool.fromEnvironment('SAVE_UI_PREVIEW') &&
                size.width == 1440) {
              await saveHistoryPreview(
                  tester, preview, 'history-work-${dark ? 'dark' : 'light'}');
            }
            await tester.tap(find.text('山间回声 · Mountain Echoes').last);
            await tester.pumpAndSettle();
            expect(find.textContaining('新的简介'), findsOneWidget);
            expect(find.textContaining('private-old.png'), findsNothing);
            expect(find.textContaining('private-new.png'), findsNothing);
            expect(find.textContaining('https://example.com'), findsNothing);
            expect(find.textContaining('internal API'), findsNothing);
            expect(find.text('封面已更新'), findsOneWidget);
            await tester.tap(find.text('关闭'));
            await tester.pumpAndSettle();
            for (final type in [
              ChangeType.added,
              ChangeType.modified,
              ChangeType.missing,
              ChangeType.restored
            ]) {
              await tester.tap(find.widgetWithText(ChoiceChip, type.label));
              await tester.pumpAndSettle();
              expect(
                  tester
                      .widget<ChoiceChip>(
                          find.widgetWithText(ChoiceChip, type.label))
                      .selected,
                  isTrue);
              expect(tester.takeException(), isNull);
            }
            await tester.tap(find.text('返回作品列表'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('所有创作者'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Moonlight Studio · 长名称创作者作品集'));
            await tester.pumpAndSettle();
            expect(find.text('新增 1 件'), findsOneWidget);
            await tester.tap(find.text('作品时间线'));
            await tester.pumpAndSettle();
            expect(find.text('另一位作者的作品'), findsOneWidget);
            expect(find.text('山间回声 · Mountain Echoes'), findsNothing);
          }
        }
        expect(find.text('查询方式'), findsOneWidget);
        await tester.tap(find.text('查询方式'));
        await tester.pumpAndSettle();
        expect(find.text('Steam Web API Key'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('本地备份').first);
        await tester.pumpAndSettle();
        expect(find.text('创建 ZIP 备份'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('内容分级'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CheckboxListTile, '成人'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('作品资料库'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Orbital'), 160,
            scrollable: find.byType(Scrollable).last);
        expect(find.text('Orbital'), findsOneWidget);
        expect(find.text('夏日留白'), findsNothing);
        final toggle = find.byTooltip(dark ? '切换浅色主题' : '切换深色主题');
        await tester.tap(toggle);
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 150)));
        await tester.pumpAndSettle();
        expect(appThemeMode.value, dark ? ThemeMode.light : ThemeMode.dark);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
            WorkshopMonitorApp(database: PreviewDatabase(dark: dark)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('作品资料库'));
        await tester.pumpAndSettle();
        expect(find.text('Orbital'), findsNothing);
        expect(find.text('山间回声 · Mountain Echoes'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
