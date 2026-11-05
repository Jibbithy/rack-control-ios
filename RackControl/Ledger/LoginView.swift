import SwiftUI

/// The one screen that ever sends a password over the wire. It is never
/// stored - see SessionStore's comment for why only the session cookie that
/// comes back from a successful login is worth keeping in the Keychain.
struct LoginView: View {
    var onSignedIn: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sp4) {
                    DeckFormSection(title: "Sign in") {
                        VStack(spacing: Theme.sp3) {
                            TextField(
                                "Username", text: $username,
                                prompt: Text("Username").foregroundStyle(Deck.muted)
                            )
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focused, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focused = .password }
                            SecureField(
                                "Password", text: $password,
                                prompt: Text("Password").foregroundStyle(Deck.muted)
                            )
                            .textContentType(.password)
                            .focused($focused, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await attempt() } }
                        }
                        .textFieldStyle(DeckFieldStyle(invalid: problem != nil, mono: true))
                        .padding(14)
                    }

                    if let problem {
                        // Shown VERBATIM - see LedgerClient.login's comment. The hub
                        // returns the identical message for a wrong password and
                        // for a username that doesn't exist, and rewriting it here
                        // could reintroduce the distinction on this side.
                        DeckErrorText(problem)
                    }

                    Button(checking ? "Signing in…" : "Sign in") { Task { await attempt() } }
                        .buttonStyle(.deckPrimary)
                        .disabled(username.isEmpty || password.isEmpty || checking)
                }
                .padding(Theme.sp4)
            }
            .background(Deck.ground)
            .navigationTitle("Ledger")
        }
    }

    private func attempt() async {
        guard !username.isEmpty, !password.isEmpty, !checking else { return }
        checking = true
        problem = nil
        defer { checking = false }
        do {
            try await LedgerClient.shared.login(username: username, password: password)
            password = ""
            onSignedIn()
        } catch {
            problem = error.localizedDescription
            password = ""
        }
    }
}
