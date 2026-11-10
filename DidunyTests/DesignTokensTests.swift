import AppKit
@testable import Diduny
import SwiftUI
import Testing

/// TS-CON-01 and TS-CON-02 (docs/design/panels-and-capabilities-redesign/test-plan.md 4.11).
/// Expected values are design-spec.md 1.1 (with the D1 to D3 build values) and the 1.3 contrast table.
struct DesignTokensTests {
    // MARK: - Fixtures

    enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case light, dark

        var appearance: NSAppearance? {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)
        }

        var testDescription: String { rawValue }
    }

    /// One row per colour role in design-spec 1.1: asset name, light hex, dark hex.
    enum Token: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case accent, accentFill, accentText, tint
        case window, sidebar, panel, chip, box, card, line
        case text, secondary
        case ok, okFill, no, warn

        var assetName: String {
            switch self {
            case .accent: "BrandAccentDeep"
            case .accentFill: "BrandAccentFill"
            case .accentText: "BrandAccentText"
            case .tint: "BrandTintSoft"
            case .window: "SurfaceWindow"
            case .sidebar: "SurfaceSidebar"
            case .panel: "SurfacePanel"
            case .chip: "SurfaceChip"
            case .box: "SurfaceBox"
            case .card: "SurfaceCard"
            case .line: "Hairline"
            case .text: "TextPrimary"
            case .secondary: "TextSecondary"
            case .ok: "StatusOk"
            case .okFill: "StatusOkFill"
            case .no: "StatusNo"
            case .warn: "StatusWarn"
            }
        }

        var specHex: (light: UInt32, dark: UInt32) {
            switch self {
            case .accent: (0xC42A4D, 0xE8486B)
            case .accentFill: (0xC42A4D, 0xD2365A)
            case .accentText: (0xAE2143, 0xFF8FA6)
            case .tint: (0xFCEDF1, 0x3A2129)
            case .window: (0xF6F6F8, 0x232326)
            case .sidebar: (0xE6E6EA, 0x2A2A2D)
            case .panel: (0xF4F4F6, 0x2B2B2E)
            case .chip: (0xE4E4E8, 0x3A3A3E)
            case .box: (0xEBEBEF, 0x202023)
            case .card: (0xFFFFFF, 0x2F2F32)
            case .line: (0xD9D9DE, 0x3A3A3E)
            case .text: (0x1D1D1F, 0xF5F5F7)
            case .secondary: (0x63636A, 0xA6A6AD)
            case .ok: (0x1B7A35, 0x4CC270) // D1
            case .okFill: (0x1B7A35, 0x1F8A3E) // D2
            case .no: (0xB02A22, 0xFF8075) // D3
            case .warn: (0x8F5600, 0xE3A53A)
            }
        }

        var paletteColor: Color {
            switch self {
            case .accent: DS.Palette.accent
            case .accentFill: DS.Palette.accentFill
            case .accentText: DS.Palette.accentText
            case .tint: DS.Palette.tint
            case .window: DS.Palette.window
            case .sidebar: DS.Palette.sidebar
            case .panel: DS.Palette.panel
            case .chip: DS.Palette.chip
            case .box: DS.Palette.box
            case .card: DS.Palette.card
            case .line: DS.Palette.line
            case .text: DS.Palette.text
            case .secondary: DS.Palette.secondary
            case .ok: DS.Palette.ok
            case .okFill: DS.Palette.okFill
            case .no: DS.Palette.no
            case .warn: DS.Palette.warn
            }
        }

        var testDescription: String { "\(rawValue) (\(assetName))" }
    }

    /// Foreground or background of a contrast pair: a token, or white (`Color.white`, on fills).
    enum Ink: Sendable, CustomStringConvertible {
        case token(Token)
        case white

        var description: String {
            switch self {
            case let .token(token): token.rawValue
            case .white: "white"
            }
        }
    }

    struct ContrastPair: Sendable, CustomTestStringConvertible {
        let foreground: Ink
        let background: Ink
        let needs: Double
        let usedFor: String

        var testDescription: String { "\(foreground) on \(background) >= \(needs) (\(usedFor))" }
    }

    /// Every row of design-spec 1.3 that has a "Needs" value for a built colour.
    /// Not here: rows that record prototype-only values (white on accent, white on prototype
    /// ok, prototype ok and no), the drawn switch replaced by the native one (D4), the exempt
    /// decorative rows (chip track, line), and the notch preview literals (not tokens).
    static let contrastPairs: [ContrastPair] = {
        let text = 4.5
        let graphic = 3.0
        let surfaces: [Token] = [.panel, .box, .card, .chip, .tint, .window, .sidebar]
        var pairs: [ContrastPair] = []
        for surface in surfaces {
            pairs.append(ContrastPair(foreground: .token(.text), background: .token(surface), needs: text, usedFor: "text"))
        }
        for surface in surfaces {
            pairs.append(ContrastPair(foreground: .token(.secondary), background: .token(surface), needs: text, usedFor: "secondary text"))
        }
        for surface: Token in [.tint, .panel, .box, .card, .window, .sidebar] {
            pairs.append(ContrastPair(foreground: .token(.accentText), background: .token(surface), needs: text, usedFor: "accent text"))
        }
        pairs += [
            ContrastPair(foreground: .white, background: .token(.accentFill), needs: text, usedFor: "Stop, selected segment, primary buttons"),
            ContrastPair(foreground: .white, background: .token(.okFill), needs: graphic, usedFor: "check glyph"),
            ContrastPair(foreground: .token(.okFill), background: .token(.window), needs: graphic, usedFor: "filled mark on window"),
            ContrastPair(foreground: .token(.okFill), background: .token(.tint), needs: graphic, usedFor: "filled mark in Diduny Cloud column"),
            ContrastPair(foreground: .token(.okFill), background: .token(.panel), needs: graphic, usedFor: "outcome square edge"),
            ContrastPair(foreground: .token(.ok), background: .token(.window), needs: text, usedFor: "Ready text"),
            ContrastPair(foreground: .token(.ok), background: .token(.chip), needs: graphic, usedFor: "mic level fill"),
            ContrastPair(foreground: .token(.no), background: .token(.chip), needs: text, usedFor: "danger button text"),
            ContrastPair(foreground: .token(.no), background: .token(.window), needs: graphic, usedFor: "cross mark"),
            ContrastPair(foreground: .token(.no), background: .token(.tint), needs: graphic, usedFor: "cross mark in Diduny Cloud column"),
            ContrastPair(foreground: .token(.warn), background: .token(.panel), needs: text, usedFor: "battery warning"),
            ContrastPair(foreground: .token(.warn), background: .token(.window), needs: text, usedFor: "silence countdown"),
            ContrastPair(foreground: .token(.accent), background: .token(.window), needs: graphic, usedFor: "half mark, mode icons"),
            ContrastPair(foreground: .token(.accent), background: .token(.tint), needs: graphic, usedFor: "level bars, field hover border"),
            ContrastPair(foreground: .token(.accent), background: .token(.panel), needs: graphic, usedFor: "status dot"),
            ContrastPair(foreground: .token(.accent), background: .token(.card), needs: graphic, usedFor: "tile icons"),
            ContrastPair(foreground: .token(.accent), background: .token(.chip), needs: graphic, usedFor: "progress fill"),
            ContrastPair(foreground: .white, background: .token(.accentFill), needs: graphic, usedFor: "keycap border"),
        ]
        return pairs
    }()

    // MARK: - TS-CON-01

    @Test("Colour token resolves to its spec hex", arguments: Token.allCases, Mode.allCases)
    func tokenResolvesToSpecHex(token: Token, mode: Mode) throws {
        let hex = mode == .light ? token.specHex.light : token.specHex.dark
        let expected = RGBA(hex: hex)
        let asset = try #require(NSColor(named: token.assetName), "missing colour set \(token.assetName)")

        let fromAsset = try #require(Self.resolve(asset, in: mode))
        let fromPalette = try #require(Self.resolve(NSColor(token.paletteColor), in: mode))

        #expect(fromAsset.isClose(to: expected), "asset \(token.assetName) \(mode): got \(fromAsset), want \(expected)")
        #expect(fromPalette.isClose(to: expected), "DS.Palette.\(token.rawValue) \(mode): got \(fromPalette), want \(expected)")
    }

    // MARK: - TS-CON-02

    @Test("Contrast pair meets its minimum", arguments: contrastPairs, Mode.allCases)
    func contrastPairMeetsMinimum(pair: ContrastPair, mode: Mode) throws {
        let foreground = try #require(Self.resolve(pair.foreground, in: mode))
        let background = try #require(Self.resolve(pair.background, in: mode))
        let ratio = foreground.contrastRatio(with: background)
        #expect(ratio >= pair.needs, "\(pair.testDescription), \(mode): \(ratio)")
    }

    // MARK: - Helpers

    private static func resolve(_ ink: Ink, in mode: Mode) -> RGBA? {
        switch ink {
        case .white: .white
        case let .token(token): resolve(NSColor(token.paletteColor), in: mode)
        }
    }

    private static func resolve(_ color: NSColor, in mode: Mode) -> RGBA? {
        guard let appearance = mode.appearance else { return nil }
        var result: RGBA?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            result = RGBA(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent),
                alpha: Double(srgb.alphaComponent)
            )
        }
        return result
    }
}

private struct RGBA: CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let white = RGBA(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Within 1/255 per channel; alpha must be 1.
    func isClose(to other: RGBA) -> Bool {
        let tolerance = 1.0 / 255 + 1e-9
        return abs(red - other.red) <= tolerance
            && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance
            && abs(alpha - other.alpha) <= 1e-9
    }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrastRatio(with other: RGBA) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    var description: String {
        String(format: "#%02X%02X%02X a%.3f", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()), alpha)
    }
}
