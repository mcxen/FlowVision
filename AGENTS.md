# FlowVision Agent Guide

本文件是仓库的低 token 导航入口。先读本文件，再按任务只打开
[`public/doc/ARCHITECTURE.md`](public/doc/ARCHITECTURE.md) 中对应的小节和代码锚点；不要默认通读大型 Swift 文件。

## 仓库与构建

- 工程：`FlowVision.xcodeproj`；Scheme：`FlowVision`；目标平台：macOS。
- 源码：`FlowVision/Sources/`；详细架构：`public/doc/ARCHITECTURE.md`。
- 本地依赖通常位于相邻目录（如 `../Settings`、`../BTree`），另有 Xcode Package 依赖。
- `build/`、`dist/` 是生成物，不属于源码，不应提交。
- 统一构建/运行入口：`./script/build_and_run.sh`；可用 `--verify`、`--debug`、`--logs`、`--telemetry`。
- 无签名 Release 验证：

```bash
xcodebuild -quiet -project FlowVision.xcodeproj -scheme FlowVision \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## 快速定位

优先使用 `rg -n '函数名|状态名' FlowVision/Sources`，按下表读取最少文件。

| 任务 | 首选文件 / 锚点 |
|---|---|
| 重命名、复制、移动、删除 | `ViewControllerExtension/FileOperation.swift` |
| 批量重命名入口与预览 | `handleBatchRenameSelectedItems`、`BatchRenamePreviewDataSource` |
| 当前目录快捷重命名 | `handleQuickRenameInCurrentFolder` |
| 重命名执行、回滚、Undo | `executeFileRenameMappings`、`executeFileRenameMappingsAsync` |
| 重命名后无闪烁更新 | `applyRenameMappingsInPlace` |
| 图片/视频复制到配置目录 | `handleCopyToConfiguredFolder` |
| 缩略图右键菜单 | `Views/CustomCollectionViewItem.swift` |
| 左侧目录树右键菜单 | `Views/CustomOutlineView.swift` |
| 快捷键分发 | `ViewControllerExtension/KeyShortcut.swift`、`WindowController.swift` |
| 文件扫描、刷新、刷新后定位 | `ViewControllerExtension/FileSystem.swift` / `selectItemsNewChanged` |
| 跨操作状态 | `ViewController.swift` / `PublicVar` |
| 排序键与文件模型 | `Common/DataModel.swift` / `SortKeyFile`、`FileModel` |
| 视频播放连续性 | `Views/LargeImageView.swift`、`Views/CustomCollectionViewItem.swift` |
| 邻近媒体 / SMB 预热 | `Common/VideoProcess.swift` / `MediaPreheatManager`、`ViewControllerExtension/LargeImage.swift` / `preloadLargeImage` |
| 进度 UI | `Views/CoreAreaView.swift`、`ViewControllerExtension/ProgressBar.swift` |
| Enhanced Index / Finder 元数据 | `Common/FinderTag.swift` |
| FFmpeg 调用 | `Common/FFmpegKit.swift`；剪切规则见架构文档 |

## 文件操作不变量

1. 大批量磁盘 I/O、冲突检查、索引更新放后台队列；AppKit、集合视图、窗口标题、Undo 注册只在主线程。
2. 文件操作期间正确维护 `publicVar.isInFileOperation`，避免文件系统监听器插入竞争刷新；所有成功、失败和提前返回路径都必须复位。
3. 重命名使用“源文件 → 临时名 → 最终名”的两阶段移动。执行前检查重复目标和外部占用；部分失败必须回滚。
4. `BTree.Map` 中的 `SortKeyFile` 是排序键，不能原地修改路径；应复制键并重建 Map，同时复用现有 `FileModel`。
5. 纯重命名优先调用 `applyRenameMappingsInPlace`：只更新路径、名称、排序位置和标题，不重新配置缩略图/播放器，不调用 `reloadData()` 或 `scheduledRefresh()`。
6. 原位更新条件不满足时才允许完整刷新；刷新前保存 `collectionScrollRestoreAfterRefresh`，最终在 `selectItemsNewChanged` 恢复可见位置。
7. 重命名不得重启或停止视频。同步维护 `currentPlayingURL`、`restorePlayURL`、大图路径和窗口标题，保留播放进度。
8. `filesForLocateAfterChange` 用于复制、创建、移动后的新目标定位；快捷重命名传空定位目标，不能把视图滚到第一个改名文件。
9. 图片目录 1 和视频目录 2 的复制共用 `handleCopyToConfiguredFolder`。复制在后台执行，自动避让重名，完成后回主线程刷新/定位。
10. 不要通过 Finder 剪贴板模拟应用内复制；直接使用 `FileManager`，错误和进度要可见。

## 邻近媒体缓存不变量

1. 大图浏览以当前媒体为中心维护前后各 5 个媒体的预热窗口；数量按图片/视频媒体计算，不按目录中的所有文件计算。
2. 图片继续写入 `LargeImageProcessor` 解码缓存；图片预热最多并发 2，尺寸与元数据读取也不能阻塞主线程。
3. 邻近视频只预读前 5 秒压缩视频样本到 macOS Unified Buffer Cache，并保留解析后的 `AVURLAsset`；不要生成需要和原片拼接的临时短视频。
4. 视频预热串行执行。切换媒体时 `beginWindow` 必须取消旧队列并递增 generation，运行中的任务须检查 generation 后尽快退出。
5. 当前视频不与邻项预热器重复读取：mpv/AVPlayer 自己维持 5 秒前向缓冲，开始播放后继续顺序预读。
6. mpv 缓存必须有上限；当前约束为 5 秒目标缓冲、128 MiB 前向 demuxer 上限、32 MiB回看上限。禁止无界占用内存或磁盘。
7. AVPlayer 路径优先复用 `mediaPreheatManager.preheatedAsset(for:)`，避免再次解析 SMB 媒体头。
8. 放大/旋转等同一媒体内部刷新不能重建预热窗口；只有浏览位置变化时才调度。

## FFmpeg 剪切约束

- `-ss` 位于输入端且配合 `-c copy` 时只能从附近关键帧无损起切，不保证精确起点。
- 不要默认 `-map 0:0 ...` 复制 iPhone MOV 的全部 data/metadata 流；这些流可能保留原始时间戳，造成黑屏、时长异常。
- 只需音视频时优先 `-map 0:v:0 -map 0:a?`。要求帧精确时重编码视频，并显式重置时间戳；不要把 stream copy 描述成精确剪切。

## 修改与验证

- 保留工作区内用户已有改动；不要清理或覆盖无关 diff。
- 编辑使用小范围补丁；禁止顺手重构与任务无关的大文件。
- 最少验证：`git diff --check`，再按风险运行 Release 构建。
- 重命名手工回归：多选预览、变量替换、冲突提示、Undo、排序变化、滚动位置、缩略图无闪烁、视频播放进度不丢。
- 异步复制手工回归：图片目录 1、选中视频目录 2、当前视频目录 2、重名避让、失败提示、操作期间界面响应。
- SMB 缓存手工回归：连续前后切换图片和视频、快速连翻后旧任务停止、首帧等待降低、播放 5 秒后持续加载、内存和网络读取保持有界。
- 发布前检查 `git status --short`，只提交任务相关文件；push/tag 必须在用户明确要求后执行，tag不应该直接检查actions，需要用户确认才能执行。
