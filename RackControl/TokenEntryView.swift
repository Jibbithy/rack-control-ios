import SwiftUI

/// The one screen that writes a credential.
///
/// Two ways here: RootView shows it whenever there is no usable token (first
/// run, or the hub just answered 401 - see HubToken), and "Change token" in the
/// Rack tab's menu opens it as a sheet over a working app.
struct TokenEntryView: View {
    /// Set only for the sheet. Shows Cancel, and closes the sheet after a
    /// save. The old token keeps working until a new one has been PROVED, so
    /// backing out of a change costs nothing.
    var onClose: (() -> Void)? = nil

    @State private var typed = ""
    @State private var checking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sp4) {
                    DeckFormSection(title: "Hub token") {
                        VStack(alignment: .leading, spacing: Theme.sp3) {
                            // A 64-character token autocapitalised or autocorrected
                            // is a silent 401 that looks like the hub is broken.
                            TextField(
                                "x-rack-token", text: $typed,
                                prompt: Text(verbatim: "x-rack-token").foregroundStyle(Deck.muted),
                                axis: .vertical
                            )
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(2...4)
                            .textFieldStyle(DeckFieldStyle(invalid: problem != nil, mono: true))
                            Text(verbatim: "On atlas: cat /var/lib/rack-hub/token")
                                .font(Deck.mono(12, .regular, relativeTo: .footnote))
                                .foregroundStyle(Deck.muted)
                        }
                        .padding(14)
                    }

                    if let problem {
                        DeckErrorText(problem)
                    }

                    Button(checking ? "Checking…" : "Save") { Task { await check() } }
                        .buttonStyle(.deckPrimary)
                        .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                }
                .padding(Theme.sp4)
            }
            .background(Deck.ground)
            .navigationTitle("Rack Control")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onClose() }
                    }
                }
            }
        }
    }

    /// PROVE THE TOKEN BEFORE STORING IT. A typo committed to the Keychain
    /// would 401 on the first call and bounce straight back here - and, over
    /// "Change token", would have thrown away a token that worked.
    private func check() async {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        problem = nil
        defer { checking = false }
        if await HubClient.shared.validate(t) {
            // Keychain AND RootView's switch, in one step - see HubToken.
            HubToken.shared.saved(t)
            onClose?()
        } else {
            problem = "That token was rejected, or the rack is unreachable. Is Tailscale on?"
        }
    }
}
