import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:we_workshop_monitor/app_theme.dart';
import 'package:we_workshop_monitor/scheduler_tray_service.dart';
import 'package:we_workshop_monitor/workshop_models.dart';
import 'package:we_workshop_monitor/workshop_timeline.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('desktop minimum size is enforced without shrinking a larger window',
      () async {
    final calls = <MethodCall>[];
    var size = const Size(700, 800);
    const channel = MethodChannel('window_manager');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getBounds') {
        return {'x': 0.0, 'y': 0.0, 'width': size.width, 'height': size.height};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await configureDesktopWindow();
    final minimum = calls
        .firstWhere((call) => call.method == 'setMinimumSize')
        .arguments as Map;
    expect(minimum['width'], 960);
    expect(minimum['height'], 680);
    final resized =
        calls.firstWhere((call) => call.method == 'setBounds').arguments as Map;
    expect(resized['width'], 960);
    expect(resized['height'], 800);
    size = const Size(1280, 900);
    calls.clear();
    await configureDesktopWindow();
    expect(calls.where((call) => call.method == 'setBounds'), isEmpty);
  });

  testWidgets('timeline rails join across rows and entries open details',
      (tester) async {
    var opened = -1;
    await tester.pumpWidget(MaterialApp(
        theme: buildWorkshopTheme(),
        home: Scaffold(
          body: Column(children: [
            for (var i = 0; i < 3; i++)
              WorkshopTimelineEntry(
                log: ItemChangeLog(
                    publishedFileId: '$i',
                    creatorSteamId: 'author',
                    syncBatchId: 'batch',
                    changeType: ChangeType.modified,
                    changedFields: {'description': 'Hidden detailed metadata'},
                    detectedAt: DateTime(2026)),
                title: '作品 $i',
                isFirst: i == 0,
                isLast: i == 2,
                onTap: () => opened = i,
              )
          ]),
        )));
    final before = find.byKey(const ValueKey('timeline-before'));
    final after = find.byKey(const ValueKey('timeline-after'));
    expect(before, findsNWidgets(2));
    expect(after, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(
          tester.getRect(after.at(i)).bottom, tester.getRect(before.at(i)).top);
      expect(
          tester.getRect(after.at(i)).left, tester.getRect(before.at(i)).left);
    }
    expect(find.textContaining('Hidden detailed metadata'), findsNothing);
    await tester.tap(find.text('作品 1'));
    expect(opened, 1);
  });

  test('filter labels keep readable contrast in both themes', () {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      appThemeMode.value = mode;
      final theme = buildWorkshopTheme();
      for (final selected in [false, true]) {
        final states = selected ? {WidgetState.selected} : <WidgetState>{};
        final background = theme.chipTheme.color!.resolve(states)!;
        final style =
            WidgetStateProperty.resolveAs(theme.chipTheme.labelStyle!, states);
        final a = background.computeLuminance();
        final b = style.color!.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(ratio, greaterThanOrEqualTo(4.5));
      }
    }
    appThemeMode.value = ThemeMode.light;
  });
}
