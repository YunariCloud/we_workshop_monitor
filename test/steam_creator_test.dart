import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:we_workshop_monitor/steam_api_service.dart';
import 'package:we_workshop_monitor/workshop_models.dart';
import 'package:we_workshop_monitor/steam_client_source.dart';

class FakeSteamSource implements SteamPublishedFileSource {
  final List<String>? ids;
  final bool fail;
  FakeSteamSource({this.ids, this.fail = false});
  @override
  Future<List<String>?> fetchPublishedIds(
      {required String steamId, void Function(int, int)? onProgress}) async {
    if (fail) throw Exception('Steam query failed');
    if (ids != null) onProgress?.call(ids!.length, ids!.length);
    return ids;
  }
}

class FakeAdapter implements HttpClientAdapter {
  final Object Function(RequestOptions) respond;
  FakeAdapter(this.respond);
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final result = respond(options);
    return ResponseBody.fromString(
      result is String ? result : jsonEncode(result),
      200,
      headers: {
        Headers.contentTypeHeader: [
          result is String ? 'text/html' : 'application/json'
        ]
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

SteamWorkshopService service(Object Function(RequestOptions) respond) {
  final dio = Dio()..httpClientAdapter = FakeAdapter(respond);
  return SteamWorkshopService(
      dataRootDir: '.', dio: dio, steamClient: FakeSteamSource());
}

Map<String, Object> detail(String id,
        {int appId = 431960, int result = 1, int fileType = 0}) =>
    {
      'publishedfileid': id,
      'creator': '76561199182487944',
      'consumer_app_id': appId,
      'result': result,
      'file_type': fileType,
      'title': 'Test wallpaper',
    };
Map<String, Object> detailsResponse(List<Map<String, Object>> items) => {
      'response': {'publishedfiledetails': items},
    };

void main() {
  test(
      'explicit API mode paginates without using Steam and preserves full metadata',
      () async {
    const key = '00000000000000000000000000000000';
    final requestedPages = <int>[];
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((request) {
        if (request.method == 'GET') {
          final page = request.queryParameters['page'] as int;
          requestedPages.add(page);
          final rows = List.generate(
              page == 3 ? 1 : 100,
              (i) => {
                    ...detail('${10000 + (page - 1) * 100 + i}'),
                    'file_description': 'Full archived description'
                  });
          return {
            'response': {'total': 201, 'publishedfiledetails': rows}
          };
        }
        final data = request.data as Map;
        return detailsResponse(List.generate(
            data['itemcount'] as int,
            (i) => {
                  ...detail(data['publishedfileids[$i]'] as String),
                  'description': 'Full archived description'
                }));
      });
    final api = SteamWorkshopService(
        dataRootDir: '.', dio: dio, steamClient: FakeSteamSource(fail: true));
    final items = await api.fetchAllCreatorItems(
        steamId: '76561199182487944',
        apiKey: key,
        queryMode: SteamQueryMode.webApi);
    expect(requestedPages, [1, 2, 3]);
    expect(items.length, 201);
    expect(items.every((i) => i.description == 'Full archived description'),
        isTrue);
  });

  test('query mode and theme persist without placing the key in config JSON',
      () {
    const settings = AppSettings(
        steamApiKey: 'test-secret',
        steamQueryMode: SteamQueryMode.webApi,
        useDarkTheme: true);
    final config = settings.toNonSensitiveJson();
    expect(config.toString(), isNot(contains('test-secret')));
    final restored = AppSettings.fromNonSensitiveJson(config);
    expect(restored.steamQueryMode, SteamQueryMode.webApi);
    expect(restored.useDarkTheme, isTrue);
    expect(AppSettings.fromNonSensitiveJson({}).steamQueryMode,
        SteamQueryMode.automatic);
  });

  test('API failures never expose the key or authenticated URL', () async {
    const secret = '00000000000000000000000000000000';
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((request) {
        throw DioException.badResponse(
            statusCode: 403,
            requestOptions: request,
            response: Response(requestOptions: request, statusCode: 403));
      });
    final api = SteamWorkshopService(
        dataRootDir: '.', dio: dio, steamClient: FakeSteamSource(fail: true));
    try {
      await api.fetchAllCreatorItems(
          steamId: '76561199182487944',
          apiKey: secret,
          queryMode: SteamQueryMode.webApi);
      fail('Expected an authentication error');
    } catch (error) {
      expect(error.toString(), isNot(contains(secret)));
      expect(error.toString(), isNot(contains('key=')));
      expect(error.toString(), contains('API Key'));
    }
  });

  test('live key queries all pages without invoking the Steam client',
      () async {
    final key = Platform.environment['STEAM_TEST_API_KEY'] ?? '';
    expect(key, isNotEmpty,
        reason: 'Provide the key via the process environment only.');
    final api = SteamWorkshopService(
        dataRootDir: '.', steamClient: FakeSteamSource(fail: true));
    final items = await api.fetchAllCreatorItems(
        steamId: '76561199182487944',
        apiKey: key,
        queryMode: SteamQueryMode.webApi);
    expect(items.length, greaterThan(400));
    expect(items.map((i) => i.publishedFileId).toSet().length, items.length);
    // ignore: avoid_print
    print(
        'Web API Key verification: ${items.length} complete item details, client disabled.');
    final nativeIds = await SteamClientWorkshopSource()
        .fetchPublishedIds(steamId: '76561199182487944');
    if (nativeIds != null) {
      final missing = nativeIds
          .toSet()
          .difference(items.map((i) => i.publishedFileId).toSet());
      // ignore: avoid_print
      print(
          'Source comparison: client=${nativeIds.length}, API=${items.length}, only-in-client=$missing');
    }
  },
      skip: !const bool.fromEnvironment('STEAM_WEB_API_LIVE_TEST'),
      timeout: const Timeout(Duration(minutes: 3)));
  test('native published list takes priority over truncated website results',
      () async {
    final requests = <String>[];
    final ids = List.generate(457, (i) => '${10000 + i}');
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((request) {
        requests.add(request.method);
        expect(request.method, 'POST');
        final data = request.data as Map;
        final chunk = List.generate(data['itemcount'] as int,
            (i) => detail(data['publishedfileids[$i]'] as String));
        return detailsResponse(chunk);
      });
    final api = SteamWorkshopService(
        dataRootDir: '.', dio: dio, steamClient: FakeSteamSource(ids: ids));
    final items = await api.fetchAllCreatorItems(
        steamId: '76561199182487944', apiKey: '');
    expect(items.length, 457);
    expect(items.map((e) => e.publishedFileId).toSet(), ids.toSet());
    expect(requests.length, 10);
  });

  test('failed native query never falls back to partial website results',
      () async {
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((_) => fail('Unexpected web fallback'));
    final api = SteamWorkshopService(
        dataRootDir: '.', dio: dio, steamClient: FakeSteamSource(fail: true));
    await expectLater(
        api.fetchAllCreatorItems(steamId: '76561199182487944', apiKey: ''),
        throwsException);
  });
  test('accepts workshop and Steam client links; IDs are explicit', () {
    expect(
        SteamInputParser.parseWorkshopFileId(
            'https://steamcommunity.com/sharedfiles/filedetails/?id=3325728106&searchtext=x'),
        '3325728106');
    expect(
        SteamInputParser.parseWorkshopFileId(
            'steam://url/CommunityFilePage/3325728106'),
        '3325728106');
    expect(SteamInputParser.parseWorkshopFileId('3325728106'), isNull);
    expect(
        SteamInputParser.parseWorkshopFileId('3325728106', allowBareId: true),
        '3325728106');
    for (final url in [
      'https://steamcommunity.com.evil.com/sharedfiles/filedetails/?id=123',
      'https://steamcommunity.com/profiles/76561199182487944',
      'https://steamcommunity.com/sharedfiles/filedetails/?id=-1'
    ]) {
      expect(SteamInputParser.parseWorkshopFileId(url), isNull);
    }
  });

  test('resolves author from a public item when profile has no metadata',
      () async {
    final api = service((request) => request.method == 'POST'
        ? detailsResponse([detail('3325728106')])
        : '<profile><privacyState>private</privacyState></profile>');
    final creator = await api.resolveCreatorFromWorkshopItem(
        rawInput: '3325728106', apiKey: '');
    expect(creator.steamId64, '76561199182487944');
    expect(creator.personaName, 'Creator_76561199182487944');
  });

  for (final entry in [
    detail('123', appId: 730),
    detail('123', result: 9),
    detail('123', fileType: 2)
  ]) {
    test('rejects unrelated, unavailable or collection item: $entry', () async {
      final api = service((_) => detailsResponse([entry]));
      await expectLater(
          api.resolveCreatorFromWorkshopItem(rawInput: '123', apiKey: ''),
          throwsException);
    });
  }

  test('follows next-page links even when Steam returns fewer than 30 items',
      () async {
    final pages = <String>[];
    final api = service((request) {
      if (request.method == 'POST') {
        return detailsResponse([detail('123'), detail('456')]);
      }
      final page = request.uri.queryParameters['p']!;
      pages.add(page);
      final id = page == '1' ? '123' : '456';
      return '<div class="workshopBrowseItems"><div class="workshopItem"><a class="ugc" href="https://steamcommunity.com/sharedfiles/filedetails/?id=$id"></a></div></div>'
          '${page == '1' ? '<div class="workshopBrowsePaging"><a href="?p=2">2</a></div>' : ''}';
    });
    final items = await api.fetchAllCreatorItems(
        steamId: '76561199182487944', apiKey: '');
    expect(pages, ['1', '2']);
    expect(items.map((item) => item.publishedFileId), ['123', '456']);
  });

  test('private profile / changed page cannot produce an empty baseline',
      () async {
    final api = service(
        (_) => '<div class="profile_private_info">Private profile</div>');
    await expectLater(
        api.fetchAllCreatorItems(steamId: '76561199182487944', apiKey: ''),
        throwsException);
  });

  test('genuinely empty workshop list is allowed', () async {
    final api = service((_) => '<div class="workshopBrowseItems"></div>');
    expect(
        await api.fetchAllCreatorItems(
            steamId: '76561199182487944', apiKey: ''),
        isEmpty);
  });

  test('incomplete item metadata aborts rather than silently dropping items',
      () async {
    final api = service((request) => request.method == 'POST'
        ? detailsResponse([])
        : '<div class="workshopItem"><a class="ugc" data-publishedfileid="123"></a></div>');
    await expectLater(
        api.fetchAllCreatorItems(steamId: '76561199182487944', apiKey: ''),
        throwsException);
  });

  test('invalid API response cannot produce an empty baseline', () async {
    final api = service((_) => {
          'response': {'result': 15}
        });
    await expectLater(
        api.fetchAllCreatorItems(steamId: '76561199182487944', apiKey: 'test'),
        throwsException);
  });

  test('live author and workshop lookup for supplied private-profile example',
      () async {
    final api = SteamWorkshopService(dataRootDir: '.');
    final creator = await api.resolveCreatorIdentity(
        rawInput: 'https://steamcommunity.com/profiles/76561199182487944/',
        apiKey: '');
    expect(creator.steamId64, '76561199182487944');
    final items =
        await api.fetchAllCreatorItems(steamId: creator.steamId64, apiKey: '');
    expect(items.length, greaterThan(400),
        reason:
            'The native source must not regress to the 30 website results.');
    expect(items.map((e) => e.publishedFileId).toSet().length, items.length);
    final resolved = await api.resolveCreatorFromWorkshopItem(
        rawInput: items.first.publishedFileId, apiKey: '');
    expect(resolved.steamId64, creator.steamId64);
    // ignore: avoid_print
    print(
        'Live Steam verification: ${creator.personaName}, ${items.length} public items, item-to-author identity matched.');
  },
      skip: !const bool.fromEnvironment('STEAM_LIVE_TEST'),
      timeout: const Timeout(Duration(minutes: 3)));
}
