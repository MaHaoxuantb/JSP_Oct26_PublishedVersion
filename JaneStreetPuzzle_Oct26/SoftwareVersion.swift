/// Monotonic software release, independent of the wire framing protocol.
/// Bump for every change to code executed by a worker or coordinator (see AGENTS.md).
enum SoftwareVersion {
    static let current = 2
    static var description: String { "JSP_Oct26 v\(current)" }
    static func accepts(_ version: Int?, minimum: Int) -> Bool {
        guard minimum >= 0 && minimum <= current else { return false }
        return (minimum...current).contains(version ?? 0)
    }
}
