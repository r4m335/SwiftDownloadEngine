#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Lightweight localization helper backed by `NSLocalizedString` for all UI surfaces.
public enum L10n {
    public static func tr(_ key: String, comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }

    public static func tr(_ key: String, _ args: CVarArg..., comment: String = "") -> String {
        let format = NSLocalizedString(key, comment: comment)
        return String(format: format, arguments: args)
    }
}

/// Applies a system font whose point size scales with Dynamic Type via `@ScaledMetric`.
public struct ScaledSystemFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    public init(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) {
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: scaledSize, weight: weight, design: design))
    }
}

public extension View {
    /// Dynamic-Type-scaled replacement for fixed `.font(.system(size:weight:design:))`.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFontModifier(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}
#endif
