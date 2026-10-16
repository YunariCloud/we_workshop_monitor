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
              tags: ['Scene'],
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
      [];
  @override
  Future<List<BackupRecord>> getBackupRecords({int limit = 50}) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
      final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
      if (await font.exists()) {
        final loader = FontLoader('Microsoft YaHei')
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
        expect(find.text('云烟'), findsOneWidget);

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
        await tester.tap(find.text('添加创作者').last);
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
          final target = size.width < 1200
              ? find.byTooltip(label)
              : find.text(label).first;
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
        }
        expect(find.text('查询方式'), findsOneWidget);
        final toggle = find.byTooltip(dark ? '切换浅色主题' : '切换深色主题');
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(appThemeMode.value, dark ? ThemeMode.light : ThemeMode.dark);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }
}
