#if canImport(SwiftUI)
import SwiftUI

/// Floating search bar for finding and navigating text occurrences within the active webpage.
public struct BrowserFindInPageView: View {
    @Binding public var query: String
    public let result: BrowserFindInPageResult
    public let onPrevious: () -> Void
    public let onNext: () -> Void
    public let onDone: () -> Void

    @FocusState private var isFieldFocused: Bool

    public init(
        query: Binding<String>,
        result: BrowserFindInPageResult,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self._query = query
        self.result = result
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onDone = onDone
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Search Input Field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Find in Page...", text: $query)
                    .focused($isFieldFocused)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .onSubmit {
                        onNext()
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            #if canImport(UIKit)
            .background(Color(UIColor.tertiarySystemFill))
            #else
            .background(Color.secondary.opacity(0.12))
            #endif
            .cornerRadius(10)

            // Match Count Pill
            if !query.isEmpty {
                Text(result.displayString)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(result.matchCount > 0 ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    #if canImport(UIKit)
                    .background(Color(UIColor.secondarySystemFill))
                    #else
                    .background(Color.secondary.opacity(0.1))
                    #endif
                    .cornerRadius(6)
            }

            // Previous Button (Chevron Up)
            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .disabled(result.matchCount == 0)

            // Next Button (Chevron Down)
            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .disabled(result.matchCount == 0)

            // Done Button
            Button("Done") {
                onDone()
            }
            .font(.body.weight(.semibold))
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        #if canImport(UIKit)
        .background(Color(UIColor.secondarySystemBackground).shadow(color: .black.opacity(0.12), radius: 6, y: 3))
        #else
        .background(Color.secondary.opacity(0.18))
        #endif
        .onAppear {
            isFieldFocused = true
        }
    }
}
#endif
