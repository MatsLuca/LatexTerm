import Foundation

/// Shared folder boundary rule for session shortcuts and the reduced project tree.
enum HomeSessionScope {
    static func contains(_ child: String, in parent: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
