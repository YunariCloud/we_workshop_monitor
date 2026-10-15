# WE Workshop Monitor

Wallpaper Engine 创意工坊创作者监测与归档桌面客户端。

为关注的创作者建立作品档案，追踪新增、修改、消失和重新公开的作品。即使作品以后无法访问，也能查看此前已保存的标题、简介、标签与预览图，并将档案备份到本地目录或 WebDAV。

> 归档范围是作品元数据和预览图，不包含壁纸源文件、视频或 `.pkg` 文件，也无法找回首次建档前已经消失的作品。

## 功能

- **创作者监测**：通过 SteamID64、`/profiles/` 链接或 `/id/` 个性主页添加创作者，首次同步建立基线档案。
- **增量追踪**：记录新增、修改、消失和恢复事件；对疑似消失的作品调用详情接口再次核验。
- **作品画廊**：按创作者、关键词与作品状态筛选，支持查看已消失作品及曾修改的作品。
- **历史对比**：保留字段变更记录和已下载的历史预览图，支持查看作品时光机与变更时间轴。
- **定时同步**：支持手动同步，或每 2、6、12、24 小时轮询；默认每 6 小时检查一次。
- **本地备份**：生成全量 ZIP、轮转保留历史归档，或将数据库快照和预览图同步到镜像目录。
- **WebDAV 备份**：支持连接测试、增量同步、全量 ZIP 上传，以及从远端镜像恢复。

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

1. 在创作者监测页面添加 SteamID64 或 Steam 主页链接。
2. 执行首次同步，等待作品列表及预览图建档完成。
3. 在作品画廊和变更时间轴查看档案；之后的同步会与本地记录比对。
4. 在设置中心选择轮询间隔，并配置本地目录或 WebDAV 备份。

Steam Web API Key 为可选配置。填写后优先使用 API；留空时使用公开网页解析与公开详情接口。采集结果取决于 Steam 页面、接口可用性及作品公开状态。

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

Steam API Key 和 WebDAV 密码通过 `flutter_secure_storage` 保存；其他设置存入本地 SQLite 数据库。

| 方式 | 内容与用途 |
| --- | --- |
| 本地全量 ZIP | 数据库快照、预览图和导出清单；默认最多保留 10 份 |
| 本地镜像 | 更新数据库快照，复制新增预览图，便于日常备份 |
| WebDAV 增量镜像 | 上传最新数据库快照及新增预览图，供远端备份与恢复使用 |
| WebDAV 全量 ZIP | 将完整归档上传至远端 `archives/` 目录 |

备份导出包含创作者汇总、作品 JSON、消失作品 CSV，以及带数据库 SHA-256 的清单。自动备份在后台轮询发现变更后触发，需要先填写相应的目标目录或 WebDAV 连接信息。

恢复入口读取 WebDAV **增量镜像中的数据库快照和预览图**，会替换当前本地数据库；恢复前请先做一次本地备份。当前没有本地 ZIP 的图形化导入入口。

## 项目结构

```text
lib/
├── main.dart                    # Material 3 桌面界面与配置入口
├── workshop_models.dart         # 领域模型、设置与 Steam 输入解析
├── workshop_database.dart       # SQLite 持久化、检索与快照恢复
├── steam_api_service.dart       # Steam API、网页解析与预览图下载
├── diff_engine.dart             # 基线建档与增量变更比对
├── backup_service.dart          # 本地 / WebDAV 备份与恢复
└── scheduler_tray_service.dart  # 定时轮询、窗口与托盘集成
windows/                        # Windows 原生宿主
pubspec.yaml                    # 依赖与 SQLite 加载配置
pubspec.lock                    # 已解析的依赖版本
```

主要技术：Flutter / Dart、Material 3、SQLite FFI、Dio、HTML 解析、`archive`、`webdav_client`、`flutter_secure_storage`、`window_manager` 和 `tray_manager`。

SQLite 由 `sqlite3_flutter_libs` 编译并随应用打包。`pubspec.yaml` 的 hooks 配置让 `sqlite3` 加载该动态库，避免重复下载另一份 GitHub 二进制文件。

## 开发与验证

```powershell
flutter pub get
flutter analyze
flutter build windows --release
```

当前尚未建立自动化测试套件。已完成的验证范围是 Windows 静态检查、构建和应用启动；Steam 实际采集及 WebDAV 备份恢复仍需结合目标创作者与服务器进行验证。

## 已知限制

- 当前仅包含 Windows 宿主工程。macOS 和 Linux 需要补齐平台工程并分别验证，尚未提供对应构建。
- 网页解析依赖 Steam 页面结构；网络波动、访问限制、限流或页面改版都可能影响同步。作品“消失”表示采集时不可公开访问，不能据此确定删除原因。
- 后台轮询依赖客户端持续运行；退出程序或电脑休眠期间不会执行检查。
- 托盘菜单已有代码，但尚未设置托盘图标。建议在设置中关闭“关闭窗口时最小化驻留系统托盘”，避免关闭窗口后缺少可见的恢复入口。
- 预览图历史保留会持续占用磁盘空间；本地 ZIP 的份数轮转不会清理原始预览图历史。

反馈问题时，请附上系统版本、`flutter --version`、复现步骤和错误信息；分享日志前请移除 API Key、WebDAV 密码等凭据。
