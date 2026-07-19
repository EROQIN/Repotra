import SwiftUI

struct BrandSpotImage: View {
    let name: String

    var body: some View {
        Group {
            if let image = NSImage(named: name) ?? loadBundledImage() {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable().scaledToFit().padding(18)
                    .foregroundStyle(.tint)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            }
        }
        .accessibilityHidden(true)
    }

    private func loadBundledImage() -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "SpotIcons")
            ?? bundle.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var fallbackSymbol: String {
        switch name {
        case "choose-library": "folder.badge.plus"
        case "no-search-results": "magnifyingglass"
        case "file-conflict": "exclamationmark.triangle"
        default: "doc.text"
        }
    }
}
