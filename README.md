# WE Workshop Monitor

Wallpaper Engine 创意工坊创作者监测与归档桌面客户端。

为关注的创作者建立作品档案，追踪新增、修改、消失和重新公开的作品。即使作品以后无法访问，也能查看此前已保存的标题、简介、标签与预览图，并将档案备份到本地目录或 WebDAV 云端。

> 归档范围是作品元数据和预览图，不包含壁纸源文件、视频或 `.pkg` 文件，也无法找回首次建档前已经消失的作品。

## 功能

- **创作者监测**：支持从壁纸作品链接、作品 ID 或 Steam 客户端作品链接识别作者，也可通过 SteamID64、`/profiles/` 链接或 `/id/` 个性主页添加。首次同步建立基线档案，重复添加会提示。
- **内容分级**：按安全、存疑、成人、未分级筛选；作品资料库每次启动默认只显示安全内容，变更记录、同步和备份不受分级筛选影响。
- **作者头像**：获取并缓存 Steam 头像，支持手动更新和随档案备份。
- **自适应布局**：小窗口使用紧凑导航，统计卡片、创作者操作、画廊筛选和设置分栏随可用宽度调整。
- **增量追踪**：记录新增、修改、消失和恢复事件；对疑似消失的作品调用详情接口再次核验。
- **作品画廊**：按创作者、关键词与作品状态筛选，支持查看已消失作品及曾修改的作品。
- **历史对比**：保留字段变更记录和已下载的历史预览图，先按创作者查看同步汇总，再进入作品的独立时间线，详细字段变化按需打开。
- **定时同步**：支持手动同步，或每 2、6、12、24 小时轮询；默认每 6 小时检查一次。进度只在对应创作者行显示已处理数 / 总数，不显示顶部状态条。
- **轻量备份**：默认将动图转为静态封面、最长边 1280px，优先 JPEG 质量 80，GIF 首帧在更小时使用 PNG；完整保留作品信息、历史记录与所有有效历史封面，不改动本机原图。也可切换原图备份。
- **本地备份**：生成 ZIP、轮转保留历史归档，或将数据库快照和预览图同步到镜像目录。轻量镜像位于目标目录的 `lightweight/` 子目录。
- **WebDAV 云端备份**：独立设置服务器目录、账号、应用密码和子文件夹，默认轻量备份并显示说明；支持连接测试、手动上传，以及参与变更后自动备份。

## 快速开始（Windows）

### 1. 准备环境

需要 Flutter SDK，以及安装了“使用 C++ 的桌面开发”工作负载和 Windows SDK 的 Visual Studio。

本项目已在 **Windows 10 x64、Flutter 3.38.5 / Dart 3.10.4、Visual Studio 2026** 环境完成静态检查、发布版构建与启动验证。建议使用相同的 Flutter 版本复现构建；仓库已提交 `pubspec.lock`。

检查 Windows 编译环境：

```powershell
flutter doctor -v
```

### 2. 下载并启动

```powershell
git clone https://github.com/YunariCloud/we_workshop_monitor.git
cd we_workshop_monitor
flutter pub get
flutter run -d windows
```

仓库已包含 `windows/` 宿主工程，无需再次执行 `flutter create`。

### 3. 首次使用

1. 在创作者监测页面点击“添加创作者”，默认从壁纸识别：粘贴 Wallpaper Engine 壁纸的创意工坊作品链接或作品 ID。也可以切换到“通过作者添加”，粘贴 SteamID64 或 Steam 主页链接。
2. 执行首次同步，等待作品列表及预览图建档完成。
3. 在作品画廊和变更时间轴查看档案；之后的同步会与本地记录比对。
4. 在设置中心选择轮询间隔，配置本地备份或 WebDAV 云端备份。

在“设置与备份 → 作品查询”选择请求方式：

- **自动选择**：填写 Key 后优先使用 Web API；否则尝试本机 Steam 客户端，未找到客户端源时再使用公开网页。
- **Web API Key**：直接调用认证接口，无需启动或登录 Steam 客户端。填入 Key 后点击“保存并测试”，只请求第一位已添加创作者的 1 条作品进行验证，不全量查询、不导入作品；没有作品时会显示已验证 0 条。
- **Steam 客户端**：需要安装 Wallpaper Engine，并使用 Steam 登录状态查询作品列表。
- **公开网页**：无需 Key 或客户端，但结果可能受网页可见性筛选限制。

显式选择的查询方式失败时不会自动换成另一种来源。本次验证账号的 API 返回 456 条、客户端返回 457 条、公开网页返回 30 条；不同来源的可见作品集合存在差异，不能直接将未列出的作品当作下架。认证接口会请求完整描述，不用匿名详情接口覆盖认证结果。Key 保存在系统安全存储中，不写入配置 JSON。

侧栏底部可以切换浅色 / 深色外观，选择会自动保存。界面参考见 [设计说明](docs/design-notes.md)。

作者隐藏个人主页时，可以尝试从其公开壁纸识别作者；昵称不可读取时可填写备注。识别成功不代表全部作品一定可读取。若列表因隐私、访问限制或页面变化无法解析，同步会停止并保留现有档案状态，不会将失败结果作为空列表。网页采集按实际翻页链接获取，兼容 Steam 每页返回条数少于请求值的情况。

## 构建与分发

在项目根目录执行：

```powershell
flutter build windows --release
```

构建输出：

```text
build/windows/x64/runner/Release/
├── we_workshop_monitor.exe
├── data/
└── *.dll
```

双击 `we_workshop_monitor.exe` 启动。分发时请打包整个 `Release` 文件夹，保留所有 DLL 和 `data/`，不能只复制 EXE。

当前仓库提供源码；上述命令用于自行构建桌面客户端。

## 数据与备份

数据保存在系统应用支持目录下的 `we_workshop_monitor/` 子目录中，具体位置由 `path_provider` 确定。Windows 默认宿主标识下通常位于：

```text
%APPDATA%/com.example/we_workshop_monitor/we_workshop_monitor/
├── workshop_monitor.db
├── previews/
└── backup_staging/
```

Steam API Key通过 `flutter_secure_storage` 保存；其他设置存入本地 SQLite 数据库。

| 方式 | 内容与用途 |
| --- | --- |
| 本地 ZIP | 默认轻量，可选原图；数据库快照、头像、有效历史封面及导出清单；默认最多保留 10 份 |
| 本地镜像 | 更新快照和报表，复制新增封面；轻量版本使用独立子目录 |
| WebDAV | 默认轻量 ZIP；先上传临时文件，成功后原子改名，避免将半份文件当作完整备份 |

备份导出包含创作者汇总、作品 JSON、消失作品 CSV，以及带数据库 SHA-256 的清单。自动备份在同步发现变更后触发，需要开启“变更后自动备份”，并设置本地目标目录或在 WebDAV 页面开启“参与变更后自动备份”。云端连接测试只确认目录可访问，实际写权限在上传时验证。服务器须支持 PROPFIND、MKCOL、PUT、MOVE，建议使用 HTTPS。

轻量模式只打包数据库和历史记录仍引用的封面；无法转换的图片会保留原文件，不会静默丢失封面。本机原始缓存不变。备份副本中的图片路径、摘要和导出清单会同步更新，清单包含新的数据库校验值。资料库分级筛选不影响任何备份。

WebDAV 密码与 Steam API Key 保存在系统安全存储中，不进入配置 JSON、数据库快照、日志或发布包。填写服务器地址时不要将账号、密码嵌入 URL。不要把不可信的重定向地址当作服务器。

当前尚未提供本地 ZIP 的图形化导入入口。

旧版本曾因更新创作者时触发关联删除，出现“计数非零但作品表为空”。新版会在启动时识别该状态并改为等待首次建档；重启后再次同步即可重新归档当前可访问作品。后续更新会保留作品和历史记录。缺失的本地预览图会在同步时重试下载，画廊也支持远程预览图回退。

## 项目结构

```text
lib/
├── main.dart                    # Material 3 桌面界面与配置入口
├── app_theme.dart               # 浅色 / 深色主题
├── workshop_preview.dart        # 本地与远程预览图回退
├── steam_client_source.dart     # Steam 客户端作品查询
├── workshop_models.dart         # 领域模型、设置与 Steam 输入解析
├── workshop_database.dart       # SQLite 持久化、检索与快照恢复
├── steam_api_service.dart       # Steam API、网页解析与预览图下载
├── diff_engine.dart             # 基线建档与增量变更比对
├── backup_service.dart          # 本地 ZIP / 镜像备份
└── scheduler_tray_service.dart  # 定时轮询、窗口与托盘集成
windows/                        # Windows 原生宿主
pubspec.yaml                    # 依赖与 SQLite 加载配置
pubspec.lock                    # 已解析的依赖版本
```

主要技术：Flutter / Dart、Material 3、SQLite FFI、Dio、HTML 解析、`archive`、`flutter_secure_storage`、`window_manager` 和 `tray_manager`。

SQLite 由 `sqlite3_flutter_libs` 编译并随应用打包。`pubspec.yaml` 的 hooks 配置让 `sqlite3` 加载该动态库，避免重复下载另一份 GitHub 二进制文件。

## 开发与验证

```powershell
flutter pub get
flutter analyze
flutter build windows --release
flutter test
```

自动化测试覆盖浅色 / 深色布局、查询方式、API 分页与错误脱敏，以及真实 SQLite 数据库中的连续同步、历史记录保留、旧档案修复、封面重试、ZIP 内容和本地镜像。Windows 数据库集成测试使用应用打包的 SQLite DLL，因此首次运行测试前先完成一次 Windows 构建。

Steam 联网测试默认跳过，需在可用客户端或自有 API Key 的环境下显式开启；不要将 Key 写入代码或提交到仓库。

## 已知限制

- 当前仅包含 Windows 宿主工程。macOS 和 Linux 需要补齐平台工程并分别验证，尚未提供对应构建。
- 网页解析依赖 Steam 页面结构；网络波动、访问限制、限流或页面改版都可能影响同步。作品“消失”表示采集时不可公开访问，不能据此确定删除原因。
- 后台轮询依赖客户端持续运行；退出程序或电脑休眠期间不会执行检查。
- 托盘菜单已有代码，但尚未设置托盘图标。建议在设置中关闭“关闭窗口时最小化驻留系统托盘”，避免关闭窗口后缺少可见的恢复入口。
- 预览图历史保留会持续占用磁盘空间；本地 ZIP 的份数轮转不会清理原始预览图历史。

反馈问题时，请附上系统版本、`flutter --version`、复现步骤和错误信息；分享日志前请移除 API Key 等凭据。

## Windows 发布包

使用 PowerShell 7 运行：

```powershell
pwsh -File scripts/package_windows.ps1
```

脚本先构建发布版，再将完整运行目录及 Visual C++ x64 运行库一起打包到 `dist/WE_Workshop_Monitor_1.1.0_windows_x64.zip`，同时生成 SHA-256 校验文件。开发机需要已安装的 Visual Studio C++ 工具链。若已完成构建，可添加 `-SkipBuild`；若发布目录位于其他位置，可同时传入 `-ReleaseDirectory <目录>`。构建前请关闭从同一构建目录运行的旧版程序，避免 EXE 被占用。

用户将 ZIP **完整解压** 后运行 `we_workshop_monitor.exe`，无需安装 Flutter。发布包不包含个人档案和凭据；更新程序不会覆盖应用数据目录。
