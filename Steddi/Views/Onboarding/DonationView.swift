import SwiftUI
import StoreKit

struct DonationView: View {
    /// When presented from onboarding the flow sits on a FIXED dark cinematic
    /// backdrop, so the sheet is pinned dark to avoid a bright-white flash at the
    /// end of the dark onboarding regardless of the chosen theme. From Settings /
    /// Home it honors the resolved Steddi theme like every other sheet.
    var fromOnboarding = false

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ThemeModeEx.defaultsKey) private var themeModeEx: String = ThemeModeEx.dynamic.rawValue
    @AppStorage("accentColor") private var accentColor: String = SteddiTheme.AccentOption.lavender.rawValue

    // StoreKit product IDs — configure in App Store Connect
    private let tipProductIDs = [
        "com.steddi.tip.small",
        "com.steddi.tip.medium",
        "com.steddi.tip.large"
    ]

    @State private var products: [Product] = []
    @State private var purchaseInProgress = false
    @State private var showThankYou = false

    /// A presented sheet gets its own presentation context and does not reliably
    /// inherit the presenter's `.preferredColorScheme`, so pin the app theme here
    /// too (mirrors SettingsView/CommuteListView). From onboarding we force dark
    /// so the final beat doesn't flash white after the dark cinematic flow.
    private var resolvedColorScheme: ColorScheme? {
        fromOnboarding ? .dark : (ThemeModeEx(rawValue: themeModeEx) ?? .dynamic).colorScheme
    }

    // The Steddi surface/text tokens are resolved by `ThemeEngine` from the app
    // theme, NOT by the pinned SwiftUI `colorScheme` — so pinning `.dark` alone
    // would still let a light-resolved theme paint a bright sheet at the end of
    // the dark onboarding. From onboarding we therefore drive the sheet's surface
    // and copy from the SAME fixed dark tokens the onboarding cards use, so the
    // final beat stays dark in every theme; from Settings/Home we use the
    // adaptive theme tokens like every other sheet.
    private var sheetSurface: Color {
        fromOnboarding ? SteddiTheme.onboardingCardFallbackFill : SteddiTheme.surfacePrimary
    }
    private var sheetTextPrimary: Color {
        fromOnboarding ? SteddiTheme.onboardingTextPrimary : SteddiTheme.textPrimary
    }
    private var sheetTextSecondary: Color {
        fromOnboarding ? SteddiTheme.onboardingTextSecondary : SteddiTheme.textSecondary
    }
    /// Tip-row fill: a faint light wash on the dark onboarding surface (matching
    /// the onboarding cards), the adaptive elevated surface elsewhere.
    private var tipRowFill: Color {
        fromOnboarding ? Color.white.opacity(0.1) : SteddiTheme.surfaceSecondary
    }
    /// Accent for icons/prices. On the fixed-dark onboarding sheet use the raw
    /// brand hue (`accentBrand`) — `accent` is luminance-shifted for the *theme*
    /// surface (which may be light), so it could darken against the dark sheet.
    /// Elsewhere use the surface-aware text-safe `accent`.
    private var sheetAccent: Color {
        fromOnboarding ? SteddiTheme.accentBrand : SteddiTheme.accent
    }

    var body: some View {
        let _ = accentColor // force a re-render when the accent changes
        return NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(sheetAccent)

                    Text("Support Steddi")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(sheetTextPrimary)

                    Text("Steddi is free. No ads, no subscriptions, no data selling. Just a tool that works for you.")
                        .font(.body)
                        .foregroundStyle(sheetTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Tip amounts
                if showThankYou {
                    VStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .font(.largeTitle)
                            .foregroundStyle(sheetAccent)
                        Text("Thank you!")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(sheetTextPrimary)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    VStack(spacing: 12) {
                        if products.isEmpty {
                            // Fallback display before products load
                            ForEach(fallbackTips, id: \.label) { tip in
                                tipButton(label: tip.label, price: tip.price) {
                                    // Products not loaded yet
                                }
                            }
                        } else {
                            ForEach(products.sorted(by: { $0.price < $1.price })) { product in
                                tipButton(label: product.displayName, price: product.displayPrice) {
                                    Task { await purchase(product) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 40)
                }

                Spacer()

                // Dismiss
                Button("Maybe later") {
                    dismiss()
                }
                .font(.body)
                .foregroundStyle(sheetTextSecondary)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(sheetSurface.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(sheetTextSecondary)
                    }
                }
            }
            .task {
                await loadProducts()
            }
        }
        .preferredColorScheme(resolvedColorScheme)
    }

    private func tipButton(label: String, price: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(sheetTextPrimary)
                Spacer()
                // Price in the accent so the tappable amount reads as the action,
                // not a link-blue default.
                Text(price)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(sheetAccent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(tipRowFill, in: RoundedRectangle(cornerRadius: 12))
        }
        // `.plain` so the label/price keep their explicit theme colors instead of
        // the default button tint painting them link-blue.
        .buttonStyle(.plain)
        .disabled(purchaseInProgress)
    }

    private var fallbackTips: [(label: String, price: String)] {
        [
            ("Small tip", "$1.99"),
            ("Medium tip", "$4.99"),
            ("Large tip", "$9.99")
        ]
    }

    private func loadProducts() async {
        do {
            products = try await Product.products(for: tipProductIDs)
        } catch {
            // Silently fail — fallback UI is fine
        }
    }

    private func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                // Only deliver + finish a *verified* transaction. Tips are
                // consumables, so StoreKit keeps the transaction in the queue
                // (and re-delivers it via Transaction.updates on every launch)
                // until we call finish() — do it after recording the thank-you.
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    withAnimation {
                        showThankYou = true
                    }
                    // Auto-dismiss after showing thanks
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        dismiss()
                    }
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            // Purchase failed — no aggressive error, just let them try again
        }
    }
}

/// Finishes any tip transactions that StoreKit delivers out-of-band — e.g. a
/// purchase that completed while the sheet was closed, an Ask-to-Buy approval,
/// or a transaction left unfinished by a prior version. Without a live
/// `Transaction.updates` listener these consumables would otherwise sit in the
/// queue forever and re-deliver on every launch. Started once at app launch.
enum TipTransactionObserver {
    private static var task: Task<Void, Never>?

    static func start() {
        guard task == nil else { return }
        task = Task.detached {
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                // Tips are consumables with nothing to unlock; just finalize so
                // the transaction leaves the queue and stops re-delivering.
                await transaction.finish()
            }
        }
    }
}

#Preview {
    DonationView()
}
