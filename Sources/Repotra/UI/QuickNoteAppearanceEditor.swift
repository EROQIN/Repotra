import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QuickNoteAppearanceEditor: View {
    private enum ColorTarget: String {
        case text
        case primaryBackground
        case secondaryBackground
        case border
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: QuickNoteAppearanceController
    let onCancel: @MainActor () -> Void
    let onCommit: @MainActor () async -> Bool

    @State private var showsAdvanced = false
    @State private var showsImageImporter = false
    @State private var activeColorTarget: ColorTarget?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("常用") {
                    Picker("主题", selection: presetBinding) {
                        ForEach(QuickNoteThemePreset.selectableCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                        if controller.selectedPreset == .custom {
                            Text(QuickNoteThemePreset.custom.title).tag(QuickNoteThemePreset.custom)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("quick-note-theme")

                    valueSlider(
                        "字号",
                        value: appearanceBinding(\.fontSize),
                        range: 11 ... 30,
                        step: 1,
                        valueText: "\(Int(controller.preview.fontSize)) pt"
                    )
                    valueSlider(
                        "透明度",
                        value: appearanceBinding(\.opacity),
                        range: 0.35 ... 1,
                        step: 0.05,
                        valueText: "\(Int((controller.preview.opacity * 100).rounded()))%"
                    )
                }

                DisclosureGroup("高级设置", isExpanded: $showsAdvanced) {
                    Picker("字体", selection: appearanceBinding(\.fontFamily)) {
                        ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    colorEditorRow(
                        "文字颜色",
                        target: .text,
                        binding: colorBinding(\.textColor)
                    )

                    Picker("背景", selection: backgroundBinding(\.kind)) {
                        Text("系统").tag(QuickNoteBackgroundKind.system)
                        Text("纯色").tag(QuickNoteBackgroundKind.solid)
                        Text("渐变").tag(QuickNoteBackgroundKind.gradient)
                        Text("图片").tag(QuickNoteBackgroundKind.image)
                    }
                    if controller.preview.background.kind != .system {
                        colorEditorRow(
                            "主背景色",
                            target: .primaryBackground,
                            binding: backgroundColorBinding(\.primaryColor)
                        )
                    }
                    if controller.preview.background.kind == .gradient {
                        colorEditorRow(
                            "渐变色",
                            target: .secondaryBackground,
                            binding: backgroundColorBinding(\.secondaryColor)
                        )
                    }
                    if controller.preview.background.kind == .image {
                        Button("选择背景图片…") { showsImageImporter = true }
                            .accessibilityIdentifier("quick-note-background-image")
                        Picker("图片填充", selection: backgroundBinding(\.imageScaling)) {
                            Text("填充").tag(StickyImageScaling.fill)
                            Text("适应").tag(StickyImageScaling.fit)
                            Text("拉伸").tag(StickyImageScaling.stretch)
                        }
                    }

                    valueSlider(
                        "圆角",
                        value: appearanceBinding(\.cornerRadius),
                        range: 0 ... 28,
                        step: 1,
                        valueText: "\(Int(controller.preview.cornerRadius))"
                    )
                    Toggle("阴影", isOn: appearanceBinding(\.hasShadow))
                    Toggle("边框", isOn: appearanceBinding(\.hasBorder))
                    if controller.preview.hasBorder {
                        colorEditorRow(
                            "边框颜色",
                            target: .border,
                            binding: borderColorBinding
                        )
                    }
                }

                if let message = controller.errorMessage ?? controller.warning {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(controller.errorMessage == nil ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("quick-note-settings-message")
                }

                Button("恢复默认") { controller.resetDraft() }
                    .accessibilityIdentifier("quick-note-reset")
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                    .accessibilityIdentifier("quick-note-settings-cancel")
                Button {
                    Task {
                        if await onCommit() { dismiss() }
                    }
                } label: {
                    if controller.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("完成")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isSaving)
                .accessibilityIdentifier("quick-note-settings-done")
            }
            .padding(12)
        }
        .frame(
            width: 360,
            height: showsAdvanced ? (activeColorTarget == nil ? 590 : 680) : 330
        )
        .animation(.easeInOut(duration: 0.16), value: showsAdvanced)
        .animation(.easeInOut(duration: 0.16), value: activeColorTarget)
        .onExitCommand {
            if activeColorTarget != nil {
                activeColorTarget = nil
            } else {
                onCancel()
                dismiss()
            }
        }
        .fileImporter(
            isPresented: $showsImageImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                await controller.stageBackground(from: url)
            }
        }
    }

    private var presetBinding: Binding<QuickNoteThemePreset> {
        Binding(
            get: { controller.selectedPreset },
            set: { controller.applyPreset($0) }
        )
    }

    private var fontFamilies: [String] {
        let preferred = ["SF Pro", "Helvetica Neue", "Avenir Next", "Menlo", "PingFang SC"]
        return preferred + NSFontManager.shared.availableFontFamilies
            .filter { !preferred.contains($0) }
            .sorted()
    }

    private func appearanceBinding<Value>(
        _ keyPath: WritableKeyPath<QuickNoteAppearance, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.preview[keyPath: keyPath] },
            set: { value in controller.updateDraft { $0[keyPath: keyPath] = value } }
        )
    }

    private func backgroundBinding<Value>(
        _ keyPath: WritableKeyPath<QuickNoteBackground, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.preview.background[keyPath: keyPath] },
            set: { value in
                controller.updateDraft { $0.background[keyPath: keyPath] = value }
            }
        )
    }

    private func colorBinding(
        _ keyPath: WritableKeyPath<QuickNoteAppearance, QuickNoteColor>
    ) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: controller.preview[keyPath: keyPath].nsColor) },
            set: { color in
                let value = QuickNoteColor.hex(PathUtilities.hexString(NSColor(color), includeAlpha: true))
                controller.updateDraft { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func backgroundColorBinding(
        _ keyPath: WritableKeyPath<QuickNoteBackground, QuickNoteColor>
    ) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: controller.preview.background[keyPath: keyPath].nsColor) },
            set: { color in
                let value = QuickNoteColor.hex(PathUtilities.hexString(NSColor(color), includeAlpha: true))
                controller.updateDraft { $0.background[keyPath: keyPath] = value }
            }
        )
    }

    private var borderColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: PathUtilities.hexColor(controller.preview.borderColor)) },
            set: { color in
                let value = PathUtilities.hexString(NSColor(color), includeAlpha: true)
                controller.updateDraft { $0.borderColor = value }
            }
        )
    }

    @ViewBuilder
    private func colorEditorRow(
        _ title: String,
        target: ColorTarget,
        binding: Binding<Color>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    activeColorTarget = activeColorTarget == target ? nil : target
                }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(InlineColorEditor.hexString(for: binding.wrappedValue))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(binding.wrappedValue)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(.primary.opacity(0.18), lineWidth: 0.75))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(activeColorTarget == target ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RepotraHoverButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(InlineColorEditor.hexString(for: binding.wrappedValue))
            .accessibilityIdentifier("quick-note-color-\(target.rawValue)")

            if activeColorTarget == target {
                InlineColorEditor(color: binding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}

struct InlineColorEditor: View {
    @Binding var color: Color

    @State private var hexText: String
    @State private var validationMessage: String?
    @FocusState private var isHexFocused: Bool

    private static let swatches = [
        "#FFFFFFFF", "#F2F2F7FF", "#D1D1D6FF", "#8E8E93FF", "#1C1C1EFF", "#000000FF",
        "#FF453AFF", "#FF9F0AFF", "#FFD60AFF", "#30D158FF", "#64D2FFFF", "#0A84FFFF",
        "#5E5CE6FF", "#BF5AF2FF", "#FF375FFF", "#8E6F47FF", "#FFF3C4FF", "#202124FF",
    ]

    init(color: Binding<Color>) {
        _color = color
        _hexText = State(initialValue: Self.hexString(for: color.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 9), spacing: 8) {
                ForEach(Self.swatches, id: \.self) { hex in
                    Button {
                        guard let swatch = Self.color(from: hex) else { return }
                        applyColor(swatch)
                    } label: {
                        Circle()
                            .fill(Self.color(from: hex) ?? .clear)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.primary.opacity(0.16), lineWidth: 0.75))
                            .overlay {
                                if Self.hexString(for: color) == hex {
                                    Circle().stroke(.primary.opacity(0.72), lineWidth: 2)
                                        .padding(-3)
                                }
                            }
                    }
                    .buttonStyle(RepotraHoverButtonStyle(
                        isSelected: Self.hexString(for: color) == hex
                    ))
                    .accessibilityLabel("颜色 \(hex)")
                }
            }

            SaturationBrightnessField(
                hue: hueBinding,
                saturation: saturationBinding,
                brightness: brightnessBinding
            )
            .frame(height: 112)
            .accessibilityLabel("饱和度与亮度")

            LabeledColorTrack(
                title: "色相",
                value: hueBinding,
                gradient: Gradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
                    Color(hue: $0, saturation: 1, brightness: 1)
                })
            )
            LabeledColorTrack(
                title: "透明度",
                value: alphaBinding,
                gradient: Gradient(colors: [opaqueRGB.opacity(0), opaqueRGB])
            )

            HStack(spacing: 8) {
                Text("HEX")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("#RRGGBBAA", text: $hexText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($isHexFocused)
                    .onSubmit(commitHex)
                    .accessibilityLabel("十六进制颜色")
                if validationMessage == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("quick-note-color-error")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: Self.hexString(for: color)) { _, newValue in
            if !isHexFocused { hexText = newValue }
        }
        .onChange(of: isHexFocused) { _, focused in
            if !focused { commitHex() }
        }
    }

    private var rgba: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        converted.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness, alpha)
    }

    private var opaqueRGB: Color {
        Color(hue: Double(rgba.hue), saturation: Double(rgba.saturation), brightness: Double(rgba.brightness))
    }

    private var hueBinding: Binding<Double> {
        componentBinding(\.hue)
    }

    private var saturationBinding: Binding<Double> {
        componentBinding(\.saturation)
    }

    private var brightnessBinding: Binding<Double> {
        componentBinding(\.brightness)
    }

    private var alphaBinding: Binding<Double> {
        componentBinding(\.alpha)
    }

    private func componentBinding(
        _ keyPath: WritableKeyPath<(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat), CGFloat>
    ) -> Binding<Double> {
        Binding(
            get: { Double(rgba[keyPath: keyPath]) },
            set: { newValue in
                var components = rgba
                components[keyPath: keyPath] = CGFloat(min(1, max(0, newValue)))
                let updated = Color(
                    hue: Double(components.hue),
                    saturation: Double(components.saturation),
                    brightness: Double(components.brightness),
                    opacity: Double(components.alpha)
                )
                applyColor(updated)
            }
        )
    }

    private func commitHex() {
        guard let parsed = Self.color(from: hexText) else {
            validationMessage = "请输入 #RRGGBB 或 #RRGGBBAA 格式的颜色。"
            return
        }
        applyColor(parsed)
    }

    private func applyColor(_ value: Color) {
        color = value
        hexText = Self.hexString(for: value)
        validationMessage = nil
    }

    static func hexString(for color: Color) -> String {
        PathUtilities.hexString(NSColor(color), includeAlpha: true)
    }

    private static func color(from value: String) -> Color? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let raw = UInt64(text, radix: 16) else { return nil }
        let normalized = text.count == 6 ? (raw << 8) | 0xFF : raw
        return Color(
            red: Double((normalized >> 24) & 0xFF) / 255,
            green: Double((normalized >> 16) & 0xFF) / 255,
            blue: Double((normalized >> 8) & 0xFF) / 255,
            opacity: Double(normalized & 0xFF) / 255
        )
    }
}

private struct SaturationBrightnessField: View {
    let hue: Binding<Double>
    let saturation: Binding<Double>
    let brightness: Binding<Double>

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [.white, Color(hue: hue.wrappedValue, saturation: 1, brightness: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(.clear)
                    .stroke(.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: 14, height: 14)
                    .position(
                        x: saturation.wrappedValue * proxy.size.width,
                        y: (1 - brightness.wrappedValue) * proxy.size.height
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.14), lineWidth: 0.75))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    saturation.wrappedValue = Double(
                        min(1, max(0, value.location.x / max(1, proxy.size.width)))
                    )
                    brightness.wrappedValue = Double(
                        min(1, max(0, CGFloat(1) - value.location.y / max(1, proxy.size.height)))
                    )
                }
            )
        }
    }
}

private struct LabeledColorTrack: View {
    let title: String
    let value: Binding<Double>
    let gradient: Gradient

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                    Circle()
                        .fill(.white)
                        .stroke(.black.opacity(0.25), lineWidth: 0.75)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .frame(width: 14, height: 14)
                        .offset(x: value.wrappedValue * max(0, proxy.size.width - 14))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        value.wrappedValue = min(1, max(0, drag.location.x / max(1, proxy.size.width)))
                    }
                )
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                value.wrappedValue = min(1, max(0, value.wrappedValue + delta))
            }
        }
    }
}
