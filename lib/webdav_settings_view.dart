import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'webdav_backup.dart';
import 'workspace_widgets.dart';
import 'workshop_models.dart';

class WebDavSettingsView extends StatefulWidget {
  final AppSettings settings;
  final Future<void> Function(AppSettings) onSave;
  final Future<void> Function(AppSettings, void Function(int, int)) onBackup;
  const WebDavSettingsView(
      {super.key,
      required this.settings,
      required this.onSave,
      required this.onBackup});
  @override
  State<WebDavSettingsView> createState() => _WebDavSettingsViewState();
}

class _WebDavSettingsViewState extends State<WebDavSettingsView> {
  late final _url = TextEditingController(text: widget.settings.webdavUrl);
  late final _username =
      TextEditingController(text: widget.settings.webdavUsername);
  late final _password =
      TextEditingController(text: widget.settings.webdavPassword);
  late final _folder =
      TextEditingController(text: widget.settings.webdavFolder);
  late bool _lightweight = widget.settings.webdavLightweight;
  late bool _enabled = widget.settings.webdavEnabled;
  bool _busy = false;
  bool _obscure = true;
  bool _failed = false;
  String? _result;

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _run(String action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
      _result = action == 'backup' ? '正在生成备份…' : null;
    });
    try {
      final settings = widget.settings.copyWith(
          webdavUrl: _url.text.trim(),
          webdavUsername: _username.text.trim(),
          webdavPassword: _password.text,
          webdavFolder: _folder.text.trim(),
          webdavLightweight: _lightweight,
          webdavEnabled: _enabled);
      final client = WebDavBackupClient();
      client.validateSettings(settings);
      await widget.onSave(settings);
      if (action == 'test') {
        await client.testConnection(settings);
      } else if (action == 'backup') {
        await widget.onBackup(settings, (sent, total) {
          if (mounted) {
            setState(() => _result =
                total > 0 ? '正在上传 ${(sent * 100 / total).floor()}%' : '正在上传…');
          }
        });
      }
      if (mounted) {
        setState(() => _result = action == 'backup'
            ? '云端备份已完成'
            : action == 'test'
                ? '连接成功，目录可访问；写入权限会在备份时验证。'
                : '设置已保存');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _result =
              error is FormatException ? error.message : '操作未完成，请检查备份设置或稍后重试';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(28), children: [
        WorkspaceSurface(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              const Text('WebDAV 云端备份',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 20),
              TextField(
                  controller: _url,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'WebDAV 目录地址',
                      hintText: 'https://example.com/dav/')),
              const SizedBox(height: 16),
              TextField(
                  controller: _username,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: '账号')),
              const SizedBox(height: 16),
              TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                      labelText: '密码 / 应用密码',
                      suffixIcon: IconButton(
                          tooltip: _obscure ? '显示 WebDAV 密码' : '隐藏 WebDAV 密码',
                          onPressed: () => setState(() => _obscure = !_obscure),
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined)))),
              const SizedBox(height: 16),
              TextField(
                  controller: _folder,
                  enabled: !_busy,
                  decoration: const InputDecoration(labelText: '远程备份文件夹')),
              const SizedBox(height: 24),
              SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, label: Text('轻量备份')),
                    ButtonSegment(value: false, label: Text('原图备份'))
                  ],
                  selected: {_lightweight},
                  onSelectionChanged: _busy
                      ? null
                      : (values) =>
                          setState(() => _lightweight = values.single)),
              const SizedBox(height: 16),
              Text(
                  _lightweight
                      ? '云端默认使用轻量备份：动图转为静态封面，最长边 1280px。作品信息与时间线完整保留，本机原图不变。'
                      : '原图备份会保留动图，文件较大，上传耗时也会增加。',
                  style: TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: AppPalette.textSecondary)),
              const SizedBox(height: 8),
              Text('云端备份包含全部作品，不受资料库分级筛选影响。密码保存在系统安全存储中。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: AppPalette.textSecondary)),
              const SizedBox(height: 12),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('参与变更后自动备份'),
                  subtitle: const Text('同时需要在查询与同步中开启自动备份'),
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value)),
              const SizedBox(height: 16),
              Wrap(spacing: 12, runSpacing: 12, children: [
                FilledButton(
                    onPressed: _busy ? null : () => _run('backup'),
                    child: const Text('立即备份到云端')),
                OutlinedButton(
                    onPressed: _busy ? null : () => _run('test'),
                    child: const Text('测试连接')),
                TextButton(
                    onPressed: _busy ? null : () => _run('save'),
                    child: const Text('保存设置')),
              ]),
              if (_busy)
                const Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: LinearProgressIndicator()),
              if (_result != null)
                Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_result!,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: _failed
                                ? AppPalette.statusMissing
                                : AppPalette.textSecondary))),
            ])),
      ]);
}
