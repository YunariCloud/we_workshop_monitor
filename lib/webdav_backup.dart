import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'backup_service.dart';
import 'workshop_database.dart';
import 'workshop_models.dart';

class WebDavBackupClient {
  final Dio _dio;
  WebDavBackupClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(minutes: 2),
                sendTimeout: const Duration(minutes: 15)));

  void validateSettings(AppSettings settings) {
    _base(settings);
    _folder(settings);
  }

  Uri _base(AppSettings settings) {
    final uri = Uri.tryParse(settings.webdavUrl.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请填写有效的 WebDAV 目录地址，账号和密码请单独填写');
    }
    return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
  }

  List<String> _folder(AppSettings settings) {
    final parts = settings.webdavFolder
        .trim()
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts
        .any((part) => part == '.' || part == '..' || part.contains('\\'))) {
      throw const FormatException('远程目录不能包含上级目录或反斜杠');
    }
    return parts;
  }

  Uri _child(Uri base, String name, {bool collection = false}) =>
      base.replace(pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        name,
        if (collection) ''
      ]);

  Future<Response<String>> _request(
      AppSettings settings, Uri uri, String method,
      {Object? data,
      Map<String, Object>? headers,
      ProgressCallback? onProgress}) async {
    try {
      final response = await _dio.request<String>(uri.toString(),
          data: data,
          options: Options(
              method: method,
              responseType: ResponseType.plain,
              followRedirects: false,
              validateStatus: (_) => true,
              headers: {
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('${settings.webdavUsername}:${settings.webdavPassword}'))}',
                ...?headers
              }),
          onSendProgress: onProgress);
      if ([401, 403].contains(response.statusCode)) {
        throw const FormatException('WebDAV 账号、密码或访问权限不正确');
      }
      return response;
    } on DioException {
      // Never expose request options, Authorization, or server response bodies.
      throw const FormatException('WebDAV 连接或传输失败，请检查网络和服务地址');
    }
  }

  Future<void> _collection(AppSettings settings, Uri uri) async {
    final response = await _request(settings, uri, 'PROPFIND',
        headers: {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8'
        },
        data:
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>');
    if (response.statusCode != 207 ||
        !RegExp(r'<(?:[\w-]+:)?collection(?:\s|/|>)')
            .hasMatch(response.data ?? '')) {
      throw const FormatException('无法访问 WebDAV 目录，请检查目录地址及服务器支持');
    }
  }

  /// Read-only connection check. Actual write permission is checked on upload.
  Future<void> testConnection(AppSettings settings) async {
    _folder(settings);
    await _collection(settings, _base(settings));
  }

  Future<Uri> upload(AppSettings settings, File archive,
      {ProgressCallback? onProgress}) async {
    var directory = _base(settings);
    await _collection(settings, directory);
    for (final segment in _folder(settings)) {
      directory = _child(directory, segment, collection: true);
      final result = await _request(settings, directory, 'MKCOL');
      if (result.statusCode == 405) {
        await _collection(settings, directory);
      } else if (result.statusCode != 201) {
        throw const FormatException('WebDAV 远程目录创建失败，请检查写入权限');
      }
    }
    final destination = _child(directory, p.basename(archive.path));
    final pending = _child(directory,
        '.uploading-${DateTime.now().toUtc().microsecondsSinceEpoch}.zip');
    try {
      final put = await _request(settings, pending, 'PUT',
          data: archive.openRead(),
          headers: {
            'Content-Type': 'application/zip',
            'Content-Length': await archive.length()
          },
          onProgress: onProgress);
      if (![200, 201, 204].contains(put.statusCode)) {
        throw const FormatException('WebDAV 文件上传失败');
      }
      final move = await _request(settings, pending, 'MOVE',
          headers: {'Destination': destination.toString(), 'Overwrite': 'F'});
      if (![201, 204].contains(move.statusCode)) {
        throw const FormatException('WebDAV 无法完成备份，请确认服务器支持 MOVE 且允许写入');
      }
      return destination;
    } catch (_) {
      try {
        await _request(settings, pending, 'DELETE');
      } catch (_) {}
      rethrow;
    }
  }
}

Future<Uri> runWebDavBackup(
    {required WorkshopDatabase database,
    required BackupService backups,
    required AppSettings settings,
    WebDavBackupClient? client,
    ProgressCallback? onProgress}) async {
  final workRoot = Directory(p.join(database.dataRootDir, 'backup_work'));
  await workRoot.create(recursive: true);
  final temporary = await workRoot.createTemp('cloud-');
  try {
    final archive = await backups.runLocalZipBackup(
        targetBackupDir: temporary.path,
        lightweight: settings.webdavLightweight,
        recordBackup: false);
    final destination = await (client ?? WebDavBackupClient())
        .upload(settings, archive, onProgress: onProgress);
    await database.insertBackupRecord(BackupRecord(
        targetType: 'WEBDAV',
        backupMode: settings.webdavLightweight ? 'LIGHTWEIGHT_ZIP' : 'FULL_ZIP',
        location: destination.toString(),
        fileSizeBytes: await archive.length(),
        status: 'SUCCESS',
        createdAt: DateTime.now().toUtc()));
    return destination;
  } finally {
    if (!p.isWithin(p.normalize(workRoot.absolute.path),
        p.normalize(temporary.absolute.path))) {
      throw StateError('Invalid cloud staging directory');
    }
    if (await temporary.exists()) await temporary.delete(recursive: true);
  }
}
