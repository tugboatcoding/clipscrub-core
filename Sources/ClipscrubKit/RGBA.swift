import CoreGraphics

/// A plain RGBA colour value used by the redaction primitives (e.g. `ImageRedactor`'s
/// default cover colour) and any compositor that builds on them.
public struct RGBA: Sendable, Hashable, Codable {
    public let red, green, blue, alpha: Double
    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
    public var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
}
