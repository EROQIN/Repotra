# Repotra

Repotra 是一个原生 macOS Markdown 笔记应用。它以普通 `.md` 文件作为唯一内容来源，并允许把任意笔记钉成可编辑的桌面便签。

## 已实现

- 单资料库文件树、创建、重命名、拖放移动和移入废纸篓
- 标题、路径和正文全文搜索
- 当前块显示 Markdown 源码、其他块富文本渲染的融合编辑器
- GFM 标题、强调、删除线、列表、任务项、引用、链接、图片、代码块和表格
- 500ms 自动保存、原子写入和外部修改冲突保护
- 图片粘贴与拖入，复制到资料库 `assets/` 并插入相对路径
- 同一笔记的主窗口与桌面便签实时同步
- 多便签、独立置顶、位置恢复、字体、颜色、渐变、背景图片、透明度、圆角、边框、阴影和无标题栏样式
- `.repotra/` 内可迁移的资料库 UUID、便签状态和背景资源

## 开发环境

- macOS 14 或更高版本
- Swift 6.1 或更高版本
- 完整 Xcode（运行 Xcode UI 测试和调试 `.app` 必需）

当前仓库也保留 Swift Package 入口，因此只有 Command Line Tools 时仍可执行核心构建和单元测试：

```sh
swift build
swift test
```

生成并打开 Xcode 工程：

```sh
brew install xcodegen   # 仅首次需要
xcodegen generate
open Repotra.xcodeproj
```

仓库已经包含生成后的 `Repotra.xcodeproj`，`project.yml` 是工程配置的来源。

构建一个无需签名、供本机直接运行的应用包：

```sh
Scripts/build-app.sh
open .build/Repotra.app
```

## 资料库结构

```text
My Notes/
├── Note.md
├── assets/                    # 正文图片
└── .repotra/
    ├── library.json           # schemaVersion 与资料库 UUID
    ├── stickies.json          # 便签窗口与外观
    └── backgrounds/           # 便签背景图
```

关闭便签只会取消钉住，不会删除 Markdown 文件。删除笔记时使用 macOS 废纸篓。第一版不包含 iCloud、数学公式、Mermaid、标签、双向链接或 App Store 沙盒。
