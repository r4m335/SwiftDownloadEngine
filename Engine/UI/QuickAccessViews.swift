#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Renders a responsive, compact icon for a Quick Access shortcut with favicon or monogram fallback.
public struct QuickAccessShortcutIconView: View {
    public let shortcut: QuickAccessShortcut
    public let size: CGFloat
    @State private var iconData: Data? = nil

    public init(shortcut: QuickAccessShortcut, size: CGFloat = 56) {
        self.shortcut = shortcut
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.regularMaterial)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)

            if let data = iconData,
               let platformImage = makeImage(from: data) {
                platformImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.52, height: size * 0.52)
                    .cornerRadius(6)
            } else {
                fallbackView
            }
        }
        .onAppear {
            loadFavicon()
        }
    }

    @ViewBuilder
    private var fallbackView: some View {
        let monogramLetter = monogram(for: shortcut.name)
        if !monogramLetter.isEmpty {
            Text(monogramLetter)
                .scaledFont(size: size * 0.40, weight: .bold, design: .rounded)
                .foregroundColor(.blue)
        } else {
            Image(systemName: "globe")
                .scaledFont(size: size * 0.42, weight: .medium)
                .foregroundColor(.blue)
        }
    }

    private func monogram(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first).uppercased()
    }

    private func makeImage(from data: Data) -> Image? {
        #if canImport(UIKit)
        if let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(data: data) {
            return Image(nsImage: nsImage)
        }
        #endif
        return nil
    }

    private func loadFavicon() {
        if let host = shortcut.url.host,
           let cached = FaviconService.shared.cachedFaviconData(for: host) {
            self.iconData = cached
            return
        }

        Task {
            if let data = await FaviconService.shared.fetchFaviconData(for: shortcut.url) {
                await MainActor.run {
                    self.iconData = data
                }
            }
        }
    }
}

/// Grid item card representing a single Quick Access shortcut.
public struct QuickAccessItemView: View {
    public let shortcut: QuickAccessShortcut
    public let onTap: () -> Void
    public let onOpenInNewTab: () -> Void
    public let onEdit: () -> Void
    public let onDelete: () -> Void
    public let onMoveLeft: () -> Void
    public let onMoveRight: () -> Void

    public init(
        shortcut: QuickAccessShortcut,
        onTap: @escaping () -> Void,
        onOpenInNewTab: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onMoveLeft: @escaping () -> Void,
        onMoveRight: @escaping () -> Void
    ) {
        self.shortcut = shortcut
        self.onTap = onTap
        self.onOpenInNewTab = onOpenInNewTab
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMoveLeft = onMoveLeft
        self.onMoveRight = onMoveRight
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                QuickAccessShortcutIconView(shortcut: shortcut, size: 56)

                Text(shortcut.name)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 68)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onTap()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }

            Button {
                onOpenInNewTab()
            } label: {
                Label("Open in New Tab", systemImage: "plus.square")
            }

            Divider()

            Button {
                onEdit()
            } label: {
                Label("Edit Shortcut", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Shortcut", systemImage: "trash")
            }

            Divider()

            Button {
                onMoveLeft()
            } label: {
                Label("Move Left", systemImage: "arrow.left")
            }

            Button {
                onMoveRight()
            } label: {
                Label("Move Right", systemImage: "arrow.right")
            }
        }
        .accessibilityLabel("\(shortcut.name), shortcut")
    }
}

/// Add shortcut cell displayed at the end of the Quick Access grid.
public struct QuickAccessAddButtonCell: View {
    public let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 56, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color.blue.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        )

                    Image(systemName: "plus")
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundColor(.blue)
                }

                Text("Add")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Quick Access shortcut")
    }
}

/// Sheet for adding a new Quick Access shortcut or editing an existing one.
public struct QuickAccessEditSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    public let editingShortcut: QuickAccessShortcut?
    public let onSave: (String, URL) -> Void

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var errorMessage: String? = nil

    public init(
        editingShortcut: QuickAccessShortcut? = nil,
        onSave: @escaping (String, URL) -> Void
    ) {
        self.editingShortcut = editingShortcut
        self.onSave = onSave
        _name = State(initialValue: editingShortcut?.name ?? "")
        _urlString = State(initialValue: editingShortcut?.url.absoluteString ?? "")
    }

    private var isValid: Bool {
        switch QuickAccessURLValidator.validate(name: name, urlString: urlString) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    public var body: some View {
        NavigationView {
            Form {
                if let error = errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Section(
                    header: Text("Website Details"),
                    footer: Text("Enter the website name and address. If you do not include https://, it will be added automatically.")
                ) {
                    TextField("Website Name (e.g. GitHub)", text: $name)
                        .disableAutocorrection(true)

                    TextField("Website URL (e.g. github.com)", text: $urlString)
                        #if canImport(UIKit)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)
                }

                if editingShortcut == nil {
                    Section(header: Text("Suggestions")) {
                        suggestionRow("YouTube", "https://youtube.com")
                        suggestionRow("Reddit", "https://reddit.com")
                        suggestionRow("Hacker News", "https://news.ycombinator.com")
                        suggestionRow("Internet Archive", "https://archive.org")
                    }
                }
            }
            .navigationTitle(editingShortcut == nil ? "Add Shortcut" : "Edit Shortcut")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.body.weight(.bold))
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func suggestionRow(_ title: String, _ url: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Text(url)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            name = title
            urlString = url
            errorMessage = nil
        }
    }

    private func save() {
        switch QuickAccessURLValidator.validate(name: name, urlString: urlString) {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let result):
            onSave(result.name, result.url)
            presentationMode.wrappedValue.dismiss()
        }
    }
}
#endif
