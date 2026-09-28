import DaiHentaiCore
import SwiftUI

/// 「ExKey 登錄」: paste `<pass hash><member id>x<igneous>`. Checked as you type; 好 writes the
/// cookies and only says 登入成功 after ExHentai actually answers.
struct ExKeyLoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var isTesting = false
    @State private var result: ProbeStatus?
    @FocusState private var isFocused: Bool

    private var parsed: ExSession.ExKey? { ExSession.parse(exKey: key) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(.exKeyPlaceholder, text: $key, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($isFocused)
                        .accessibilityIdentifier("exKeyField")
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { key = first }
                    }
                    .labelStyle(.titleAndIcon)
                } header: {
                    Text(.exKeyHeader)
                } footer: {
                    validation
                }

                if let result, result != .success {
                    Section {
                        Label(message(for: result), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(.settingsExKeyLogIn)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.commonCancel, systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isTesting {
                        ProgressView()
                    } else {
                        Button(.commonOkay) { logIn() }
                            .disabled(parsed == nil)
                            .accessibilityIdentifier("exKeyConfirm")
                    }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var validation: some View {
        if key.isEmpty {
            Text(.exKeyFormatHint)
        } else if let parsed {
            Label(.exKeyValid(parsed.memberID), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label(.exKeyInvalid, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func message(for status: ProbeStatus) -> LocalizedStringResource {
        switch status {
        case .networkFailed, .testing, .success: .exKeyNetworkFailed
        case .parseFailed, .notLoggedIn: .exKeyRejected
        }
    }

    private func logIn() {
        isTesting = true
        result = nil
        Task {
            let status = await model.logIn(exKey: key)
            isTesting = false
            result = status
            if status == .success {
                model.toasts.show(.commonLoggedIn, kaomoji: "O3Ob")
                dismiss()
            }
        }
    }
}
