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
                    TextField("請在此處輸入Cookie", text: $key, axis: .vertical)
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
                    Text("用Cookie登錄")
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
            .navigationTitle("ExKey 登錄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isTesting {
                        ProgressView()
                    } else {
                        Button("好", action: logIn)
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
            Text("格式是 32 碼的 pass hash, 接著 member id, 然後 x 加上 igneous。")
        } else if let parsed {
            Label("格式正確 · member id \(parsed.memberID)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("格式不太對呦, 再檢查一下", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private func message(for status: ProbeStatus) -> String {
        switch status {
        case .networkFailed: "Cookie 存好了, 但是連不上 ExHentai, 等等在設定頁看看狀態"
        case .parseFailed, .notLoggedIn: "ExHentai 沒有認這組 Cookie (只看到熊貓), 檢查一下 igneous 吧"
        case .testing, .success: ""
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
                model.toasts.show("登入成功", kaomoji: "O3Ob")
                dismiss()
            }
        }
    }
}
