import AppKit
import SwiftUI

struct StickyNoteView: View {
    @Bindable var model: StickyWindowModel
    let importImageFile: @MainActor (URL) async -> String?
    let importImageData: @MainActor (Data) async -> String?
    @State private var isHovering = false
    @State private var showsAppearance = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            stickyBackground
            MarkdownEditorView(
                session: model.session,
                rootURL: model.rootURL,
                context: .sticky,
                renderOptions: MarkdownRenderOptions(
                    fontFamily: model.record.appearance.fontFamily,
                    fontSize: model.record.appearance.fontSize,
                    textColor: PathUtilities.hexColor(model.record.appearance.textColor)
                ),
                importImageFile: importImageFile,
                importImageData: importImageData
            )
            .clipShape(RoundedRectangle(cornerRadius: model.record.appearance.cornerRadius))

            if isHovering || showsAppearance {
                HStack(spacing: 6) {
                    Button {
                        model.setAlwaysOnTop(!model.record.alwaysOnTop)
                    } label: {
                        Image(systemName: model.record.alwaysOnTop ? "pin.fill" : "pin")
                    }
                    .help(model.record.alwaysOnTop ? "取消始终置顶" : "始终置顶")

                    Button { showsAppearance.toggle() } label: { Image(systemName: "paintpalette") }
                        .popover(isPresented: $showsAppearance, arrowEdge: .top) {
                            StickyAppearanceEditor(model: model)
                        }
                        .help("便签外观")

                    Button { model.onClose?() } label: { Image(systemName: "xmark") }
                        .help("取消钉住")
                }
                .buttonStyle(.borderless)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: model.record.appearance.cornerRadius))
        .overlay {
            if model.record.appearance.hasBorder {
                RoundedRectangle(cornerRadius: model.record.appearance.cornerRadius)
                    .stroke(PathUtilities.swiftUIColor(model.record.appearance.borderColor), lineWidth: 1)
            }
        }
        .shadow(
            color: model.record.appearance.hasShadow ? .black.opacity(0.2) : .clear,
            radius: model.record.appearance.hasShadow ? 16 : 0,
            y: 8
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var stickyBackground: some View {
        let background = model.record.appearance.background
        switch background.kind {
        case .solid:
            PathUtilities.swiftUIColor(background.primaryColor)
        case .gradient:
            LinearGradient(
                colors: [
                    PathUtilities.swiftUIColor(background.primaryColor),
                    PathUtilities.swiftUIColor(background.secondaryColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .image:
            if let path = background.imagePath,
               let image = NSImage(contentsOf: model.rootURL.appending(path: path))
            {
                switch background.imageScaling {
                case .fill:
                    Image(nsImage: image).resizable().scaledToFill().clipped()
                case .fit:
                    ZStack {
                        PathUtilities.swiftUIColor(background.primaryColor)
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                case .stretch:
                    Image(nsImage: image).resizable()
                }
            } else {
                PathUtilities.swiftUIColor(background.primaryColor)
            }
        }
    }
}

private struct StickyAppearanceEditor: View {
    @Bindable var model: StickyWindowModel

    var body: some View {
        Form {
            Picker("字体", selection: appearanceBinding(\.fontFamily)) {
                ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Slider(value: appearanceBinding(\.fontSize), in: 11 ... 30, step: 1) {
                Text("字号")
            } minimumValueLabel: { Text("11") } maximumValueLabel: { Text("30") }
            ColorPicker("文字颜色", selection: colorBinding(\.textColor), supportsOpacity: false)
            Picker("背景", selection: backgroundBinding(\.kind)) {
                Text("纯色").tag(StickyBackgroundKind.solid)
                Text("渐变").tag(StickyBackgroundKind.gradient)
                Text("图片").tag(StickyBackgroundKind.image)
            }
            ColorPicker("主背景色", selection: backgroundColorBinding(\.primaryColor), supportsOpacity: false)
            if model.record.appearance.background.kind == .gradient {
                ColorPicker("渐变色", selection: backgroundColorBinding(\.secondaryColor), supportsOpacity: false)
            }
            if model.record.appearance.background.kind == .image {
                Button("选择背景图片…") { model.importBackground() }
                Picker("图片填充", selection: backgroundBinding(\.imageScaling)) {
                    Text("填充").tag(StickyImageScaling.fill)
                    Text("适应").tag(StickyImageScaling.fit)
                    Text("拉伸").tag(StickyImageScaling.stretch)
                }
            }
            Slider(value: appearanceBinding(\.opacity), in: 0.35 ... 1, step: 0.05) { Text("透明度") }
            Slider(value: appearanceBinding(\.cornerRadius), in: 0 ... 28, step: 1) { Text("圆角") }
            Toggle("阴影", isOn: appearanceBinding(\.hasShadow))
            Toggle("边框", isOn: appearanceBinding(\.hasBorder))
            Toggle("无标题栏", isOn: appearanceBinding(\.hidesTitleBar))
        }
        .formStyle(.grouped)
        .frame(width: 310, height: 520)
    }

    private var fontFamilies: [String] {
        let preferred = ["SF Pro", "Helvetica Neue", "Avenir Next", "Menlo", "PingFang SC"]
        return preferred + NSFontManager.shared.availableFontFamilies.filter { !preferred.contains($0) }.prefix(30)
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<StickyAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { model.record.appearance[keyPath: keyPath] },
            set: { value in
                var appearance = model.record.appearance
                appearance[keyPath: keyPath] = value
                model.setAppearance(appearance)
            }
        )
    }

    private func backgroundBinding<Value>(_ keyPath: WritableKeyPath<StickyBackground, Value>) -> Binding<Value> {
        Binding(
            get: { model.record.appearance.background[keyPath: keyPath] },
            set: { value in
                var appearance = model.record.appearance
                appearance.background[keyPath: keyPath] = value
                model.setAppearance(appearance)
            }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<StickyAppearance, String>) -> Binding<Color> {
        Binding(
            get: { PathUtilities.swiftUIColor(model.record.appearance[keyPath: keyPath]) },
            set: { color in
                var appearance = model.record.appearance
                appearance[keyPath: keyPath] = PathUtilities.hexString(NSColor(color))
                model.setAppearance(appearance)
            }
        )
    }

    private func backgroundColorBinding(_ keyPath: WritableKeyPath<StickyBackground, String>) -> Binding<Color> {
        Binding(
            get: { PathUtilities.swiftUIColor(model.record.appearance.background[keyPath: keyPath]) },
            set: { color in
                var appearance = model.record.appearance
                appearance.background[keyPath: keyPath] = PathUtilities.hexString(NSColor(color))
                model.setAppearance(appearance)
            }
        )
    }
}

private extension PathUtilities {
    static func swiftUIColor(_ value: String) -> Color {
        Color(nsColor: hexColor(value))
    }
}
