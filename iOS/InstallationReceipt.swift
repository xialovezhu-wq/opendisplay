import Foundation
import CryptoKit

/// Lets the paired local renewer verify the profile actually installed on the
/// iPad. Contains no certificate, account identifier, or keyboard content.
enum InstallationReceipt {
    static func write() {
        #if DEBUG
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: profileURL),
              let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else { return }
        let receipt: [String: String] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "profileSHA256": SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined(),
            "launchedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try data.write(to: documents.appendingPathComponent("opendisplay-installation.json"),
                           options: .atomic)
        } catch {
            Log.info("Installation receipt could not be saved.")
        }
        #endif
    }
}
