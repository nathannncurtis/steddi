import SwiftUI
import StoreKit

struct DonationView: View {
    @Environment(\.dismiss) private var dismiss

    // StoreKit product IDs — configure in App Store Connect
    private let tipProductIDs = [
        "com.steddi.tip.small",
        "com.steddi.tip.medium",
        "com.steddi.tip.large"
    ]

    @State private var products: [Product] = []
    @State private var purchaseInProgress = false
    @State private var showThankYou = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.brown)

                    Text("Support Steddi")
                        .font(.title2.weight(.bold))

                    Text("Steddi is free. No ads, no subscriptions, no data selling. Just a tool that works for you.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Tip amounts
                if showThankYou {
                    VStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.pink)
                        Text("Thank you!")
                            .font(.title3.weight(.semibold))
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
                .foregroundStyle(.secondary)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await loadProducts()
            }
        }
    }

    private func tipButton(label: String, price: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.body.weight(.medium))
                Spacer()
                Text(price)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12))
        }
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
