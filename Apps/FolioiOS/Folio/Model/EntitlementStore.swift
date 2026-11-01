import Foundation
import Observation
import StoreKit
import FolioCore

/// Premium via StoreKit 2. The entitlement logic (`EntitlementState`) is
/// portable and unit-tested; this class only talks to the App Store.
/// Products must exist in App Store Connect (and `Folio.storekit` for local
/// testing); nothing here fakes a purchase.
@MainActor
@Observable
final class EntitlementStore {
    private(set) var state = EntitlementState.free
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    @ObservationIgnored private var updates: Task<Void, Never>?

    var isPremium: Bool { state.isPremium }

    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: PremiumProduct.allCases.map(\.rawValue))
            let order = PremiumProduct.allCases.map(\.rawValue)
            products = loaded.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            lastError = nil
        } catch {
            lastError = "The App Store is not reachable right now."
        }
    }

    func refreshEntitlements() async {
        var active = Set<PremiumProduct>()
        var expiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil,
                  let product = PremiumProduct(rawValue: transaction.productID)
            else { continue }
            if let expiration = transaction.expirationDate {
                guard expiration > Date() else { continue }
                expiry = max(expiry ?? expiration, expiration)
            }
            active.insert(product)
        }
        state = EntitlementState(activeProducts: active, subscriptionExpiresAt: expiry)
    }

    func purchase(_ product: Product) async {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification { await transaction.finish() }
                await refreshEntitlements()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
            lastError = nil
        } catch {
            lastError = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = "Couldn't restore purchases: \(error.localizedDescription)"
        }
    }
}
