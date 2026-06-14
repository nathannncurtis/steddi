import UIKit

/// Custom UIKit trait carrying a monotonic "theme revision" counter.
///
/// The dynamic `SteddiTheme` surface/text colors are built with
/// `Color(UIColor { traitCollection in ... })`. A `UIColor` provider re-resolves
/// only when a trait it *reads* changes — so each provider reads this revision,
/// registering a dependency on it. The app root bumps the revision (via the
/// window's `traitOverrides`) on every `.steddiDynamicThemeUpdated`, which makes
/// every dynamic color in the hosted SwiftUI tree re-resolve against the latest
/// `ThemeEngine.snapshot` WITHOUT rebuilding any SwiftUI `@State`. That is how a
/// golden-hour / temperature / tunnel step reaches HomeView and the nav overlay
/// even though those files are never edited or `.id()`-reset.
struct ThemeRevisionTrait: UITraitDefinition {
    static let defaultValue = 0
    // Theme revision does not affect layout or text — it only re-resolves colors.
    static let affectsColorAppearance = true
}

extension UITraitCollection {
    var themeRevision: Int { self[ThemeRevisionTrait.self] }
}
