import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// A null result means the native source is not installed on this machine.
/// A connected source must return a complete list or throw, never silently
/// downgrade to a smaller website result after a failed native query.
abstract interface class SteamPublishedFileSource {
  Future<List<String>?> fetchPublishedIds({
    required String steamId,
    void Function(int fetched, int total)? onProgress,
  });
}

final class _QueryCompleted extends Struct {
  @Uint64()
  external int handle;
  @Int32()
  external int result;
  @Uint32()
  external int returned;
  @Uint32()
  external int total;
  @Bool()
  external bool cached;
  @Array(256)
  external Array<Uint8> nextCursor;
}

/// Uses the user's installed Steamworks library, without copying it into the
/// app or reading login tokens. Only Published-list read operations are exposed.
class SteamClientWorkshopSource implements SteamPublishedFileSource {
  final Future<String?> Function()? libraryLocator;
  SteamClientWorkshopSource({this.libraryLocator});

  // SteamAPI is process-global. Serialize foreground and scheduled queries.
  static Future<void> _queue = Future<void>.value();

  @override
  Future<List<String>?> fetchPublishedIds({
    required String steamId,
    void Function(int fetched, int total)? onProgress,
  }) async {
    if (!Platform.isWindows) return null;
    final previous = _queue;
    final finished = Completer<void>();
    _queue = finished.future;
    await previous;
    try {
      final library = await (libraryLocator ?? _locateLibrary)();
      if (library == null) return null;
      if (!RegExp(r'^\d{17}$').hasMatch(steamId)) {
        throw const FormatException('无效的 SteamID64');
      }
      final bindings = _Bindings(DynamicLibrary.open(library));
      return await _fetch(bindings, steamId, onProgress);
    } finally {
      finished.complete();
    }
  }

  Future<List<String>> _fetch(_Bindings api, String steamId,
      void Function(int, int)? onProgress) async {
    final error = calloc<Uint8>(1024);
    var initialized = false;
    // Scope AppID changes to initialization and restore the process environment.
    final oldAppId = Platform.environment['SteamAppId'];
    final oldGameId = Platform.environment['SteamGameId'];
    try {
      try {
        _setEnvironment('SteamAppId', '431960');
        _setEnvironment('SteamGameId', '431960');
        initialized = api.init(error.cast<Utf8>()) == 0;
      } finally {
        _setEnvironment('SteamAppId', oldAppId);
        _setEnvironment('SteamGameId', oldGameId);
      }
      if (!initialized) {
        throw Exception(
            '无法连接 Steam 客户端，请启动 Steam 并登录拥有 Wallpaper Engine 的账号后重试。'
            '为避免漏抓，本次不会改用网页的部分结果。');
      }
      final ugc = api.getUgc();
      final utils = api.getUtils();
      if (ugc == nullptr || utils == nullptr) {
        throw Exception('Steam 创意工坊接口不可用，请更新 Steam 和 Wallpaper Engine');
      }
      final ids = <String>{};
      int? expectedTotal;
      for (var page = 1;; page++) {
        // Published=0, All=-1, CreationOrderDesc=0. This is NOT Favorites=5.
        final handle = api.createQuery(
            ugc,
            (BigInt.parse(steamId) & BigInt.from(0xffffffff)).toInt(),
            0,
            -1,
            0,
            0,
            431960,
            page);
        if (handle == -1 || handle == 0) {
          throw Exception('Steam 未能创建作者作品查询');
        }
        try {
          if (!api.onlyIds(ugc, handle, true)) {
            throw Exception('Steam 未能配置作者作品查询');
          }
          final call = api.sendQuery(ugc, handle);
          if (call == 0) throw Exception('Steam 未能提交作者作品查询');
          final result = calloc<_QueryCompleted>();
          final failed = calloc<Bool>();
          // SteamUGCDetails_t begins with PublishedFileId_t. Reserve more than
          // its documented size and only read that field with ReturnOnlyIDs.
          final item = calloc<Uint8>(65536);
          try {
            final timer = Stopwatch()..start();
            while (true) {
              api.runCallbacks();
              if (api.isCompleted(utils, call, failed)) break;
              if (timer.elapsed > const Duration(seconds: 30)) {
                throw TimeoutException('Steam 作者作品查询超时，请检查客户端连接');
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            if (failed.value ||
                !api.getCallResult(utils, call, result.cast<Void>(),
                    sizeOf<_QueryCompleted>(), 3401, failed) ||
                failed.value ||
                result.ref.result != 1 ||
                result.ref.handle != handle ||
                result.ref.returned > 50) {
              throw Exception('Steam 未返回有效的作者作品列表，本次同步已停止');
            }
            expectedTotal ??= result.ref.total;
            if (result.ref.total != expectedTotal) {
              throw Exception('同步期间作者作品数量发生变化，请重新同步以获取完整列表');
            }
            final beforePage = ids.length;
            for (var i = 0; i < result.ref.returned; i++) {
              if (!api.getItem(ugc, handle, i, item.cast<Void>())) {
                throw Exception('Steam 作品列表读取不完整，请重新同步');
              }
              final id = item.cast<Uint64>().value;
              if (id == 0) throw Exception('Steam 返回了无效的作品 ID');
              ids.add('$id');
            }
            onProgress?.call(ids.length, expectedTotal);
            if (ids.length == expectedTotal) return ids.toList();
            if (ids.length > expectedTotal ||
                ids.length == beforePage ||
                result.ref.returned == 0) {
              throw Exception('Steam 作者作品分页不完整，本次不会使用部分结果');
            }
          } finally {
            calloc.free(item);
            calloc.free(failed);
            calloc.free(result);
          }
        } finally {
          api.releaseQuery(ugc, handle);
        }
      }
    } finally {
      if (initialized) api.shutdown();
      calloc.free(error);
    }
  }

  static Future<String?> _locateLibrary() async {
    final roots = <String>{};
    try {
      final registry = await Process.run(
          'reg.exe', ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamPath'],
          stdoutEncoding: systemEncoding, stderrEncoding: systemEncoding);
      if (registry.exitCode == 0) {
        final match = RegExp(r'SteamPath\s+REG_SZ\s+(.+)', caseSensitive: false)
            .firstMatch(registry.stdout.toString());
        if (match != null) roots.add(match.group(1)!.trim());
      }
    } on ProcessException {
      // Standard install locations still work if registry access is unavailable.
    }
    for (final variable in ['ProgramFiles(x86)', 'ProgramFiles']) {
      final base = Platform.environment[variable];
      if (base != null) roots.add(p.join(base, 'Steam'));
    }
    for (final root in roots.toList()) {
      final folders = File(p.join(root, 'steamapps', 'libraryfolders.vdf'));
      if (!await folders.exists()) continue;
      final text = await folders.readAsString();
      for (final match in RegExp(r'"path"\s+"([^"]+)"').allMatches(text)) {
        roots.add(match.group(1)!.replaceAll(r'\\', r'\'));
      }
    }
    for (final root in roots) {
      final manifest =
          File(p.join(root, 'steamapps', 'appmanifest_431960.acf'));
      if (!await manifest.exists()) continue;
      final name = RegExp(r'"installdir"\s+"([^"]+)"')
          .firstMatch(await manifest.readAsString())
          ?.group(1);
      if (name == null || name.contains('..') || p.isAbsolute(name)) continue;
      final library = File(
          p.join(root, 'steamapps', 'common', name, 'bin', 'steam_api64.dll'));
      if (await library.exists()) return library.path;
    }
    return null;
  }

  static void _setEnvironment(String name, String? value) {
    final set = DynamicLibrary.open('kernel32.dll').lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(
            Pointer<Utf16>, Pointer<Utf16>)>('SetEnvironmentVariableW');
    final key = name.toNativeUtf16();
    final text = value?.toNativeUtf16() ?? nullptr;
    try {
      if (set(key, text) == 0) throw Exception('无法配置 Steam 客户端查询环境');
    } finally {
      calloc.free(key);
      if (text != nullptr) calloc.free(text);
    }
  }
}

class _Bindings {
  final DynamicLibrary library;
  _Bindings(this.library);

  late final init = library.lookupFunction<Int32 Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)>('SteamAPI_InitFlat');
  late final shutdown = library
      .lookupFunction<Void Function(), void Function()>('SteamAPI_Shutdown');
  late final runCallbacks =
      library.lookupFunction<Void Function(), void Function()>(
          'SteamAPI_RunCallbacks');
  late final getUgc = _ugcGetter();
  Pointer<Void> Function() _ugcGetter() {
    for (final version in ['021', '020', '019', '018', '017', '016']) {
      try {
        return library.lookupFunction<Pointer<Void> Function(),
            Pointer<Void> Function()>('SteamAPI_SteamUGC_v$version');
      } on ArgumentError {
        continue;
      }
    }
    throw Exception('Wallpaper Engine 的 Steam 接口版本不兼容，请更新后重试');
  }

  late final getUtils = library.lookupFunction<Pointer<Void> Function(),
      Pointer<Void> Function()>('SteamAPI_SteamUtils_v010');
  late final createQuery = library.lookupFunction<
      Uint64 Function(
          Pointer<Void>, Uint32, Int32, Int32, Int32, Uint32, Uint32, Uint32),
      int Function(Pointer<Void>, int, int, int, int, int, int,
          int)>('SteamAPI_ISteamUGC_CreateQueryUserUGCRequest');
  late final onlyIds = library.lookupFunction<
      Bool Function(Pointer<Void>, Uint64, Bool),
      bool Function(
          Pointer<Void>, int, bool)>('SteamAPI_ISteamUGC_SetReturnOnlyIDs');
  late final sendQuery = library.lookupFunction<
      Uint64 Function(Pointer<Void>, Uint64),
      int Function(
          Pointer<Void>, int)>('SteamAPI_ISteamUGC_SendQueryUGCRequest');
  late final isCompleted = library.lookupFunction<
      Bool Function(Pointer<Void>, Uint64, Pointer<Bool>),
      bool Function(Pointer<Void>, int,
          Pointer<Bool>)>('SteamAPI_ISteamUtils_IsAPICallCompleted');
  late final getCallResult = library.lookupFunction<
      Bool Function(
          Pointer<Void>, Uint64, Pointer<Void>, Int32, Int32, Pointer<Bool>),
      bool Function(Pointer<Void>, int, Pointer<Void>, int, int,
          Pointer<Bool>)>('SteamAPI_ISteamUtils_GetAPICallResult');
  late final getItem = library.lookupFunction<
      Bool Function(Pointer<Void>, Uint64, Uint32, Pointer<Void>),
      bool Function(Pointer<Void>, int, int,
          Pointer<Void>)>('SteamAPI_ISteamUGC_GetQueryUGCResult');
  late final releaseQuery = library.lookupFunction<
      Bool Function(Pointer<Void>, Uint64),
      bool Function(
          Pointer<Void>, int)>('SteamAPI_ISteamUGC_ReleaseQueryUGCRequest');
}
