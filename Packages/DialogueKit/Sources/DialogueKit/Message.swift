import Foundation

public struct Message: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
