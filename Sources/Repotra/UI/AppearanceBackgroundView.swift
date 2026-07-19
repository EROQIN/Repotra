import AppKit
import SwiftUI

enum RenderedBackgroundKind {
    case solid
    case gradient
    case image
}

struct RenderedBackground {
    var kind: RenderedBackgroundKind
    var primaryColor: NSColor
    var secondaryColor: NSColor
    var imageURL: URL?
    var imageScaling: StickyImageScaling
    var overlayColor: NSColor? = nil
    var overlayOpacity = 0.0

    static func sticky(_ background: StickyBackground, rootURL: URL) -> Self {
        Self(
            kind: background.kind == .image ? .image : background.kind == .gradient ? .gradient : .solid,
            primaryColor: PathUtilities.hexColor(background.primaryColor),
            secondaryColor: PathUtilities.hexColor(background.secondaryColor),
            imageURL: background.imagePath.map { rootURL.appending(path: $0) },
            imageScaling: background.imageScaling
        )
    }

    static func quickNote(_ background: QuickNoteBackground, backgroundsURL: URL) -> Self {
        let kind: RenderedBackgroundKind
        switch background.kind {
        case .system, .solid:
            kind = .solid
        case .gradient:
            kind = .gradient
        case .image:
            kind = .image
        }
        let primaryColor = background.kind == .system
            ? NSColor.textBackgroundColor
            : background.primaryColor.nsColor
        let secondaryColor = background.kind == .system
            ? NSColor.textBackgroundColor
            : background.secondaryColor.nsColor
        return Self(
            kind: kind,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            imageURL: background.imageFileName.map { backgroundsURL.appending(path: $0) },
            imageScaling: background.imageScaling
        )
    }

    static func app(_ background: AppBackgroundConfiguration, backgroundsURL: URL) -> Self {
        let normalized = background.normalized()
        let kind: RenderedBackgroundKind
        switch normalized.kind {
        case .system, .solid:
            kind = .solid
        case .gradient:
            kind = .gradient
        case .image:
            kind = .image
        }
        return Self(
            kind: kind,
            primaryColor: normalized.kind == .system
                ? .windowBackgroundColor
                : PathUtilities.hexColor(normalized.primaryColor),
            secondaryColor: normalized.kind == .system
                ? .windowBackgroundColor
                : PathUtilities.hexColor(normalized.secondaryColor),
            imageURL: normalized.imageFileName.map { backgroundsURL.appending(path: $0) },
            imageScaling: normalized.imageScaling,
            overlayColor: normalized.kind == .image ? normalized.imageOverlayColor : nil,
            overlayOpacity: normalized.kind == .image ? normalized.imageOverlayOpacity : 0
        )
    }
}

struct AppearanceBackgroundView: View {
    let presentation: RenderedBackground

    var body: some View {
        switch presentation.kind {
        case .solid:
            Color(nsColor: presentation.primaryColor)
        case .gradient:
            LinearGradient(
                colors: [
                    Color(nsColor: presentation.primaryColor),
                    Color(nsColor: presentation.secondaryColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .image:
            ZStack {
                imageBackground
                if let overlayColor = presentation.overlayColor,
                   presentation.overlayOpacity > 0
                {
                    Color(nsColor: overlayColor).opacity(presentation.overlayOpacity)
                }
            }
        }
    }

    @ViewBuilder
    private var imageBackground: some View {
        if let imageURL = presentation.imageURL,
           let image = NSImage(contentsOf: imageURL)
        {
            switch presentation.imageScaling {
            case .fill:
                Image(nsImage: image).resizable().scaledToFill().clipped()
            case .fit:
                ZStack {
                    Color(nsColor: presentation.primaryColor)
                    Image(nsImage: image).resizable().scaledToFit()
                }
            case .stretch:
                Image(nsImage: image).resizable()
            }
        } else {
            Color(nsColor: presentation.primaryColor)
        }
    }
}
