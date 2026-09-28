import Foundation
import LocalAuthentication

/// Face ID / Touch ID for the app lock. Passcode is normally not offered, keeping the old promise
/// "未來只可以透過指紋或是臉來解鎖, 密碼無法!" — except once when biometrics are no longer enrolled,
/// so nobody is locked out of their own app forever.
public enum BiometricAuthenticator {
    public enum Kind: Sendable {
        case faceID, touchID, opticID, none

        public var symbolName: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .none: "lock.fill"
            }
        }

        public var title: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .none: String(localized: .biometricAny)
            }
        }
    }

    public enum Outcome: Sendable, Equatable {
        case success
        case failed
        /// Too many failures; the device passcode must be entered on the lock screen first.
        case lockedOut
        /// No biometrics on this device.
        case unavailable
    }

    public static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// `kind` without blocking the caller (the check talks to a system daemon).
    @concurrent
    public static func currentKind() async -> Kind {
        kind
    }

    public static var kind: Kind {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// Biometric check. With `allowsPasscodeIfNotEnrolled`, a device whose biometrics were removed
    /// falls back to the passcode instead of trapping the user.
    @concurrent
    public static func authenticate(reason: String, allowsPasscodeIfNotEnrolled: Bool = false) async -> Outcome {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) ? .success : .failed
            } catch let error as LAError where error.code == .biometryLockout {
                return .lockedOut
            } catch {
                return .failed
            }
        }

        switch (error as? LAError)?.code {
        case .biometryLockout:
            return .lockedOut
        case .biometryNotEnrolled, .biometryNotAvailable:
            // Also covers the user revoking Face ID permission for the app in Settings.
            guard allowsPasscodeIfNotEnrolled else { return .unavailable }
            let fallback = LAContext()
            do {
                return try await fallback.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
            } catch let error as LAError where error.code == .passcodeNotSet {
                // No biometrics and no passcode: nothing can prove the owner, so don't pretend it failed.
                return .unavailable
            } catch {
                return .failed
            }
        default:
            return .unavailable
        }
    }
}
