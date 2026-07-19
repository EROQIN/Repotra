<p align="center">
  <img src="Resources/AppIcon.svg" width="136" height="136" alt="Repotra 图标">
</p>

<h1 align="center">Repotra</h1>

<p align="center">
  原生、轻量、源码保真的 macOS Markdown 笔记应用。
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-191919?logo=apple">
  <img alt="Swift 6.1" src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white">
  <img alt="TextKit 2" src="https://img.shields.io/badge/Editor-TextKit%202-3578E5">
</p>

Repotra 把普通 `.md` 文件作为唯一内容来源，在一个安静的融合式编辑器里完成写作。任意当前笔记都能在单实例临时浮窗中继续编辑；快速笔记使用独立的多会话浮窗，所有窗口共享原始 Markdown 内容。

“设置 → 个性化”可配置贯穿主窗口三栏的系统、纯色、渐变或图片背景，并提供图片填充方式、遮罩强度和自动/手动文字颜色。该配置在所有资料库间共享，与快速笔记的独立外观互不影响。

Repotra 1.0 面向本机交付，构建脚本会输出临时签名应用和便于传输的 ZIP；不包含 Developer ID 公证或 Mac App Store 沙盒化。

## 亮点

| | 能力 |
| --- | --- |
| ✍️ | **源码保真编辑**：渲染只改变 TextKit 2 显示属性，不替换 Markdown 字符，不破坏选区与 Undo 坐标。 |
| 👁️ | **融合式 Markdown**：离开当前行后立即渲染；光标回到节点内部时重新显示对应标记。 |
| ◫ | **临时浮窗**：当前普通笔记以单实例浮窗打开，切换时复用窗口，隐藏前立即保存并恢复独立位置。 |
| ◇ | **快速记录会话**：全局 `⌥⌘N` 恢复上次会话，支持稳定排序的新建、切换、重命名和删除。 |
| 🗂️ | **本地资料库**：整行导航、双击行内重命名、拖入文件夹、全文搜索、字符统计、原子保存和冲突保护。 |
| 🖼️ | **可迁移资源**：粘贴或拖入图片后保存到 `assets/UUID.ext`，整个资料库移动后仍能显示。 |

## Markdown 支持

- GFM 标题、粗体、斜体、删除线、高亮、链接、图片与自动链接
- 引用、嵌套有序/无序列表、任务列表、分隔线和软/硬换行
- 行内代码、围栏代码块、语言提示、语法高亮和一键复制
- 表格、YAML Front Matter、脚注与只读 `[TOC]`
- 选区悬浮格式条、行首 `/` 命令菜单、自动配对和列表续写
- 原始源码模式，以及按窗口隔离的系统 Undo/Redo

数学公式、Mermaid、Wiki Link、标签、双向链接和插件系统暂不在首版范围内。

## 快速开始

### 要求

- macOS 14 或更高版本
- Swift 6.1 或更高版本
- 完整 Xcode（调试应用与运行 XCUITest 时需要）

### 构建可直接打开的应用

```sh
git clone https://github.com/EROQIN/Repotra.git
cd Repotra
Scripts/build-app.sh
open .build/Repotra.app
```

`build-app.sh` 会生成并校验 `.build/Repotra.app`、`.build/Repotra-1.0.0-macos.zip` 与对应 SHA-256 文件，仅供本机运行和传输。

### Xcode

仓库包含生成后的工程；`project.yml` 是工程配置来源。

```sh
brew install xcodegen   # 仅首次需要
xcodegen generate
open Repotra.xcodeproj
```

### 测试

```sh
swift test
swift test --package-path Vendor/MarkdownEngine
```

完整 Xcode 安装后，还应运行 `RepotraUITests`，并在 macOS 14 与 15 上完成手动验收。

Repotra 运行后会注册全局 `⌥⌘N`；即使当前正在使用其他应用，也会直接显示快速笔记浮窗，不会把主窗口切到前台。再次按下快捷键会隐藏浮窗，窗口会记住上次的位置和尺寸。首次使用仍需先选择资料库。

快速笔记每次显示都会直接聚焦到文末，不会自动插入时间标题。会话保存在资料库根目录下可见的“快速笔记”文件夹中，但不会重复出现在普通笔记、全部笔记或最近编辑列表。外观设置支持实时预览，只有点击“完成”才会保存；取消或关闭设置会恢复原来的外观。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 快速笔记 | `⌥⌘N` |
| 折叠侧栏 | `⌘\` |
| 粗体 / 斜体 / 链接 | `⌘B` / `⌘I` / `⌘K` |
| 删除线 / 高亮 / 行内代码 | `⌘⇧X` / `⌘⇧H` / `⌘⇧C` |
| 段落 / 标题 | `⌘0` / `⌘1…⌘6` |
| 引用 / 代码块 | `⌘⇧Q` / `⌘⇧K` |
| 无序 / 有序 / 任务列表 | `⌘⇧U` / `⌘⇧O` / `⌘⇧T` |
| 插入图片 | `⌘⌥I` |

## 设计与架构

Repotra 使用 SwiftUI 管理应用状态与主界面，编辑区域与浮动编辑窗口由 AppKit 提供。Markdown 源码始终是唯一文本存储，文件 I/O、搜索与元数据分别由 actor 隔离。

```text
SwiftUI / AppKit windows
        │
        ├── NoteSession ── shared Markdown source
        ├── MarkdownEngine ── TextKit 2 styling and input
        ├── LibraryStore ── atomic file operations
        ├── SearchIndex ── title, path and body search
        └── MetadataStore ── schema v3 navigation and quick sessions
```

编辑器基于仓库内固定版本的 [swift-markdown-engine 0.9.0](https://github.com/nodes-app/swift-markdown-engine)，并保留其 Apache 2.0 许可证与上游说明。代码高亮由 HighlighterSwift 提供。

## 资料库结构

```text
My Notes/
├── Note.md
├── 快速笔记/                 # 多会话 Markdown；普通列表隐藏、全局搜索可见
│   └── 未命名速记.md
├── assets/                    # 正文图片
└── .repotra/                  # 在文件树和搜索中隐藏
    ├── library.json           # schema v3、快速会话、收藏和展示状态
    ├── stickies.json          # 旧桌面贴图元数据，仅为降级兼容保留
    └── backgrounds/           # 便签背景图
```

删除普通笔记或快速会话时使用 macOS 废纸篓。旧桌面贴图不会自动恢复，也没有产品入口；元数据仅保留以避免旧版本降级时丢失记录。

## 项目状态与许可

Repotra 当前版本为 `1.0.0`。主项目尚未声明开源许可证，因此默认保留所有权利；`Vendor/` 中的第三方代码继续遵循其各自许可证。发布正式开源版本前应先明确主项目许可证。

欢迎通过 Issues 提交问题与建议。
