import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'workshop_models.dart';
import 'steam_client_source.dart';

/// 远端抓取到的单条创意工坊作品数据结构
class RemoteWorkshopEntry {
  final String publishedFileId;
  final String title;
  final String description;
  final List<String> tags;
  final int fileSizeBytes;
  final String previewUrl;
  final int timeCreated;
  final int timeUpdated;
  final int views;
  final int subscriptions;
  final int favorites;

  const RemoteWorkshopEntry({
    required this.publishedFileId,
    required this.title,
    required this.description,
    required this.tags,
    required this.fileSizeBytes,
    required this.previewUrl,
    required this.timeCreated,
    required this.timeUpdated,
    this.views = 0,
    required this.subscriptions,
    required this.favorites,
  });
}

/// Steam 创意工坊采集与预览图归档服务
/// - Windows 优先：本机 Steam 客户端的 Published 列表
/// - 未安装客户端源时：Steam Web API 或社区网页
/// - 防误报核验通道：ISteamRemoteStorage/GetPublishedFileDetails
class SteamWorkshopService {
  final Dio _dio;
  final SteamPublishedFileSource _steamClient;
  final String dataRootDir;
  String lastFetchSourceLabel = '';

  SteamWorkshopService(
      {required this.dataRootDir,
      Dio? dio,
      SteamPublishedFileSource? steamClient})
      : _steamClient = steamClient ?? SteamClientWorkshopSource(),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WallpaperEngineWorkshopMonitor/1.0',
                  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
                },
              ),
            );

  /// 解析创作者输入（64 位 SteamID、个人主页链接或自定义个性 URL）为标准 SteamID64 与昵称
  Future<({String steamId64, String personaName, String? avatarUrl})>
      resolveCreatorFromWorkshopItem({
    required String rawInput,
    required String apiKey,
  }) async {
    final fileId =
        SteamInputParser.parseWorkshopFileId(rawInput, allowBareId: true);
    if (fileId == null) {
      throw const FormatException('请输入壁纸作品链接或作品 ID');
    }
    final response = await _dio.post<Map<String, dynamic>>(
      'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/',
      data: {'itemcount': 1, 'publishedfileids[0]': fileId},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final details =
        response.data?['response']?['publishedfiledetails'] as List?;
    if (details == null || details.length != 1) {
      throw Exception('Steam 未返回作品信息，请检查作品链接后重试');
    }
    final item = Map<String, dynamic>.from(details.single as Map);
    if (item['result'] != 1 || item['publishedfileid']?.toString() != fileId) {
      throw Exception('无法读取此作品，可能已删除或不可公开访问');
    }
    if (item['consumer_app_id']?.toString() != '$kWallpaperEngineAppId' ||
        item['file_type']?.toString() == '2') {
      throw Exception('请提供 Wallpaper Engine 的单个壁纸作品，不支持合集或其他游戏作品');
    }
    final creator = item['creator']?.toString() ?? '';
    if (!RegExp(r'^\d{17}$').hasMatch(creator) ||
        BigInt.parse(creator) == BigInt.zero) {
      throw Exception('此作品未提供有效的作者信息');
    }
    // Identity resolution tolerates private/unavailable profiles.
    return resolveCreatorIdentity(rawInput: creator, apiKey: apiKey);
  }

  Future<({String steamId64, String personaName, String? avatarUrl})>
      resolveCreatorIdentity({
    required String rawInput,
    required String apiKey,
  }) async {
    if (SteamInputParser.parseWorkshopFileId(rawInput) != null) {
      return resolveCreatorFromWorkshopItem(rawInput: rawInput, apiKey: apiKey);
    }
    final parsed = SteamInputParser.parseCreatorInput(rawInput);
    String? steamId64 = parsed.steamId64;

    // 若用户输入的是自定义个性域名 (如 /id/xxx)，先解析出 64 位 SteamID
    if (steamId64 == null && parsed.vanityName != null) {
      if (apiKey.trim().isNotEmpty) {
        final resp =
            await _authenticatedGet('ISteamUser/ResolveVanityURL/v1/', {
          'key': apiKey.trim(),
          'vanityurl': parsed.vanityName,
        });
        final body = resp['response'] as Map<String, dynamic>? ?? {};
        if (body['success'] == 1 && body['steamid'] != null) {
          steamId64 = body['steamid'].toString();
        }
      }
      // 免 API Key 网页解析降级：通过 ?xml=1 获取 steamID64
      if (steamId64 == null) {
        final xmlResp = await _dio.get<String>(
          'https://steamcommunity.com/id/${parsed.vanityName}/?xml=1',
        );
        final match = RegExp(r'<steamID64>(\d{17})</steamID64>')
            .firstMatch(xmlResp.data ?? '');
        if (match != null) {
          steamId64 = match.group(1);
        }
      }
    }

    if (steamId64 == null || steamId64.isEmpty) {
      throw Exception('无法解析创作者 SteamID，请输入 17 位数字 SteamID64 或完整个人主页链接');
    }

    // 获取创作者昵称与头像
    if (apiKey.trim().isNotEmpty) {
      try {
        final summaryResp =
            await _authenticatedGet('ISteamUser/GetPlayerSummaries/v2/', {
          'key': apiKey.trim(),
          'steamids': steamId64,
        });
        final players = summaryResp['response']?['players'] as List<dynamic>?;
        if (players != null && players.isNotEmpty) {
          final p0 = players.first as Map<String, dynamic>;
          return (
            steamId64: steamId64,
            personaName: p0['personaname']?.toString() ?? 'Creator_$steamId64',
            avatarUrl: p0['avatarfull']?.toString(),
          );
        }
      } catch (_) {}
    }

    // 免 Key XML 资料降级
    try {
      final xmlResp = await _dio.get<String>(
        'https://steamcommunity.com/profiles/$steamId64/?xml=1',
      );
      final rawXml = xmlResp.data ?? '';
      final nameMatch = RegExp(r'<steamID><!\[CDATA\[(.*?)\]\]></steamID>')
          .firstMatch(rawXml);
      final avatarMatch = RegExp(
        r'<avatarFull><!\[CDATA\[(.*?)\]\]></avatarFull>',
      ).firstMatch(rawXml);
      return (
        steamId64: steamId64,
        personaName: nameMatch?.group(1) ?? 'Creator_$steamId64',
        avatarUrl: avatarMatch?.group(1),
      );
    } catch (_) {
      return (
        steamId64: steamId64,
        personaName: 'Creator_$steamId64',
        avatarUrl: null,
      );
    }
  }

  /// Automatic uses the configured key first; explicit modes never silently fall back.
  Future<List<RemoteWorkshopEntry>> fetchAllCreatorItems({
    required String steamId,
    required String apiKey,
    SteamQueryMode queryMode = SteamQueryMode.automatic,
    void Function(int fetched, int total)? onProgress,
  }) async {
    if (queryMode == SteamQueryMode.webApi ||
        (queryMode == SteamQueryMode.automatic && apiKey.trim().isNotEmpty)) {
      lastFetchSourceLabel = 'Web API Key';
      if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(apiKey.trim())) {
        throw const FormatException('请填写有效的 32 位 Steam Web API Key');
      }
      return _fetchViaSteamWebApi(
          steamId: steamId, apiKey: apiKey.trim(), onProgress: onProgress);
    }
    if (queryMode != SteamQueryMode.web) {
      lastFetchSourceLabel = 'Steam 客户端';
      final nativeIds = await _steamClient.fetchPublishedIds(
          steamId: steamId, onProgress: onProgress);
      if (nativeIds != null) {
        return _fetchBatchDetailsPublicApi(nativeIds,
            fallbackTitles: const {},
            fallbackPreviews: const {},
            expectedCreatorSteamId: steamId,
            onProgress: onProgress);
      }
      if (queryMode == SteamQueryMode.client) {
        throw Exception('未找到本机 Wallpaper Engine 客户端源，请安装后重试，或切换为 Web API Key');
      }
    }
    lastFetchSourceLabel = '公开网页（结果可能不完整）';
    return _fetchViaHtmlFallback(steamId: steamId, onProgress: onProgress);
  }

  Future<Map<String, dynamic>> _authenticatedGet(
      String path, Map<String, dynamic> parameters) async {
    try {
      final response = await _retryRequest(() => _dio.get<Map<String, dynamic>>(
          'https://api.steampowered.com/$path',
          queryParameters: parameters));
      return response.data ?? {};
    } on DioException catch (error) {
      // Never expose request URLs or credentials through an exception message.
      final status = error.response?.statusCode;
      throw Exception(status == 401 || status == 403
          ? 'Steam 拒绝了 API Key，请检查 Key 是否有效及账号权限'
          : 'Steam Web API 请求失败（${status == null ? '网络连接异常' : 'HTTP $status'}），请稍后重试');
    }
  }

  /// A single authenticated request; never imports or paginates test results.
  Future<int> testWebApiKey(
      {required String steamId, required String apiKey}) async {
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(apiKey.trim())) {
      throw const FormatException('请填写有效的 32 位 Steam Web API Key');
    }
    final body =
        await _authenticatedGet('IPublishedFileService/GetUserFiles/v1/', {
      'key': apiKey.trim(),
      'steamid': steamId,
      'appid': kWallpaperEngineAppId,
      'page': 1,
      'numperpage': 1,
      'return_details': true,
    });
    final response = body['response'] as Map?;
    final total = int.tryParse(response?['total']?.toString() ?? '');
    final rows = response?['publishedfiledetails'] as List? ?? [];
    if (total == null ||
        total < 0 ||
        (response?['result'] != null && response?['result'] != 1) ||
        rows.length > 1 ||
        (total > 0 && rows.isEmpty) ||
        rows.any((row) => row is! Map || row['result'] != 1)) {
      throw Exception('Steam 未返回有效的测试结果，请检查 API Key');
    }
    return rows.length;
  }

  Future<List<RemoteWorkshopEntry>> _fetchViaSteamWebApi({
    required String steamId,
    required String apiKey,
    void Function(int fetched, int total)? onProgress,
  }) async {
    final ids = <String>{};
    final entries = <String, RemoteWorkshopEntry>{};
    int? expectedTotal;
    for (var page = 1;; page++) {
      final body =
          await _authenticatedGet('IPublishedFileService/GetUserFiles/v1/', {
        'key': apiKey,
        'steamid': steamId,
        'appid': kWallpaperEngineAppId,
        'page': page,
        'numperpage': 100,
        'return_tags': true,
        'return_previews': true,
        'return_short_description': false,
        'return_details': true,
      });
      final response = body['response'] as Map<String, dynamic>?;
      final total = int.tryParse(response?['total']?.toString() ?? '');
      if (response == null ||
          total == null ||
          total < 0 ||
          (response['result'] != null && response['result'] != 1)) {
        throw Exception('Steam 未返回有效作品列表，请检查 API Key 或稍后重试');
      }
      expectedTotal ??= total;
      if (total != expectedTotal) throw Exception('查询期间作品数量发生变化，请重新同步');
      final rows = response['publishedfiledetails'] as List? ?? [];
      final before = ids.length;
      for (final raw in rows) {
        final item = raw as Map;
        final id = item['publishedfileid']?.toString() ?? '';
        if (item['result'] != 1 ||
            !RegExp(r'^[1-9]\d*$').hasMatch(id) ||
            item['creator']?.toString() != steamId ||
            (item['consumer_appid'] ?? item['consumer_app_id'])?.toString() !=
                '$kWallpaperEngineAppId') {
          throw Exception('Steam API 返回的作品详情或作者归属无效，本次同步已停止');
        }
        ids.add(id);
        entries[id] = RemoteWorkshopEntry(
          publishedFileId: id,
          title: item['title']?.toString() ?? '未命名作品 ($id)',
          description: (item['file_description'] ??
                      item['description'] ??
                      item['short_description'])
                  ?.toString() ??
              '',
          tags: (item['tags'] as List? ?? [])
              .map((tag) => (tag as Map)['tag']?.toString() ?? '')
              .where((tag) => tag.isNotEmpty)
              .toList(),
          fileSizeBytes:
              int.tryParse(item['file_size']?.toString() ?? '0') ?? 0,
          previewUrl: item['preview_url']?.toString() ?? '',
          timeCreated:
              int.tryParse(item['time_created']?.toString() ?? '0') ?? 0,
          timeUpdated:
              int.tryParse(item['time_updated']?.toString() ?? '0') ?? 0,
          views: int.tryParse(item['views']?.toString() ?? '0') ?? 0,
          subscriptions:
              int.tryParse(item['subscriptions']?.toString() ?? '0') ?? 0,
          favorites: int.tryParse(item['favorited']?.toString() ?? '0') ?? 0,
        );
      }
      onProgress?.call(ids.length, total);
      if (ids.length == total) break;
      if (ids.length > total || ids.length == before) {
        throw Exception('Steam API 返回的作品分页不完整，本次不会使用部分结果');
      }
    }
    return entries.values.toList();
  }

  /// 备用通道：免 API Key 抓取创意工坊网页 HTML DOM 并调用公开的 GetPublishedFileDetails 补全元数据
  Future<List<RemoteWorkshopEntry>> _fetchViaHtmlFallback({
    required String steamId,
    void Function(int fetched, int total)? onProgress,
  }) async {
    final discoveredIds = <String>[];
    final fallbackTitles = <String, String>{};
    final fallbackPreviews = <String, String>{};
    int page = 1;

    while (true) {
      final url =
          'https://steamcommunity.com/profiles/$steamId/myworkshopfiles/?appid=$kWallpaperEngineAppId&p=$page&numperpage=30';
      final response = await _retryRequest(() => _dio.get<String>(url));
      final document = html_parser.parse(response.data ?? '');

      final itemElements = document.querySelectorAll('.workshopItem');
      if (itemElements.isEmpty) {
        // A private profile, login wall or changed DOM must never become an empty baseline.
        if (document.querySelector(
                '.workshopBrowseItems, .workshopBrowseItemsContainer') ==
            null) {
          throw Exception('无法读取作者的公开作品列表，可能是主页隐私或 Steam 访问限制。'
              '可在设置中配置 Steam Web API Key 后重试；本次不会变更作品状态。');
        }
        break;
      }

      int newInPage = 0;
      for (final el in itemElements) {
        final ugcLink = el.querySelector('a.ugc, a.workshopItemPreviewHolder');
        final id = ugcLink?.attributes['data-publishedfileid'] ??
            SteamInputParser.parseWorkshopFileId(
                ugcLink?.attributes['href'] ?? '') ??
            '';
        if (id.isEmpty || discoveredIds.contains(id)) continue;

        discoveredIds.add(id);
        newInPage++;

        final titleEl = el.querySelector('.workshopItemTitle');
        if (titleEl != null) {
          fallbackTitles[id] = titleEl.text.trim();
        }
        final imgEl = el.querySelector('img.workshopItemPreviewImage');
        if (imgEl != null && imgEl.attributes['src'] != null) {
          fallbackPreviews[id] = imgEl.attributes['src']!;
        }
      }

      onProgress?.call(discoveredIds.length, discoveredIds.length);
      if (newInPage == 0) {
        throw Exception('Steam 作品列表解析失败或分页重复，本次同步已停止');
      }
      // Steam may ignore numperpage and return nine items per page.
      // Follow its actual pagination rather than assuming a fixed page size.
      final hasNextPage = document
          .querySelectorAll('.workshopBrowsePaging a[href]')
          .any((link) =>
              Uri.tryParse(link.attributes['href'] ?? '')
                  ?.queryParameters['p'] ==
              '${page + 1}');
      if (!hasNextPage) break;
      page++;
    }

    if (discoveredIds.isEmpty) return [];

    // 使用无需 API Key 的公开接口 ISteamRemoteStorage/GetPublishedFileDetails/v1 批量补全详情
    return _fetchBatchDetailsPublicApi(
      discoveredIds,
      fallbackTitles: fallbackTitles,
      fallbackPreviews: fallbackPreviews,
      expectedCreatorSteamId: steamId,
    );
  }

  /// 批量调用无需 API Key 的 GetPublishedFileDetails 接口补全元数据
  Future<List<RemoteWorkshopEntry>> _fetchBatchDetailsPublicApi(
    List<String> fileIds, {
    required Map<String, String> fallbackTitles,
    required Map<String, String> fallbackPreviews,
    required String expectedCreatorSteamId,
    void Function(int fetched, int total)? onProgress,
  }) async {
    final entries = <RemoteWorkshopEntry>[];
    const int batchSize = 50;

    for (int i = 0; i < fileIds.length; i += batchSize) {
      final chunk = fileIds.skip(i).take(batchSize).toList();
      final formData = <String, dynamic>{'itemcount': chunk.length};
      for (int idx = 0; idx < chunk.length; idx++) {
        formData['publishedfileids[$idx]'] = chunk[idx];
      }

      final resp = await _retryRequest(
        () => _dio.post<Map<String, dynamic>>(
          'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/',
          data: formData,
          options: Options(contentType: Headers.formUrlEncodedContentType),
        ),
      );

      final details =
          resp.data?['response']?['publishedfiledetails'] as List<dynamic>? ??
              [];
      final returnedIds = details
          .map((raw) => (raw as Map)['publishedfileid']?.toString())
          .toSet();
      if (details.length != chunk.length || !returnedIds.containsAll(chunk)) {
        throw Exception('Steam 未返回完整作品详情，本次同步已停止，请稍后重试');
      }
      for (final raw in details) {
        final d = raw as Map<String, dynamic>;
        if (d['result'] != 1) {
          throw Exception('Steam 未能返回完整作品详情，本次同步已停止，请稍后重试');
        }
        if (d['creator']?.toString() != expectedCreatorSteamId ||
            d['consumer_app_id']?.toString() != '$kWallpaperEngineAppId') {
          throw Exception('Steam 返回了其他作者或其他应用的作品，本次同步已停止');
        }
        final id = d['publishedfileid']?.toString() ?? '';
        if (id.isEmpty) continue;

        final rawTags = d['tags'] as List<dynamic>? ?? [];
        final tags = rawTags
            .map((t) => (t as Map<String, dynamic>)['tag']?.toString() ?? '')
            .where((t) => t.isNotEmpty)
            .toList();

        entries.add(
          RemoteWorkshopEntry(
            publishedFileId: id,
            title:
                d['title']?.toString() ?? fallbackTitles[id] ?? '未命名作品 ($id)',
            description: d['description']?.toString() ?? '',
            tags: tags,
            fileSizeBytes: int.tryParse(d['file_size']?.toString() ?? '0') ?? 0,
            previewUrl:
                d['preview_url']?.toString() ?? fallbackPreviews[id] ?? '',
            timeCreated:
                int.tryParse(d['time_created']?.toString() ?? '0') ?? 0,
            timeUpdated:
                int.tryParse(d['time_updated']?.toString() ?? '0') ?? 0,
            views: int.tryParse(d['views']?.toString() ?? '0') ?? 0,
            subscriptions:
                int.tryParse(d['subscriptions']?.toString() ?? '0') ?? 0,
            favorites: int.tryParse(d['favorited']?.toString() ?? '0') ?? 0,
          ),
        );
      }
      onProgress?.call(entries.length, fileIds.length);
    }

    return entries;
  }

  /// 二次核验疑似消失的作品（调用 ISteamRemoteStorage/GetPublishedFileDetails）
  /// 返回 true 表示确认已删除/隐藏/下架；返回 false 表示仍存活或网络波动暂不判定
  Future<bool> confirmItemIsMissing(String publishedFileId) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/',
        data: {
          'itemcount': 1,
          'publishedfileids[0]': publishedFileId,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final details =
          response.data?['response']?['publishedfiledetails'] as List<dynamic>?;
      if (details == null || details.isEmpty) return false;

      final detail = details.first as Map<String, dynamic>;
      final int resultCode = detail['result'] as int? ?? 1;
      // result != 1 (如 result == 9 File Not Found) 或已被封禁/设为非公开
      if (resultCode != 1) return true;
      final int banned = detail['banned'] as int? ?? 0;
      final int visibility = detail['visibility'] as int? ?? 0;
      return banned != 0 || visibility != 0;
    } catch (_) {
      return false;
    }
  }

  /// Cache creator avatars separately from wallpaper previews.
  Future<String?> downloadCreatorAvatar(
      {required String steamId, String? avatarUrl}) async {
    final uri = Uri.tryParse(avatarUrl ?? '');
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        !RegExp(r'^\d{17}$').hasMatch(steamId)) {
      return null;
    }
    try {
      final response = await _dio.get<List<int>>(uri.toString(),
          options: Options(responseType: ResponseType.bytes));
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      final hash = sha256.convert(bytes).toString().substring(0, 12);
      final relative = p.join('avatars', '${steamId}_$hash.img');
      final file = File(p.join(dataRootDir, relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return relative;
    } catch (_) {
      return null;
    }
  }

  /// 下载预览图并按内容摘要归档，保留历史版本。
  Future<({String relativePath, String sha256Hash})?> downloadPreviewImage({
    required String creatorSteamId,
    required String publishedFileId,
    required String previewUrl,
  }) async {
    if (previewUrl.trim().isEmpty) return null;

    try {
      final response = await _retryRequest(
        () => _dio.get<List<int>>(
          previewUrl,
          options: Options(responseType: ResponseType.bytes),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;

      final hash = sha256.convert(bytes).toString();
      final shortHash = hash.substring(0, 8);

      final contentType =
          response.headers.value(Headers.contentTypeHeader) ?? '';
      String ext = 'jpg';
      if (contentType.contains('gif')) {
        ext = 'gif';
      } else if (contentType.contains('png')) {
        ext = 'png';
      } else if (contentType.contains('webp')) {
        ext = 'webp';
      }

      final relDir = p.join('previews', creatorSteamId);
      final absDir = Directory(p.join(dataRootDir, relDir));
      if (!await absDir.exists()) {
        await absDir.create(recursive: true);
      }

      final fileName = '${publishedFileId}_$shortHash.$ext';
      final relPath = p.join(relDir, fileName);
      final absFile = File(p.join(dataRootDir, relPath));

      if (!await absFile.exists()) {
        await absFile.writeAsBytes(bytes, flush: true);
      }

      return (relativePath: relPath, sha256Hash: hash);
    } catch (_) {
      return null;
    }
  }

  /// 指数退避重试包装器（应对 Steam 429 限流或瞬时网络抖动）
  Future<T> _retryRequest<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
  }) async {
    int attempt = 0;
    while (true) {
      try {
        attempt++;
        return await action();
      } catch (e) {
        if (e is DioException) {
          final status = e.response?.statusCode;
          if (status != null &&
              status >= 400 &&
              status < 500 &&
              status != 429) {
            rethrow;
          }
        }
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(
            Duration(milliseconds: 800 * (1 << attempt)));
      }
    }
  }
}
