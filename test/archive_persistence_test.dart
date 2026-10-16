import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:we_workshop_monitor/backup_service.dart';
import 'package:we_workshop_monitor/diff_engine.dart';
import 'package:we_workshop_monitor/steam_api_service.dart';
import 'package:we_workshop_monitor/workshop_database.dart';
import 'package:we_workshop_monitor/workshop_models.dart';

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
