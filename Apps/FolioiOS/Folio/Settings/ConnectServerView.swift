import StoreKit
import SwiftUI
import FolioCore
import FolioFreshRSS

/// Connects a FreshRSS server through its Google Reader API. Nothing is
/// saved until the server accepts the credentials; the API password goes to
/// the Keychain only.
struct ConnectServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

    private var isInsecure: Bool { server.lowercased().hasPrefix("http://") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $server, prompt: Text("rss.example.com or vault.tailnet.ts.net:8091"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API password", text: $password)
                        .textContentType(.password)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("In FreshRSS, turn on API access under Settings › Authentication, then set an API password under Settings › Profile. It is separate from your login password.")
                        Text("Tailscale works too: use your server's MagicDNS name with HTTPS (Tailscale Serve).")
                    }
                }
                if isInsecure {
                    Section {
                        Label("This address uses plain HTTP. Only use it on a network you trust; iOS allows it for local addresses.",
                              systemImage: "lock.open.trianglebadge.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Text("Connect")
                            if isConnecting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(server.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
                }
            }
            .navigationTitle("FreshRSS")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.connect(server: server, username: username.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            dismiss()
        } catch {
            self.error = error.description
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showConnect = false
    @State private var showPicker = false
    @State private var isLoadingDemo = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 14) {
                Text("Paperwire")
                    .font(.system(size: 56, weight: .bold, design: .serif))
                Text("Your feeds, set like a book.\nRead them, or listen with every word highlighted, even offline.")
                    .font(.system(.title3, design: .serif))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                Button {
                    showPicker = true
                } label: {
                    Text("Choose what to read").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("choose-feeds")
                Button {
                    showConnect = true
                } label: {
                    Text("I use FreshRSS").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button {
                    isLoadingDemo = true
                    Task { await model.useDemo() }
                } label: {
                    HStack {
                        Text("Try the demo library")
                        if isLoadingDemo { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .accessibilityIdentifier("try-demo")
                Text("No account needed. Paperwire never sends your articles anywhere.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .background(Color("LaunchBackground").ignoresSafeArea())
        .sheet(isPresented: $showConnect) { ConnectServerView() }
        .fullScreenCover(isPresented: $showPicker) { FeedPickerView(mode: .start) }
    }
}

struct PremiumView: View {
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @State private var showManageSubscription = false

    /// Lifetime owners only see the Family upgrade; everyone else the three plans.
    private var offered: [Product] {
        if entitlements.state.canUpgradeToFamily {
            return entitlements.products.filter { $0.id == PremiumProduct.familyUpgrade.rawValue }
        }
        guard !entitlements.isPremium else { return [] }
        return entitlements.products.filter { $0.id != PremiumProduct.familyUpgrade.rawValue }
    }

    /// Only what Premium unlocks in this build: App Review rejects purchases
    /// that promise features the app doesn't have yet.
    private let features: [(String, String)] = [
        ("person.2.wave.2", "More natural voices, including our own Orion"),
        ("paintpalette", "Custom themes and letter spacing"),
        ("waveform", "Speeds above 2×, pitch and speed per voice"),
        ("person.wave.2", "A different voice for each feed"),
        ("character.book.closed", "Your own pronunciations, including regular expressions"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paperwire Premium").font(.system(.largeTitle, design: .serif, weight: .bold))
                        Text("Paperwire stays free for reading with every typeface, offline articles, FreshRSS, News Radio and listening with Ivy, our natural voice, or any Apple voice. Premium funds development and adds the extras.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    ForEach(features, id: \.1) { icon, text in Label(text, systemImage: icon) }
                }
                Section {
                    if entitlements.products.isEmpty {
                        if entitlements.isLoading { ProgressView() } else {
                            Text(entitlements.lastError ?? "Products are not available yet.").foregroundStyle(.secondary)
                        }
                    }
                    if entitlements.isPremium && !entitlements.state.canUpgradeToFamily {
                        Label(entitlements.state.isFamily ? "Premium is active for your family." : "Premium is active.",
                              systemImage: "checkmark.seal.fill")
                    }
                    ForEach(offered, id: \.id) { product in
                        Button {
                            Task { await entitlements.purchase(product) }
                        } label: {
                            LabeledContent {
                                Text(product.displayPrice).bold()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(product.displayName)
                                    Text(product.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if entitlements.state.activeProducts.contains(.yearly) {
                        Button("Manage subscription") { showManageSubscription = true }
                    }
                    Button("Restore purchases") { Task { await entitlements.restore() } }
                } footer: {
                    Text("Payment is charged to your Apple ID when you buy. The yearly plan renews automatically at the same price unless you cancel at least 24 hours before the year ends; manage or cancel it here or in Settings, under your name, then Subscriptions. Lifetime and Family Lifetime are one-time purchases. Family Lifetime, or the upgrade for Lifetime owners, is shared with up to five family members through Family Sharing.")
                }
                Section {
                    Link("Terms of Use", destination: LegalLinks.terms)
                    Link("Privacy Policy", destination: LegalLinks.privacy)
                }
            }
            .navigationTitle("")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $showManageSubscription)
        }
    }
}
