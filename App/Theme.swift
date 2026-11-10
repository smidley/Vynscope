import SwiftUI

/// vynscope.com's palette, from the asset catalog: the site's colors in light, its dark sections' colors in dark.
extension Color {
    static let vynIvory = Color("VynIvory"), vynPaper = Color("VynPaper"), vynInk = Color("VynInk")
    static let vynMuted = Color("VynMuted"), vynLine = Color("VynLine"), vynGreen = Color("VynGreen")
    static let vynOrangeDark = Color("VynOrangeDark"), vynOrange = Color("AccentColor")
    /// Errors and the active fault, toned to sit in the palette: #D42323 in light, #F26B6B in dark.
    static let vynRed = Color("VynRed")
}

/// A screen's one primary action against its quiet ones.
extension View {
    /// A filled button in the darker orange with paper text on it, which reads at 4.5 to 1 in both appearances. One
    /// per screen: Check my car, Read fault codes, Scan, Run health check, Back up, Send.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.vynOrangeDark)
            .foregroundStyle(Color.vynPaper)
    }

    /// The screen's other buttons in ink, so that its primary action is the only orange; a destructive button keeps
    /// its red and a disabled one its dimming.
    func quietButtons() -> some View {
        tint(Color.vynInk)
    }
}

/// vynscope.com's typefaces, bundled in `App/Fonts`.
extension Font {
    /// Manrope at the text style's size, scaling with Dynamic Type.
    static func vyn(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: style.pointSize, relativeTo: style).weight(weight)
    }

    /// IBM Plex Mono at the text style's size, for codes, addresses and hex.
    static func vynMono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom("IBM Plex Mono", size: style.pointSize, relativeTo: style).weight(weight)
    }
}

private extension Font.TextStyle {
    /// The style's point size at the default Dynamic Type size, as on the iPhone.
    var pointSize: CGFloat {
        switch self {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }
}
