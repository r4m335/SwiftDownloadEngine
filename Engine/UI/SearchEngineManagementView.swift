#if canImport(SwiftUI)
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Management sheet and settings screen for configuring built-in and user-defined search engines.
public struct SearchEngineManagementView: View {
    @Environment(\.presentationMode) private var presentationMode
    public var onUpdate: (() -> Void)?

    @State private var activeEngineID: String = BrowserSearchEngine.duckDuckGo.rawValue
    @State private var customEngines: [CustomSearchEngine] = []
    @State private var isShowingAddSheet: Bool = false
    @State private var editingEngine: CustomSearchEngine? = nil
    @State private var feedbackBanner: String? = nil

    public init(onUpdate: (() -> Void)? = nil) {
        self.onUpdate = onUpdate
    }

    public var body: some View {
        NavigationView {
            Form {
                if let feedback = feedbackBanner {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(feedback)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer()
                            Button {
                                feedbackBanner = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // Section 1: Built-in Search Engines
                Section(
                    header: Text("Built-in Search Engines"),
                    footer: Text("Built-in search engines cannot be deleted or renamed.")
                ) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(engine.displayName)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(engine.urlTemplate)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if activeEngineID == engine.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.body.weight(.semibold))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectEngine(id: engine.rawValue)
                        }
                        .accessibilityLabel("\(engine.displayName), built-in\(activeEngineID == engine.rawValue ? ", selected" : "")")
                    }
                }

                // Section 2: Custom Search Engines
                Section(
                    header: HStack {
                        Text("Custom Search Engines")
                        Spacer()
                        Button {
                            editingEngine = nil
                            isShowingAddSheet = true
                        } label: {
                            Label("Add Engine", systemImage: "plus")
                                .font(.caption.weight(.semibold))
                        }
                    },
                    footer: Text("Add search engines using URL templates with '%s' as the query placeholder.")
                ) {
                    if customEngines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No Custom Search Engines")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                            Text("Tap '+' to add search engines like Kagi, Ecosia, GitHub, or Wikipedia.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(customEngines) { engine in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(engine.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let desc = engine.searchDescription, !desc.isEmpty {
                                            Text("• \(desc)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Text(engine.urlTemplate)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if activeEngineID == engine.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                        .font(.body.weight(.semibold))
                                }

                                Button {
                                    editingEngine = engine
                                    isShowingAddSheet = true
                                } label: {
                                    Image(systemName: "pencil.circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 4)
                                .accessibilityLabel("Edit \(engine.name)")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectEngine(id: engine.id)
                            }
                            .accessibilityLabel("\(engine.name), custom\(activeEngineID == engine.id ? ", selected" : "")")
                        }
                        .onDelete(perform: deleteCustomEngines)
                    }
                }
            }
            .navigationTitle("Search Engines")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if canImport(UIKit)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editingEngine = nil
                        isShowingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Custom Search Engine")
                }
                #else
                ToolbarItem {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem {
                    Button {
                        editingEngine = nil
                        isShowingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                #endif
            }
            .sheet(isPresented: $isShowingAddSheet) {
                AddOrEditSearchEngineSheet(
                    editingEngine: editingEngine,
                    onSave: { savedEngine in
                        saveCustomEngine(savedEngine)
                    }
                )
            }
            .onAppear {
                loadSettings()
            }
        }
    }

    private func loadSettings() {
        let settings = AppSettings.load()
        self.activeEngineID = settings.activeSearchEngineID
        self.customEngines = settings.customSearchEngines
    }

    private func selectEngine(id: String) {
        self.activeEngineID = id
        var settings = AppSettings.load()
        settings.activeSearchEngineID = id
        if let builtIn = BrowserSearchEngine(rawValue: id) {
            settings.browserSearchEngine = builtIn
        }
        settings.save()
        onUpdate?()
        feedbackBanner = "Selected search engine: \(settings.effectiveActiveSearchEngineName)"
    }

    private func deleteCustomEngines(at offsets: IndexSet) {
        var settings = AppSettings.load()
        var updated = customEngines
        let deletedIDs = offsets.map { updated[$0].id }
        updated.remove(atOffsets: offsets)
        self.customEngines = updated
        settings.customSearchEngines = updated

        // If the active engine was deleted, fallback safely to DuckDuckGo
        if deletedIDs.contains(settings.activeSearchEngineID) {
            settings.activeSearchEngineID = BrowserSearchEngine.duckDuckGo.rawValue
            settings.browserSearchEngine = .duckDuckGo
            self.activeEngineID = BrowserSearchEngine.duckDuckGo.rawValue
        }

        settings.save()
        onUpdate?()
    }

    private func saveCustomEngine(_ engine: CustomSearchEngine) {
        var settings = AppSettings.load()
        var updated = settings.customSearchEngines
        if let idx = updated.firstIndex(where: { $0.id == engine.id }) {
            updated[idx] = engine
        } else {
            updated.append(engine)
        }
        settings.customSearchEngines = updated
        settings.save()
        self.customEngines = updated
        onUpdate?()
        feedbackBanner = "Saved '\(engine.name)'"
    }
}

/// Sheet for adding a new custom search engine or modifying an existing one.
public struct AddOrEditSearchEngineSheet: View {
    @Environment(\.presentationMode) private var presentationMode

    public let editingEngine: CustomSearchEngine?
    public let onSave: (CustomSearchEngine) -> Void

    @State private var name: String = ""
    @State private var urlTemplate: String = ""
    @State private var searchDescription: String = ""
    @State private var validationError: String? = nil

    public init(
        editingEngine: CustomSearchEngine? = nil,
        onSave: @escaping (CustomSearchEngine) -> Void
    ) {
        self.editingEngine = editingEngine
        self.onSave = onSave
        _name = State(initialValue: editingEngine?.name ?? "")
        _urlTemplate = State(initialValue: editingEngine?.urlTemplate ?? "")
        _searchDescription = State(initialValue: editingEngine?.searchDescription ?? "")
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        switch SearchURLBuilder.validateTemplate(urlTemplate) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    public var body: some View {
        NavigationView {
            Form {
                if let error = validationError {
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
                    header: Text("Engine Details"),
                    footer: Text("The URL template must begin with 'https://' and contain '%s' where the search terms will be inserted.")
                ) {
                    TextField("Engine Name (e.g. Kagi)", text: $name)
                        .disableAutocorrection(true)

                    TextField("URL Template (https://...%s)", text: $urlTemplate)
                        #if canImport(UIKit)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        #endif
                        .disableAutocorrection(true)

                    TextField("Description (optional)", text: $searchDescription)
                }

                Section(header: Text("Template Examples")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kagi Search:")
                            .font(.caption.bold())
                        Text("https://kagi.com/search?q=%s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if urlTemplate.isEmpty {
                            name = "Kagi"
                            urlTemplate = "https://kagi.com/search?q=%s"
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ecosia:")
                            .font(.caption.bold())
                        Text("https://www.ecosia.org/search?q=%s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if urlTemplate.isEmpty {
                            name = "Ecosia"
                            urlTemplate = "https://www.ecosia.org/search?q=%s"
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub Code / Repositories:")
                            .font(.caption.bold())
                        Text("https://github.com/search?q=%s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if urlTemplate.isEmpty {
                            name = "GitHub"
                            urlTemplate = "https://github.com/search?q=%s"
                        }
                    }
                }
            }
            .navigationTitle(editingEngine == nil ? "Add Search Engine" : "Edit Search Engine")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if canImport(UIKit)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.body.weight(.bold))
                    }
                    .disabled(!isValid)
                }
                #else
                ToolbarItem {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem {
                    Button("Save") {
                        save()
                    }
                    .disabled(!isValid)
                }
                #endif
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTemplate = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = searchDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationError = "Engine name cannot be empty."
            return
        }

        switch SearchURLBuilder.validateTemplate(trimmedTemplate) {
        case .failure(let err):
            validationError = err.localizedDescription
            return
        case .success:
            break
        }

        let id = editingEngine?.id ?? UUID().uuidString
        let engine = CustomSearchEngine(
            id: id,
            name: trimmedName,
            urlTemplate: trimmedTemplate,
            searchDescription: trimmedDesc.isEmpty ? nil : trimmedDesc
        )
        onSave(engine)
        presentationMode.wrappedValue.dismiss()
    }
}
#endif
