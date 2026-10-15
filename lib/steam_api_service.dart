import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'workshop_models.dart';

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

/// Steam 创意工坊双通道采集与预览图并发归档服务
/// - 主通道：Steamworks Web API (IPublishedFileService/GetUserFiles)
/// - 备用免 Key 通道：Steam 社区创意工坊网页 HTML DOM 解析
/// - 防误报核验通道：ISteamRemoteStorage/GetPublishedFileDetails
class SteamWorkshopService {
  final Dio _dio;
  final String dataRootDir;

  SteamWorkshopService({required this.dataRootDir, Dio? dio})
      : _dio = dio ??
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
      resolveCreatorIdentity({
    required String rawInput,
    required String apiKey,
  }) async {
    final parsed = SteamInputParser.parseCreatorInput(rawInput);
    String? steamId64 = parsed.steamId64;

    // 若用户输入的是自定义个性域名 (如 /id/xxx)，先解析出 64 位 SteamID
    if (steamId64 == null && parsed.vanityName != null) {
      if (apiKey.trim().isNotEmpty) {
        final resp = await _dio.get<Map<String, dynamic>>(
          'https://api.steampowered.com/ISteamUser/ResolveVanityURL/v1/',
          queryParameters: {
            'key': apiKey.trim(),
            'vanityurl': parsed.vanityName,
          },
        );
        final body = resp.data?['response'] as Map<String, dynamic>? ?? {};
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
        final summaryResp = await _dio.get<Map<String, dynamic>>(
          'https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/',
          queryParameters: {
            'key': apiKey.trim(),
            'steamids': steamId64,
          },
        );
        final players = summaryResp.data?['response']?['players']
            as List<dynamic>?;
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
      final nameMatch =
          RegExp(r'<steamID><!\[CDATA\[(.*?)\]\]></steamID>').firstMatch(rawXml);
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

  /// 拉取创作者在 Wallpaper Engine (AppID=431960) 下的全部公开作品
  /// 若已配置 API Key 则走官方 IPublishedFileService；未配置则自动降级走 HTML DOM 解析
  Future<List<RemoteWorkshopEntry>> fetchAllCreatorItems({
    required String steamId,
    required String apiKey,
    void Function(int fetched, int total)? onProgress,
  }) async {
    if (apiKey.trim().isNotEmpty) {
      return _fetchViaSteamWebApi(
        steamId: steamId,
        apiKey: apiKey.trim(),
        onProgress: onProgress,
      );
    } else {
      return _fetchViaHtmlFallback(
        steamId: steamId,
        onProgress: onProgress,
      );
    }
  }

  /// 主通道：通过 Steamworks Web API (IPublishedFileService/GetUserFiles/v1) 分页获取
  Future<List<RemoteWorkshopEntry>> _fetchViaSteamWebApi({
    required String steamId,
    required String apiKey,
    void Function(int fetched, int total)? onProgress,
  }) async {
    final results = <String, RemoteWorkshopEntry>{};
    int page = 1;
    const int numPerPage = 100;
    int totalExpected = 0;

    while (true) {
      final response = await _retryRequest(
        () => _dio.get<Map<String, dynamic>>(
          'https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/',
          queryParameters: {
            'key': apiKey,
            'steamid': steamId,
            'appid': kWallpaperEngineAppId,
            'page': page,
            'numperpage': numPerPage,
            'return_tags': true,
            'return_previews': true,
          },
        ),
      );

      final respBody = response.data?['response'] as Map<String, dynamic>? ?? {};
      totalExpected = respBody['total'] as int? ?? 0;
      final details = respBody['publishedfiledetails'] as List<dynamic>? ?? [];

      if (details.isEmpty) break;

      for (final raw in details) {
        final item = raw as Map<String, dynamic>;
        final id = item['publishedfileid']?.toString() ?? '';
        if (id.isEmpty) continue;

        final rawTags = item['tags'] as List<dynamic>? ?? [];
        final tags = rawTags
            .map((t) => (t as Map<String, dynamic>)['tag']?.toString() ?? '')
            .where((t) => t.isNotEmpty)
            .toList();

        results[id] = RemoteWorkshopEntry(
          publishedFileId: id,
          title: item['title']?.toString() ?? '未命名作品 ($id)',
          description: item['file_description']?.toString() ?? '',
          tags: tags,
          fileSizeBytes: int.tryParse(item['file_size']?.toString() ?? '0') ?? 0,
          previewUrl: item['preview_url']?.toString() ?? '',
          timeCreated: int.tryParse(item['time_created']?.toString() ?? '0') ?? 0,
          timeUpdated: int.tryParse(item['time_updated']?.toString() ?? '0') ?? 0,
          views: int.tryParse(item['views']?.toString() ?? '0') ?? 0,
          subscriptions:
              int.tryParse(item['subscriptions']?.toString() ?? '0') ?? 0,
          favorites: int.tryParse(item['favorited']?.toString() ?? '0') ?? 0,
        );
      }

      onProgress?.call(results.length, totalExpected);
      if (results.length >= totalExpected || details.length < numPerPage) {
        break;
      }
      page++;
    }

    return results.values.toList();
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
      if (itemElements.isEmpty) break;

      int newInPage = 0;
      for (final el in itemElements) {
        final ugcLink = el.querySelector('a.ugc');
        final id = ugcLink?.attributes['data-publishedfileid'] ?? '';
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
      if (newInPage == 0 || itemElements.length < 30) break;
      page++;
    }

    if (discoveredIds.isEmpty) return [];

    // 使用无需 API Key 的公开接口 ISteamRemoteStorage/GetPublishedFileDetails/v1 批量补全详情
    return _fetchBatchDetailsPublicApi(
      discoveredIds,
      fallbackTitles: fallbackTitles,
      fallbackPreviews: fallbackPreviews,
    );
  }

  /// 批量调用无需 API Key 的 GetPublishedFileDetails 接口补全元数据
  Future<List<RemoteWorkshopEntry>> _fetchBatchDetailsPublicApi(
    List<String> fileIds, {
    required Map<String, String> fallbackTitles,
    required Map<String, String> fallbackPreviews,
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
      for (final raw in details) {
        final d = raw as Map<String, dynamic>;
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
            title: d['title']?.toString() ??
                fallbackTitles[id] ??
                '未命名作品 ($id)',
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

      final details = response.data?['response']?['publishedfiledetails']
          as List<dynamic>?;
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

  /// 下载预览图并按 {publishedFileId}_{sha256前8位}.{ext} 归档（保留所有历史版本封面）
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
        if (attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 * (1 << attempt)));
      }
    }
  }
}
