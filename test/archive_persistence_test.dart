import 'dart:convert';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:we_workshop_monitor/backup_service.dart';
import 'package:we_workshop_monitor/diff_engine.dart';
import 'package:we_workshop_monitor/steam_api_service.dart';
import 'package:we_workshop_monitor/workshop_database.dart';
import 'package:we_workshop_monitor/workshop_models.dart';
import 'package:we_workshop_monitor/webdav_backup.dart';
import 'package:we_workshop_monitor/scheduler_tray_service.dart';

class ArchiveTestSteam extends SteamWorkshopService {
  bool failPreviews = false;
  int previewAttempts = 0;
  List<String> remoteTags = const ['Scene'];
  ArchiveTestSteam(String root) : super(dataRootDir: root);

  @override
  Future<List<RemoteWorkshopEntry>> fetchAllCreatorItems({
    required String steamId,
    required String apiKey,
    SteamQueryMode queryMode = SteamQueryMode.automatic,
    void Function(int, int)? onProgress,
  }) async =>
      [
        for (final id in ['1001', '1002'])
          RemoteWorkshopEntry(
              publishedFileId: id,
              title: 'Archived wallpaper $id',
              description: 'Original description',
              tags: remoteTags,
              fileSizeBytes: 1024,
              previewUrl: 'https://example.com/$id.png',
              timeCreated: 100,
              timeUpdated: 200,
              subscriptions: 50,
              favorites: 10)
      ];

  @override
  Future<({String relativePath, String sha256Hash})?> downloadPreviewImage({
    required String creatorSteamId,
    required String publishedFileId,
    required String previewUrl,
  }) async {
    previewAttempts++;
    if (failPreviews) return null;
    final relative =
        p.join('previews', creatorSteamId, '${publishedFileId}_cover.png');
    final file = File(p.join(dataRootDir, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII='));
    return (relativePath: relative, sha256Hash: 'cover-$publishedFileId');
  }
}

class ActualHttpOverrides extends HttpOverrides {}

WebDavBackupClient localWebDavClient() {
  final dio = Dio();
  dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpOverrides.runWithHttpOverrides(
          () => HttpClient(), ActualHttpOverrides()));
  return WebDavBackupClient(dio: dio);
}

class BlockingArchiveSteam extends ArchiveTestSteam {
  final gate = Completer<void>();
  BlockingArchiveSteam(super.root);
  @override
  Future<List<RemoteWorkshopEntry>> fetchAllCreatorItems(
      {required String steamId,
      required String apiKey,
      SteamQueryMode queryMode = SteamQueryMode.automatic,
      void Function(int, int)? onProgress}) async {
    await gate.future;
    return super.fetchAllCreatorItems(
        steamId: steamId,
        apiKey: apiKey,
        queryMode: queryMode,
        onProgress: onProgress);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // The project uses the SQLite runtime bundled by sqlite3_flutter_libs.
    // Load it before FFI initialization, matching the Windows runner behavior.
    if (Platform.isWindows) {
      final libraries = [
        for (final mode in ['Debug', 'Release'])
          File(p.join('build', 'windows', 'x64', 'runner', mode, 'sqlite3.dll'))
      ];
      final library = libraries.where((file) => file.existsSync()).firstOrNull;
      if (library == null) {
        throw StateError(
            'Run flutter build windows --debug before database integration tests.');
      }
      DynamicLibrary.open(library.absolute.path);
    }
  });

  late Directory temporary;
  late WorkshopDatabase database;
  late ArchiveTestSteam steam;
  late Creator creator;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('workshop-regression-');
    database = await WorkshopDatabase.initialize(
        dataRootDirOverride: p.join(temporary.path, 'data'));
    steam = ArchiveTestSteam(database.dataRootDir);
    creator = Creator(
        steamId: '76561199182487944',
        personaName: 'Archive regression',
        profileUrl: '',
        isBaselineCompleted: false,
        totalActiveCount: 0,
        totalMissingCount: 0,
        createdAt: DateTime.utc(2026));
    await database.upsertCreator(creator);
  });
  tearDown(() async {
    await database.db.close();
    if (!p.isWithin(
            Directory.systemTemp.absolute.path, temporary.absolute.path) ||
        !p.basename(temporary.path).startsWith('workshop-regression-')) {
      throw StateError(
          'Refusing to remove a directory outside the test temporary root');
    }
    await temporary.delete(recursive: true);
  });

  Future<SyncReport> sync() async =>
      WorkshopDiffEngine(database: database, steamService: steam).syncCreator(
          creator: (await database.getAllCreators()).single, apiKey: '');

  test(
      'lightweight archive is self-contained and preserves originals and full history',
      () async {
    await sync();
    final originalItems = await database.queryItems();
    final image = img.Image(width: 480, height: 270);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final v = (x * 17 + y * 31) % 256;
        image.setPixelRgb(x, y, v, (v * 3) % 256, (v * 7) % 256);
      }
    }
    image.addFrame(img.Image.from(image));
    final gif = img.encodeGif(image);
    final relative = p.join('previews', creator.steamId, 'animated.gif');
    final source = File(p.join(database.dataRootDir, relative));
    await source.writeAsBytes(gif);
    await database.db.update('workshop_items', {'preview_local_path': relative},
        where: 'published_file_id = ?', whereArgs: ['1001']);
    await database.db.insert('item_change_logs', {
      'published_file_id': '1001',
      'creator_steam_id': creator.steamId,
      'sync_batch_id': 'new-cover',
      'change_type': 'MODIFIED',
      'detected_at': DateTime.now().toUtc().toIso8601String(),
      'changed_fields_json': jsonEncode({
        'preview_local_path': {
          'old': originalItems.first.previewLocalPath,
          'new': relative
        }
      })
    });
    await File(p.join(database.dataRootDir, 'previews', 'unreferenced.gif'))
        .writeAsBytes(gif);
    final backups = BackupService(database: database);
    final zip = await backups.runLocalZipBackup(
        targetBackupDir: p.join(temporary.path, 'light-zips'),
        lightweight: true);
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    final entries = {for (final entry in archive.files) entry.name: entry};
    final metadata =
        jsonDecode(utf8.decode(entries['exports/items_all.json']!.content))
            as List;
    final changed = metadata
        .cast<Map>()
        .firstWhere((item) => item['published_file_id'] == '1001');
    final newPath =
        (changed['preview_local_path'] as String).replaceAll('\\', '/');
    expect(newPath, matches(RegExp(r'_light\.(jpg|png)$')));
    expect(entries[newPath], isNotNull);
    expect(entries[newPath]!.size, lessThan(gif.length));
    expect(sha256.convert(entries[newPath]!.content).toString(),
        changed['preview_sha256']);
    expect(img.decodeImage(entries[newPath]!.content)!.numFrames, 1);
    expect(entries.keys.where((name) => name.endsWith('.gif')), isEmpty);
    expect(await source.readAsBytes(), gif);
    expect(
        (await database.queryItems())
            .firstWhere((item) => item.publishedFileId == '1001')
            .previewLocalPath,
        relative);
    final manifest = jsonDecode(utf8.decode(entries['manifest.json']!.content));
    expect(manifest['media']['mode'], 'lightweight');
    expect(
        manifest['database_sha256'],
        sha256
            .convert(entries['workshop_monitor_snapshot.db']!.content)
            .toString());
    final snapshotPath = p.join(temporary.path, 'snapshot.db');
    await File(snapshotPath)
        .writeAsBytes(entries['workshop_monitor_snapshot.db']!.content);
    final snapshot = await databaseFactoryFfi.openDatabase(snapshotPath,
        options: OpenDatabaseOptions(readOnly: true));
    try {
      expect(await snapshot.query('workshop_items'), hasLength(2));
      final logs = await snapshot.query('item_change_logs');
      expect(logs, hasLength(3));
      for (final row in logs) {
        final field = jsonDecode(
            row['changed_fields_json'] as String)['preview_local_path'];
        final paths = field is String ? [field] : (field as Map).values;
        for (final path in paths) {
          expect(entries.containsKey((path as String).replaceAll('\\', '/')),
              isTrue);
        }
      }
    } finally {
      await snapshot.close();
    }
    await backups.runLocalMirrorSync(
        targetMirrorDir: p.join(temporary.path, 'mirror'), lightweight: true);
    expect(
        await File(p.join(temporary.path, 'mirror', 'lightweight', newPath))
            .exists(),
        isTrue);
    expect(
        await Directory(p.join(database.dataRootDir, 'backup_work'))
            .list()
            .isEmpty,
        isTrue);
  });

  test(
      'structured progress reports committed work and bulk sync blocks overlapping requests',
      () async {
    final blocked = BlockingArchiveSteam(database.dataRootDir);
    final updates = <(int, int, bool)>[];
    final busy = <bool>[];
    final scheduler = SchedulerAndTrayService(
        database: database,
        diffEngine:
            WorkshopDiffEngine(database: database, steamService: blocked),
        backupService: BackupService(database: database),
        initialSettings: const AppSettings(
            pollIntervalHours: 0, autoBackupAfterChange: false),
        onBackgroundSyncEvent: (_) async {},
        onBusyChanged: busy.add,
        onCreatorProgress: (id, completed, total, finished) {
          expect(id, creator.steamId);
          updates.add((completed, total, finished));
        });
    final pending = scheduler.runScheduledSyncAllCreators();
    await Future<void>.delayed(Duration.zero);
    await expectLater(scheduler.syncCreatorNow(creator), throwsStateError);
    blocked.gate.complete();
    await pending;
    expect(busy, [true, false]);
    expect(updates, contains((1, 2, false)));
    expect(updates.last, (2, 2, true));
    expect(await database.queryItems(), hasLength(2));
    await scheduler.syncCreatorNow((await database.getAllCreators()).single);
    expect(updates.last, (2, 2, true));
    scheduler.dispose();
  });

  test(
      'WebDAV uploads a complete light archive atomically and stores no password in config',
      () async {
    await sync();
    final files = <String, List<int>>{};
    final collections = <String>{'/dav/'};
    final methods = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      methods.add(request.method);
      expect(request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('test-user:test-password'))}');
      if (request.method == 'PROPFIND') {
        request.response.statusCode = 207;
        request.response.write(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response></d:multistatus>');
      } else if (request.method == 'MKCOL') {
        request.response.statusCode =
            collections.add(request.uri.path) ? 201 : 405;
      } else if (request.method == 'PUT') {
        files[request.uri.path] =
            await request.fold<List<int>>([], (all, part) => all..addAll(part));
        request.response.statusCode = 201;
      } else if (request.method == 'MOVE') {
        final destination =
            Uri.parse(request.headers.value('destination')!).path;
        files[destination] = files.remove(request.uri.path)!;
        request.response.statusCode = 201;
      }
      await request.response.close();
    });
    final settings = AppSettings(
        webdavUrl: 'http://127.0.0.1:${server.port}/dav/',
        webdavUsername: 'test-user',
        webdavPassword: 'test-password',
        webdavFolder: '我的备份/sub folder');
    expect(settings.webdavLightweight, isTrue);
    expect(jsonEncode(settings.toNonSensitiveJson()),
        isNot(contains('test-password')));
    await localWebDavClient().testConnection(settings);
    final destination = await runWebDavBackup(
        database: database,
        backups: BackupService(database: database),
        settings: settings,
        client: localWebDavClient());
    expect(files.keys, [destination.path]);
    expect(
        Uri.decodeComponent(destination.path), contains('/我的备份/sub folder/'));
    expect(destination.path, isNot(contains('%25')));
    expect(methods.where((method) => method == 'PUT'), hasLength(1));
    expect(methods.where((method) => method == 'MOVE'), hasLength(1));
    final archive = ZipDecoder().decodeBytes(files.values.single);
    final manifest = jsonDecode(utf8.decode(archive.files
        .firstWhere((entry) => entry.name == 'manifest.json')
        .content));
    expect(manifest['media']['mode'], 'lightweight');
    final records = await database.getBackupRecords();
    expect(records, hasLength(1));
    expect(records.single.targetType, 'WEBDAV');
    expect(
        await Directory(p.join(database.dataRootDir, 'backup_work'))
            .list()
            .isEmpty,
        isTrue);
  });

  test(
      'WebDAV failure cleans temporary uploads and does not record a successful backup',
      () async {
    await sync();
    var deleted = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      if (request.method == 'PROPFIND') {
        request.response.statusCode = 207;
        request.response.write('<d:collection xmlns:d="DAV:"/>');
      } else if (request.method == 'MKCOL' || request.method == 'PUT') {
        request.response.statusCode = 201;
      } else if (request.method == 'MOVE') {
        request.response.statusCode = 500;
      } else if (request.method == 'DELETE') {
        deleted = true;
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
    final settings = AppSettings(
        webdavUrl: 'http://127.0.0.1:${server.port}/dav/',
        webdavPassword: 'never-show-this-password');
    try {
      await runWebDavBackup(
          database: database,
          backups: BackupService(database: database),
          settings: settings,
          client: localWebDavClient());
      fail('The failed MOVE must not be treated as a successful backup');
    } catch (error) {
      expect(error.toString(), isNot(contains('never-show-this-password')));
    }
    expect(deleted, isTrue);
    expect(await database.getBackupRecords(), isEmpty);
    expect(
        await Directory(p.join(database.dataRootDir, 'backup_work'))
            .list()
            .isEmpty,
        isTrue);
  });

  test(
      'content ratings do not exclude any works from sync or backup; cached avatars are included',
      () async {
    steam.remoteTags = ['Mature'];
    final avatar = File(p.join(database.dataRootDir, 'avatars', 'author.img'));
    await avatar.parent.create(recursive: true);
    await avatar.writeAsBytes([1, 2, 3]);
    await database.upsertCreator(
        creator.copyWith(avatarLocalPath: p.join('avatars', 'author.img')));
    final report = await sync();
    expect(report.baselineCount, 2);
    expect(
        (await database.queryItems())
            .every((item) => item.contentRating == ContentRating.mature),
        isTrue);
    final backup = BackupService(database: database);
    final zip = await backup.runLocalZipBackup(
        targetBackupDir: p.join(temporary.path, 'zip'));
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    expect(
        archive.files.any((file) => file.name == 'avatars/author.img'), isTrue);
    final mirror = p.join(temporary.path, 'mirror');
    await backup.runLocalMirrorSync(targetMirrorDir: mirror);
    expect(
        await File(p.join(mirror, 'avatars', 'author.img')).exists(), isTrue);
    final items = jsonDecode(
        await File(p.join(mirror, 'exports', 'items_all.json'))
            .readAsString()) as List;
    expect(items, hasLength(2));
  });

  test('complete history includes records beyond the default list limit',
      () async {
    await sync();
    final batch = database.db.batch();
    for (var i = 0; i < 305; i++) {
      batch.insert('item_change_logs', {
        'published_file_id': '1001',
        'creator_steam_id': creator.steamId,
        'sync_batch_id': 'history-$i',
        'change_type': 'MODIFIED',
        'changed_fields_json': jsonEncode({
          'title': {'old': 'Before', 'new': 'After'}
        }),
        'detected_at':
            DateTime.utc(2026).add(Duration(minutes: i)).toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
    expect(await database.getChangeLogs(), hasLength(300));
    expect(await database.getChangeLogs(limit: -1), hasLength(307));
    expect(await database.getChangeLogs(publishedFileId: '1001', limit: -1),
        hasLength(306));
  });

  test('a new workspace never preloads a fixed creator', () async {
    final fresh = await WorkshopDatabase.initialize(
        dataRootDirOverride: p.join(temporary.path, 'fresh'));
    try {
      expect(await fresh.getAllCreators(), isEmpty);
    } finally {
      await fresh.db.close();
    }
  });

  test('sync statistics and local backups preserve archived items and history',
      () async {
    final baseline = await sync();
    expect(baseline.baselineCount, 2);
    expect(await database.queryItems(), hasLength(2));
    expect(await database.getChangeLogs(), hasLength(2));
    final saved = (await database.getAllCreators()).single;
    await database
        .upsertCreator(saved.copyWith(personaName: 'Renamed creator'));
    expect(await database.queryItems(), hasLength(2));
    expect(await database.getChangeLogs(), hasLength(2));
    final second = await sync();
    expect(second.hasAnyChange, isFalse);
    expect((await database.getAllCreators()).single.totalActiveCount, 2);

    final backup = BackupService(database: database);
    final mirror = p.join(temporary.path, 'mirror');
    await backup.runLocalMirrorSync(targetMirrorDir: mirror);
    final exported = jsonDecode(
        await File(p.join(mirror, 'exports', 'items_all.json'))
            .readAsString()) as List;
    expect(exported, hasLength(2));
    for (final item in await database.queryItems()) {
      expect(
          await File(p.join(mirror, item.previewLocalPath!)).exists(), isTrue);
    }
    final zip = await backup.runLocalZipBackup(
        targetBackupDir: p.join(temporary.path, 'zips'));
    final files = ZipDecoder().decodeBytes(await zip.readAsBytes());
    expect(files.any((file) => file.name == 'exports/items_all.json'), isTrue);
    expect(files.where((file) => file.name.endsWith('.png')), hasLength(2));
    expect(await database.queryItems(), hasLength(2));
    expect(await database.getBackupRecords(), hasLength(2));
    await database.deleteCreator(creator.steamId);
    expect(await database.queryItems(), isEmpty);
    expect(await database.getChangeLogs(), isEmpty);
  });

  test(
      'startup detects old cascade deletion and the next sync rebuilds the archive',
      () async {
    await sync();
    final saved = (await database.getAllCreators()).single;
    // Reproduce the old implementation in this disposable test database only.
    await database.db.insert('creators', saved.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    expect(await database.queryItems(), isEmpty);
    final root = database.dataRootDir;
    await database.db.close();
    database = await WorkshopDatabase.initialize(dataRootDirOverride: root);
    final repaired = (await database.getAllCreators()).single;
    expect(repaired.isBaselineCompleted, isFalse);
    expect(repaired.totalActiveCount, 0);
    expect((await sync()).baselineCount, 2);
    expect(await database.queryItems(), hasLength(2));
    expect(await database.getChangeLogs(), hasLength(2));
  });

  test(
      'unchanged works retry missing covers without inventing modification events',
      () async {
    steam.failPreviews = true;
    await sync();
    expect(
        (await database.queryItems())
            .every((item) => item.previewLocalPath == null),
        isTrue);
    steam.failPreviews = false;
    expect((await sync()).modifiedCount, 0);
    final items = await database.queryItems();
    expect(items.every((item) => item.previewLocalPath != null), isTrue);
    final cover =
        File(p.join(database.dataRootDir, items.first.previewLocalPath!));
    await cover.delete();
    expect((await sync()).modifiedCount, 0);
    expect(await cover.exists(), isTrue);
    expect(steam.previewAttempts, 5);
    expect(await database.getChangeLogs(), hasLength(2));
  });
}
