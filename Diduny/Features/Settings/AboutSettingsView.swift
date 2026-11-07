import SwiftUI

/// About screen, ported from AppCat's AboutSettingsView (currentID = .diduny).
/// Update checks go through `MainWindowController` -> `AppDelegate.updaterManager` (Sparkle).
struct AboutSettingsView: View {
    private enum UpdateState: Equatable {
        case checking
        case upToDate
        case available
        case failed
    }

    @State private var latestVersion: String?
    @State private var updateState: UpdateState = .checking
    @State private var checkedToday = false

    private let currentID: AboutProduct.IDValue = .diduny

    var body: some View {
        PageScaffold(title: "About") {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                if updateState == .failed {
                    errorBanner
                }
                hero
                appGrid
                authorCard
                Text("Made in Ukraine · © 2024–2026 Roman Marinsky")
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.xs)
            }
        }
        .task { await loadLatestVersion() }
    }

    private var currentProduct: AboutProduct {
        AboutProduct.all.first { $0.id == currentID } ?? AboutProduct.all[0]
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            ProductMark(product: currentProduct, size: 76)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("About the app")
                    .font(DS.Font.headline)
                    .foregroundStyle(currentProduct.accentDeep)
                Text(currentProduct.name)
                    .font(DS.Font.settingsTitle)
                Text(currentProduct.description)
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.lg)

            updateCard
                .frame(width: 190)
        }
        .padding(DS.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(currentProduct.tintSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(currentProduct.tintBorder, lineWidth: 1)
        )
    }

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(updateHeadline)
                .font(DS.Font.headline)
                .foregroundStyle(currentProduct.accentDeep)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Space.xs) {
                versionLine("Current", value: currentVersionText)
                versionLine("Latest", value: latestText)
                versionLine("Checked", value: checkedToday ? String(localized: "today") : "—")
            }

            Button {
                MainWindowController.shared.checkForUpdates()
            } label: {
                Label(
                    updateState == .available ? "Update now" : "Check for updates",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(currentProduct.accentDeep)
            .controlSize(.small)
            .disabled(!MainWindowController.shared.canCheckForUpdates)
        }
        .padding(DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Palette.cardFill.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(currentProduct.tintBorder, lineWidth: 1)
        )
    }

    private var updateHeadline: LocalizedStringKey {
        switch updateState {
        case .available: "Update available"
        case .upToDate: "Diduny is up to date"
        case .checking, .failed: "Check for updates"
        }
    }

    private var latestText: String {
        switch updateState {
        case .checking: String(localized: "Checking…")
        case .failed: String(localized: "Unavailable")
        case .upToDate, .available: latestVersion ?? String(localized: "Unavailable")
        }
    }

    private func versionLine(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text(title).font(DS.Font.caption).foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.xs)
            Text(value).font(DS.Font.caption.weight(.semibold)).lineLimit(1)
        }
    }

    private var errorBanner: some View {
        Banner(message: Text("Couldn’t check for updates. Try again.")) {
            Button("Try again") { Task { await loadLatestVersion() } }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Grid

    private var appGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.md), count: 3),
            alignment: .leading,
            spacing: DS.Space.md
        ) {
            ForEach(AboutProduct.all) { product in
                AppPromoCard(product: product, isCurrent: product.id == currentID)
            }
        }
    }

    // MARK: - Author

    private var authorCard: some View {
        Card {
            HStack(alignment: .top, spacing: DS.Space.lg) {
                Text("RM")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(currentProduct.accentDeep)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Space.lg, style: .continuous).fill(DS.Palette.tintSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Space.lg, style: .continuous)
                            .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Author").font(DS.Font.headline).foregroundStyle(currentProduct.accentDeep)
                        Text("Roman Marinskyi").font(DS.Font.headline)
                        Text("I build practical macOS tools that remove small daily frictions from your work routine.")
                            .font(DS.Font.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                        spacing: 1
                    ) {
                        AuthorLinkRow(title: "Website", value: "rmarinsky.com.ua", icon: "globe", url: "https://rmarinsky.com.ua")
                        AuthorLinkRow(title: "GitHub", value: "@rmarinsky", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/rmarinsky")
                        AuthorLinkRow(title: "LinkedIn", value: "in/rmarinsky", icon: "briefcase", url: "https://linkedin.com/in/rmarinsky")
                        AuthorLinkRow(title: "YOY", value: String(localized: "event platform"), icon: "calendar", url: "https://yoy.fyi")
                        AuthorLinkRow(title: "Monobase", value: String(localized: "support development"), icon: "heart.fill", url: "https://base.monobank.ua/3yGFDUvCLJuNhm#subscriptions")
                    }
                    .background(DS.Palette.cardBorder)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Space.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Space.sm, style: .continuous)
                            .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - Version

    private var currentVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func loadLatestVersion() async {
        withAnimation(DS.Motion.easeOut(0.16)) { updateState = .checking }
        guard let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String, let url = URL(string: feed) else {
            withAnimation(DS.Motion.easeOut(0.16)) { updateState = .failed }
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let xml = String(data: data, encoding: .utf8) ?? ""
            let latest = Self.extractLatestVersion(from: xml)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            latestVersion = latest
            checkedToday = true
            withAnimation(DS.Motion.easeOut(0.16)) {
                if let latest, let current, latest.compare(current, options: .numeric) == .orderedDescending {
                    updateState = .available
                } else {
                    updateState = latest == nil ? .failed : .upToDate
                }
            }
        } catch {
            withAnimation(DS.Motion.easeOut(0.16)) { updateState = .failed }
        }
    }

    static func extractLatestVersion(from xml: String) -> String? {
        for marker in ["sparkle:shortVersionString=\"", "sparkle:version=\""] {
            if let value = quotedValue(after: marker, in: xml) { return value }
        }
        for tag in ["sparkle:shortVersionString", "sparkle:version"] {
            if let value = taggedValue(tag, in: xml) { return value }
        }
        return nil
    }

    private static func quotedValue(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func taggedValue(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound ..< text.endIndex)
        else { return nil }
        return String(text[start.upperBound ..< end.lowerBound])
    }
}

// MARK: - Pieces

private struct AppPromoCard: View {
    let product: AboutProduct
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(alignment: .center, spacing: DS.Space.sm) {
                ProductMark(product: product, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name).font(DS.Font.headline)
                    Text(product.tagline)
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if isCurrent {
                Text("You are here")
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundStyle(product.accentDeep)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 2)
                    .background(product.tintSoft, in: Capsule())
            }

            Text(product.description)
                .font(DS.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: DS.Space.sm) {
                if isCurrent {
                    Text("Installed")
                        .font(DS.Font.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.md)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Link(destination: product.downloadURL) { Text("Download") }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Link(destination: product.sourceURL) { Text("GitHub") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .background(DS.Palette.cardFill, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
    }
}

private struct AuthorLinkRow: View {
    let title: String
    let value: String
    let icon: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: icon)
                    .font(DS.Font.callout.weight(.medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 24, height: 24)
                    .background(DS.Palette.tintSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(title)).font(DS.Font.callout.weight(.medium)).foregroundStyle(.primary)
                    Text(value).font(DS.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(DS.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.md)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.cardFill)
        }
        .buttonStyle(.plain)
    }
}

private struct ProductMark: View {
    let product: AboutProduct
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(product.tintSoft)
            Image(systemName: product.systemImage)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(product.accentDeep)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(DS.Palette.cardBorder, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

private struct AboutProduct: Identifiable {
    enum IDValue: String { case diduny, papuga, appCat }

    let id: IDValue
    let name: String
    let tagline: String
    let description: String
    let systemImage: String
    let tintSoft: Color
    let tintBorder: Color
    let accentDeep: Color
    let downloadURL: URL
    let sourceURL: URL

    static let all: [AboutProduct] = [
        AboutProduct(
            id: .diduny,
            name: "Diduny",
            tagline: String(localized: "Dictation and transcription for macOS"),
            description: String(localized: "Press a key, say the thought, get clean text. Meeting recordings and Dynamic Notch feedback included."),
            systemImage: "mic.fill",
            tintSoft: DS.Palette.tintSoft,
            tintBorder: DS.Palette.tintBorder,
            accentDeep: DS.Palette.accent,
            downloadURL: URL(string: "https://github.com/rmarinsky/Diduny/releases/latest")!,
            sourceURL: URL(string: "https://github.com/rmarinsky/Diduny")!
        ),
        AboutProduct(
            id: .papuga,
            name: "Papuga",
            tagline: String(localized: "Fixes text typed in the wrong keyboard layout"),
            description: String(localized: "Select text, press a shortcut, get the right language without retyping."),
            systemImage: "bird.fill",
            tintSoft: Color(red: 234.0 / 255.0, green: 247.0 / 255.0, blue: 240.0 / 255.0),
            tintBorder: Color(red: 31.0 / 255.0, green: 175.0 / 255.0, blue: 92.0 / 255.0).opacity(0.18),
            accentDeep: Color(red: 23.0 / 255.0, green: 140.0 / 255.0, blue: 74.0 / 255.0),
            downloadURL: URL(string: "https://github.com/rmarinsky/papuga/releases/latest")!,
            sourceURL: URL(string: "https://github.com/rmarinsky/papuga")!
        ),
        AboutProduct(
            id: .appCat,
            name: "AppCat",
            tagline: String(localized: "Control where links and files open"),
            description: String(localized: "Routes URLs, browsers, profiles, and apps without copy-paste between Chrome, Safari, Slack, and IDEs."),
            systemImage: "cat.fill",
            tintSoft: DS.Palette.tintSoft,
            tintBorder: DS.Palette.tintBorder,
            accentDeep: DS.Palette.accent,
            downloadURL: URL(string: "https://github.com/rmarinsky/AppCat/releases/latest")!,
            sourceURL: URL(string: "https://github.com/rmarinsky/AppCat")!
        ),
    ]
}
