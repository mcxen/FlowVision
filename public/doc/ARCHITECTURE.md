# FlowVision 项目架构文档

## 项目概述

FlowVision 是一款 macOS 瀑布流风格图片查看器，支持图片和视频浏览，具有以下特性：
- 自适应布局模式，支持明暗主题
- 便捷的文件管理（类似 Finder）
- 右键手势快速导航
- 大量图片目录的性能优化
- 高质量缩放
- 视频播放支持
- HDR 显示支持
- 递归浏览模式

## 快速导航

仓库级修改规则和构建命令见 [`AGENTS.md`](../../AGENTS.md)。定位代码时先搜索下列稳定锚点，避免通读大型扩展文件。

| 场景 | 调用入口 / 核心锚点 | 主要文件 |
|---|---|---|
| 批量重命名 | `actBatchRenameSelectedItems` → `handleBatchRenameSelectedItems` | `Views/CustomCollectionViewItem.swift`、`Views/CustomOutlineView.swift`、`ViewControllerExtension/FileOperation.swift` |
| 快捷重命名当前目录 | `handleQuickRenameInCurrentFolder` → `executeFileRenameMappingsAsync` | `ViewControllerExtension/FileOperation.swift` |
| 原位更新名称 | `applyRenameMappingsInPlace` | `ViewControllerExtension/FileOperation.swift` |
| 配置目录异步复制 | `handleCopyToPhotoFolder1` / `handleCopySelectedVideosToPhotoFolder2` → `handleCopyToConfiguredFolder` | `ViewControllerExtension/KeyShortcut.swift`、`ViewControllerExtension/FileOperation.swift` |
| 文件系统刷新与定位 | `scheduledRefresh` → `selectItemsNewChanged` | `ViewController.swift`、`ViewControllerExtension/FileSystem.swift` |
| 播放状态 | `currentPlayingURL`、`restorePlayURL` | `ViewController.swift`、`Views/LargeImageView.swift`、`Views/CustomCollectionViewItem.swift` |
| 邻近媒体预热 | `preloadLargeImage` → `MediaPreheatManager` | `ViewControllerExtension/LargeImage.swift`、`Common/VideoProcess.swift` |
| FFmpeg | `FFmpegKit` | `Common/FFmpegKit.swift` |

常用定位命令：

```bash
rg -n 'handleQuickRenameInCurrentFolder|applyRenameMappingsInPlace' FlowVision/Sources
rg -n 'handleCopyToConfiguredFolder|isInFileOperation' FlowVision/Sources
rg -n 'currentPlayingURL|restorePlayURL' FlowVision/Sources
```

## 系统要求

- macOS 11.0 或更高版本
- Xcode 15.2+

## 目录结构

```
FlowVision/
├── FlowVision.xcodeproj          # Xcode 项目文件
├── FlowVision/
│   ├── Info.plist                # 应用程序配置
│   ├── FlowVision.entitlements   # 应用权限配置
│   ├── Resources/                # 资源文件
│   │   ├── Assets.xcassets/      # 图片资源
│   │   ├── Base.lproj/           # 基础本地化资源
│   │   ├── mul.lproj/            # 多语言本地化资源
│   │   ├── Localizable.xcstrings # 本地化字符串
│   │   └── icon.png              # 应用图标
│   └── Sources/                  # 源代码目录
│       ├── AppDelegate.swift     # 应用程序代理
│       ├── ViewController.swift  # 主视图控制器
│       ├── WindowController.swift # 窗口控制器
│       ├── Common/               # 公共模块
│       ├── Views/                # 视图组件
│       ├── ViewControllerExtension/ # 视图控制器扩展
│       └── SettingsViews/        # 设置界面
├── docs/                         # 文档目录
├── public/                       # 公共资源
├── build_dmg.sh                  # DMG 打包脚本
├── Base.xcconfig                 # 基础配置
└── LocalDev.xcconfig.template    # 本地开发配置模板
```

## 核心模块说明

### 1. 入口文件

| 文件 | 说明 |
|------|------|
| `AppDelegate.swift` | 应用程序入口，处理应用生命周期、全局状态管理、菜单配置等 |
| `ViewController.swift` | 主视图控制器，核心业务逻辑，管理图片展示、用户交互 |
| `WindowController.swift` | 窗口控制器，管理窗口行为、标题栏、工具栏等 |

### 2. Common 模块 (`Sources/Common/`)

公共工具和数据模型，被其他模块共享使用。

| 文件 | 大小 | 说明 |
|------|------|------|
| `Common.swift` | 40KB | 通用工具函数、扩展方法、辅助功能 |
| `DataModel.swift` | 41KB | 数据模型定义，包含排序键、文件项模型等 |
| `ImageProcess.swift` | 106KB | 图片处理核心逻辑，缩略图生成、图片解码等 |
| `VideoProcess.swift` | 3KB | 视频处理相关功能 |
| `FFmpegKit.swift` | 7KB | FFmpeg 集成封装 |
| `FinderTag.swift` | 31KB | macOS Finder 标签功能集成 |
| `Log.swift` | 12KB | 日志系统 |
| `GlobalVariable.swift` | 9KB | 全局变量和配置 |
| `Enum.swift` | 1KB | 枚举定义（文件类型、排序类型、布局类型等） |
| `RefCode.swift` | 1KB | 引用代码 |
| `TempVariable.swift` | 0.1KB | 临时变量 |

#### 关键枚举定义 (`Enum.swift`)

```swift
// 文件类型
enum FileType: Int, Codable {
    case image, video, other, folder, notSet, all
}

// 右键手势方向
enum RightMouseGestureDirection: Int, Codable {
    case right, left, up, down, up_right, up_left, down_left, down_right, zero, forward, back
}

// 布局类型
enum LayoutType: Int, Codable {
    case justified, waterfall, grid, detail
}

// 排序类型
enum SortType: Int, Codable {
    case pathA, pathZ, extA, extZ, sizeA, sizeZ,
         createDateA, createDateZ, modDateA, modDateZ,
         addDateA, addDateZ, random, exifDateA, exifDateZ,
         exifPixelA, exifPixelZ
}
```

### 3. Views 模块 (`Sources/Views/`)

自定义视图组件，负责 UI 渲染。

| 文件 | 大小 | 说明 |
|------|------|------|
| `CustomCollectionView.swift` | 18KB | 自定义集合视图，瀑布流布局核心 |
| `CustomCollectionViewItem.swift` | 76KB | 集合视图单元格，缩略图显示 |
| `CustomOutlineView.swift` | 23KB | 目录树视图 |
| `CustomOutlineViewManager.swift` | 16KB | 目录树管理器 |
| `LargeImageView.swift` | 116KB | 大图查看视图 |
| `ImageEditingView.swift` | 34KB | 图片编辑视图 |
| `CoreAreaView.swift` | 12KB | 核心区域视图 |
| `Layout.swift` | 12KB | 布局管理 |
| `CustomImageView.swift` | 8KB | 自定义图片视图 |
| `CustomProfileView.swift` | 23KB | 配置文件视图 |
| `FavoritesPopoverViewController.swift` | 17KB | 收藏夹弹出视图 |
| `DrawingView.swift` | 5KB | 绘图视图 |
| `CustomSplitView.swift` | 2KB | 自定义分割视图 |
| `CustomPathControl.swift` | 0.2KB | 路径控件 |
| `CustomEffectView.swift` | 2KB | 自定义效果视图 |
| `CustomCollectionViewManager.swift` | 6KB | 集合视图管理器 |
| `CustomCollectionViewItem.xib` | 5KB | 界面布局文件 |

### 4. ViewControllerExtension 模块 (`Sources/ViewControllerExtension/`)

视图控制器功能扩展，按职责分离代码。

| 文件 | 大小 | 说明 |
|------|------|------|
| `FileOperation.swift` | 93KB | 文件操作（复制、移动、删除、重命名等） |
| `KeyShortcut.swift` | 52KB | 键盘快捷键处理 |
| `FileSystem.swift` | 76KB | 文件系统操作、目录遍历 |
| `LargeImage.swift` | 47KB | 大图查看功能 |
| `EventHandler.swift` | 27KB | 事件处理 |
| `Search.swift` | 25KB | 搜索功能 |
| `WindowManagement.swift` | 19KB | 窗口管理 |
| `ArrowKeyLocate.swift` | 13KB | 方向键导航 |
| `DirTree.swift` | 7KB | 目录树操作 |
| `AutoScrollPlay.swift` | 5KB | 自动滚动播放 |
| `RightMouseGesture.swift` | 6KB | 右键手势识别 |
| `ProgressBar.swift` | 9KB | 进度条显示 |
| `MemoryManagement.swift` | 3KB | 内存管理 |
| `LayoutManagement.swift` | 11KB | 布局管理 |
| `LayoutProfileConfig.swift` | 6KB | 布局配置文件管理 |

### 5. SettingsViews 模块 (`Sources/SettingsViews/`)

设置界面相关视图。

| 文件 | 说明 |
|------|------|
| `GeneralSettingsViewController.swift` | 通用设置（启动、外观等） |
| `ActionsSettingsViewController.swift` | 操作设置（快捷键、手势等） |
| `CustomSettingsViewController.swift` | 自定义设置 |
| `AdvancedSettingsViewController.swift` | 高级设置（性能、内存等） |
| `TaggingSettingsViewController.swift` | 标签设置 |
| `DemoSettingsViewController.swift` | 演示设置 |

## 架构设计

### MVC 架构

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                       │
│  ┌─────────────────┐                                        │
│  │  AppDelegate    │ ← 应用入口、全局状态、菜单管理           │
│  └─────────────────┘                                        │
├─────────────────────────────────────────────────────────────┤
│                     Controller Layer                         │
│  ┌─────────────────┐  ┌──────────────────────┐             │
│  │ WindowController│  │   ViewController     │             │
│  │                 │  │   (Main Controller)  │             │
│  └─────────────────┘  └──────────────────────┘             │
│                              │                              │
│              ┌───────────────┼───────────────┐             │
│              ↓               ↓               ↓             │
│  ┌────────────────┐ ┌─────────────┐ ┌──────────────┐      │
│  │ FileOperation  │ │ KeyShortcut │ │ EventHandler │ ...  │
│  └────────────────┘ └─────────────┘ └──────────────┘      │
├─────────────────────────────────────────────────────────────┤
│                        View Layer                            │
│  ┌────────────────────┐  ┌────────────────────┐            │
│  │ CustomCollectionView│  │  CustomOutlineView │            │
│  │ (瀑布流缩略图)       │  │  (目录树)          │            │
│  └────────────────────┘  └────────────────────┘            │
│  ┌────────────────────┐  ┌────────────────────┐            │
│  │   LargeImageView   │  │ ImageEditingView   │            │
│  │   (大图查看)        │  │ (图片编辑)          │            │
│  └────────────────────┘  └────────────────────┘            │
├─────────────────────────────────────────────────────────────┤
│                        Model Layer                           │
│  ┌─────────────────────────────────────────────┐           │
│  │ DataModel.swift (SortKey, FileItem等)       │           │
│  │ GlobalVariable.swift (GlobalVar)            │           │
│  └─────────────────────────────────────────────┘           │
├─────────────────────────────────────────────────────────────┤
│                     Service Layer                            │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────┐       │
│  │ImageProcess │ │ VideoProcess │ │  FinderTag     │       │
│  └─────────────┘ └──────────────┘ └────────────────┘       │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────┐       │
│  │ FileSystem  │ │   Log        │ │   FFmpegKit    │       │
│  └─────────────┘ └──────────────┘ └────────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### 数据流向

```
用户操作 → EventHandler/KeyShortcut
                ↓
         ViewController
                ↓
    ┌───────────┼───────────┐
    ↓           ↓           ↓
FileOperation  Search    FileSystem
    ↓           ↓           ↓
    └───────────┼───────────┘
                ↓
         DataModel 更新
                ↓
         View 刷新
```

## 文件操作、线程与刷新策略

### 重命名调用链

```text
缩略图/目录树菜单                         当前目录快捷键
        │                                      │
        ▼                                      ▼
handleBatchRenameSelectedItems     handleQuickRenameInCurrentFolder
        │                                      │
预览表格（原名称 / 新名称）             后台生成重命名计划
        └──────────────┬───────────────────────┘
                       ▼
 executeFileRenameMappings / executeFileRenameMappingsAsync
                       │
        冲突预检 → 临时名 → 最终名 → 失败回滚
                       │
             更新 Enhanced Index 与 Undo
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
 applyRenameMappingsInPlace    条件不满足的兜底刷新
 路径/名称/排序原位更新          scheduledRefresh + 恢复滚动
```

批量重命名支持前缀、后缀、查找替换，以及 `{name}`、`{index}`、`{index:03}`、`{folder}`、`{ext}` 等变量。确认前使用两列表格展示原名称和新名称。执行器采用两阶段临时路径，避免交换名称或排序链式重命名互相覆盖。

### 复制到配置目录

图片目录 1 与视频目录 2 共用 `handleCopyToConfiguredFolder`：

```text
快捷键/菜单
  → 收集并校验 URL、目标目录、自复制关系（主线程）
  → FileManager.copyItem、重名避让、进度统计（后台队列）
  → 状态复位、错误提示、目标定位与刷新（主线程）
```

该路径不依赖 Finder 剪贴板。调用方包括 `handleCopyToPhotoFolder1`、`handleCopySelectedVideosToPhotoFolder2` 和当前视频复制入口。

### 线程约定

| 工作 | 所在线程 |
|---|---|
| 文件枚举、批量冲突检查、复制、两阶段重命名、Enhanced Index 更新 | 后台队列 |
| NSAlert、进度控件、collection/outline view、窗口标题、UndoManager | 主线程 |
| `publicVar.isInFileOperation` 的生命周期切换 | 主线程统一管理，所有退出路径复位 |

`isInFileOperation` 使文件监听刷新在应用主动操作期间让路，防止中间临时文件被扫描进模型。后台任务不得直接访问或修改 AppKit 对象。

### 刷新决策

| 变更类型 | 默认策略 | 原因 |
|---|---|---|
| 仅重命名 | `applyRenameMappingsInPlace` | 复用 `FileModel` 和现有 cell，不闪烁、不重启播放器 |
| 重命名但模型不完整/目录已切换 | `scheduledRefresh`，随后恢复滚动位置 | 确保磁盘和模型最终一致 |
| 创建、复制、移动到新位置 | 刷新并使用 `filesForLocateAfterChange` 定位新目标 | 新文件尚未存在于当前 Map |
| 删除、目录结构变化 | 文件系统刷新 | 需要重新枚举或更新目录树 |

原位重命名会克隆新的 `SortKeyFile` 并重建 `BTree.Map`，但继续复用 `FileModel`。可见 cell 只更新 URL、名称、tooltip 和必要的排序移动，不调用完整配置流程。大图路径、`currentPlayingURL`、`restorePlayURL`、Finder 打开路径和窗口标题同步替换，从而保留视频播放进度。

兜底刷新使用 `collectionScrollRestoreAfterRefresh` 保存当前 clip view 原点，并在 `selectItemsNewChanged(isFinal:)` 完成后恢复。快捷重命名不设置 `filesForLocateAfterChange`，否则会错误滚到第一个改名项目。

### FFmpeg 剪切边界

输入端 `-ss` 配合 `-c copy` 是关键帧级无损剪切，不是帧精确剪切。iPhone MOV 可能同时包含视频、多个音轨和 `mebx` data 流；无差别映射所有流会把各自的原始时间轴带入输出，可能表现为开头黑屏或容器时长异常。

- 只需要画面和声音：使用 `-map 0:v:0 -map 0:a?`，不要默认映射 data 流。
- 需要准确起止：视频重编码，并显式处理时间戳；音频可按兼容性决定复制或重编码。
- 需要无损快速导出：接受切点对齐附近关键帧，并用 `ffprobe` 同时检查 format duration 和各 stream 的 start/duration。

## 邻近媒体预热与 SMB 播放

大图浏览每次切换位置后，以当前媒体为中心收集前 5 个和后 5 个可浏览媒体。`ViewController` 持有独立的 `MediaPreheatManager`，因此多窗口之间不会相互取消任务。

```text
changeLargeImage（仅浏览位置变化）
  → preloadLargeImage 收集 [-5 ... 当前 ... +5]
  → beginWindow：取消旧任务、更新 generation
      ├─ 图片队列（并发 2）→ LargeImageProcessor 解码缓存
      └─ 视频队列（并发 1）→ AVAssetReader 读取前 5 秒压缩样本
                              → macOS Unified Buffer Cache
                              → 保留已解析 AVURLAsset
```

视频不生成本地 5 秒临时片段，因为片段切回原片会引入时间轴、音轨和关键帧拼接问题。`AVAssetReader` 的目的不是提前播放或长期持有解码帧，而是将 SMB 上即将访问的文件区间预读进系统文件页缓存。邻项切成当前项后：

- libmpv 强制开启有界缓存，先维持约 5 秒目标缓冲，再在播放过程中持续向前读取；demuxer 前向上限为 128 MiB，回看上限为 32 MiB。
- AVPlayer 回退路径优先从 `MediaPreheatManager` 取已解析的 `AVURLAsset`，并继续使用 `preferredForwardBufferDuration = 5`。
- 当前视频由播放器读取，预热器只处理邻近视频，避免同一 SMB 文件被两条读取链路竞争。

预热任务带 generation。快速连续翻页时，排队任务会被取消，已经运行的视频读取循环检测 generation 并取消 `AVAssetReader`。图片和视频队列分别限制并发，避免预热吞掉当前播放所需带宽。缩放、旋转等不改变浏览位置的刷新不重建预热窗口。

## 支持的文件格式

### 图片格式
- 常见格式：jpg, jpeg, png, gif, bmp, webp, tiff, ico, svg
- 高质量格式：heif, heic, hif, avif, jxl, jp2
- RAW 格式：crw, cr2, cr3, nef, nrw, arw, srf, sr2, rw2, orf, raf, pef, dng, raw, rwl, x3f, 3fr, fff, iiq, mos, dcr, erf, mrw, gpr, srw
- 设计文件：ai, psd

### 视频格式
- 原生支持：mp4, mov, m2ts, ts, mpeg, mpg, m4v, vob
- FFmpeg 支持：mkv, mts, avi, flv, f4v, asf, wmv, rmvb, rm, webm, divx, xvid, 3gp, 3g2

## 依赖库

| 库名 | 用途 |
|------|------|
| ffmpeg-kit | 视频解码和处理 |
| BTree | 高效有序数据结构 |
| Settings | 设置界面框架 |

## 全局配置 (`GlobalVar`)

主要配置项包括：
- 窗口限制：`WINDOW_LIMIT = 16`
- 缩略图预加载范围：前 20 张，后 40 张
- 内存使用限制：默认 4000MB
- 缩略图线程数：本地 8，外部 1
- 文件夹搜索深度：本地 4，外部 0
- 滚动灵敏度
- 各种显示和行为选项

## 布局模式

1. **Justified（两端对齐）**：图片行两端对齐，类似 Google Photos
2. **Waterfall（瀑布流）**：传统瀑布流布局
3. **Grid（网格）**：均匀网格布局
4. **Detail（详情）**：详细信息列表视图

## 用户交互

### 右键手势
- 右/左：切换到下一个/上一个含图片的文件夹
- 上：切换到父目录
- 下：返回上一个目录
- 右上：切换到同级下一个文件夹
- 右下：关闭标签/窗口

### 键盘快捷键
- W：等同于右键手势向上
- A/D：等同于右键手势左/右
- S：等同于右键手势向下

### 图片查看操作
- 双击：打开/关闭图片
- 右键/左键 + 滚轮：缩放
- 中键拖动：移动窗口
- 长按左键：100% 缩放
- 长按右键：适应窗口

## 构建说明

1. 克隆项目和依赖库
2. 构建 ffmpeg-kit 或下载预编译版本
3. 按指定目录结构组织依赖
4. 使用 Xcode 构建 Release 版本

---

*最后维护日期：2026-07-12*
