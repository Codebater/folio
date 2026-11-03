import SwiftUI

/// Where Paperwire's legal pages live. The App Store listing links the same
/// addresses.
enum LegalLinks {
    static let privacy = URL(string: "https://www.graphiq.art/paperwire/privacy")!
    static let terms = URL(string: "https://www.graphiq.art/paperwire/terms")!
    static let source = URL(string: "https://github.com/Codebater/folio")!
}

/// The software and voices Paperwire is built with, and the licences that
/// travel with them. The Supertonic voices' licence asks for a copy to come
/// with them, and its use restrictions are part of the Terms of Use.
struct LicencesView: View {
    private struct Component: Identifiable {
        let name: String
        let detail: String
        let licence: String
        /// A licence text in the app bundle (Resources/Licences).
        let file: String?
        var id: String { name }
    }

    private let components = [
        Component(name: "Supertonic-3 voices", detail: "Ivy and our other Supertonic voices, by Supertone Inc.",
                  licence: "BigScience OpenRAIL-M", file: "Supertonic-3-OpenRAIL-M"),
        Component(name: "FluidAudio", detail: "Runs the natural voices on the iPhone, by FluidInference",
                  licence: "Apache License 2.0", file: "Apache-2.0"),
        Component(name: "Kokoro-82M", detail: "A natural voice you can download, by hexgrad",
                  licence: "Apache License 2.0", file: "Apache-2.0"),
        Component(name: "Paradee-8M", detail: "A natural voice you can download, by Sahil Mahendrakar",
                  licence: "Apache License 2.0", file: "Apache-2.0"),
        Component(name: "SQLite", detail: "The database that keeps your library", licence: "Public domain", file: nil),
    ]

    var body: some View {
        List {
            Section {
                ForEach(components) { component in
                    if let file = component.file {
                        NavigationLink {
                            LicenceTextView(title: component.licence, file: file)
                        } label: {
                            row(component)
                        }
                    } else {
                        row(component)
                    }
                }
            } footer: {
                Text("The Supertonic voices' use restrictions are part of Paperwire's Terms of Use. Paperwire's own source code is public under the Functional Source License (FSL-1.1-ALv2).")
            }
            Section {
                Link("Terms of Use", destination: LegalLinks.terms)
                Link("Privacy Policy", destination: LegalLinks.privacy)
            }
        }
        .navigationTitle("Licences")
    }

    private func row(_ component: Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(component.name)
            Text(component.detail).font(.caption).foregroundStyle(.secondary)
            Text(component.licence).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A licence's full text, as shipped in the app.
struct LicenceTextView: View {
    let title: String
    let file: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The licence text is missing from this build." }
        return text
    }
}
