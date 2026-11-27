#if canImport(SwiftUI)
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


// MARK: - Home / New Tab View

public struct BrowserHomeView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @State private var isShowingAddSheet: Bool = false
    @State private var editingShortcut: QuickAccessShortcut? = nil
    @State private var shortcutToDelete: QuickAccessShortcut? = nil
    @State private var isShowingDeleteConfirm: Bool = false

    let columns = [
        GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 14)
    ]

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Hero Branding Card
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.22), Color.indigo.opacity(0.14)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 78, height: 78)
                            .overlay(
                                Circle()
                                    .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                            )
                            .shadow(color: .blue.opacity(0.15), radius: 10, x: 0, y: 4)
                        Image(systemName: "globe")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .padding(.top, 18)

                    Text("LID In-App Browser")
                        .font(.title2.weight(.bold))

                    Text("Browse privately, auto-detect media streams, and route transfers directly to the multi-threaded engine.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Quick Access Section (Speed Dial)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Quick Access")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.quickAccessShortcuts) { shortcut in
                            QuickAccessItemView(
                                shortcut: shortcut,
                                onTap: {
                                    viewModel.load(url: shortcut.url)
                                },
                                onOpenInNewTab: {
                                    viewModel.createNewTab(with: shortcut.url)
                                },
                                onEdit: {
                                    editingShortcut = shortcut
                                },
                                onDelete: {
                                    shortcutToDelete = shortcut
                                    isShowingDeleteConfirm = true
                                },
                                onMoveLeft: {
                                    viewModel.moveQuickAccessShortcut(id: shortcut.id, direction: .left)
                                },
                                onMoveRight: {
                                    viewModel.moveQuickAccessShortcut(id: shortcut.id, direction: .right)
                                }
                            )
                        }

                        QuickAccessAddButtonCell {
                            isShowingAddSheet = true
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Integrated Engine & Privacy Shield Card
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(viewModel.isAdBlockerEnabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                            .frame(width: 38, height: 38)
                        Image(systemName: viewModel.isAdBlockerEnabled ? "bolt.shield.fill" : "shield.slash")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(viewModel.isAdBlockerEnabled ? .green : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Integrated Transfer Engine")
                                .font(.subheadline.weight(.bold))
                            if viewModel.isAdBlockerEnabled {
                                Text("Shields On")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.16))
                                    .foregroundColor(.green)
                                    .clipShape(Capsule())
                            }
                        }
                        Text("Downloads initiated from this browser automatically inherit cookies, referer headers, segmented range writing, and background recovery.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 5, x: 0, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            QuickAccessEditSheet { name, url in
                viewModel.addQuickAccessShortcut(name: name, url: url)
            }
        }
        .sheet(item: $editingShortcut) { shortcut in
            QuickAccessEditSheet(editingShortcut: shortcut) { name, url in
                var updated = shortcut
                updated.name = name
                updated.url = url
                viewModel.updateQuickAccessShortcut(updated)
            }
        }
        .confirmationDialog(
            "Delete '\(shortcutToDelete?.name ?? "Shortcut")'?",
            isPresented: $isShowingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let shortcut = shortcutToDelete {
                    viewModel.deleteQuickAccessShortcut(id: shortcut.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This shortcut will be removed from your Quick Access page. Your bookmarks and browsing history will not be affected.")
        }
    }
}

// MARK: - Browser Tab Switcher (Visual 2-Column Grid with Tab Groups & Renaming)

extension BrowserTabGroup {
    public var swiftUIColor: Color {
        switch colorName.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        default: return .blue
        }
    }
}

public struct BrowserTabSwitcherView: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tabToRename: BrowserTabState? = nil
    @State private var renameText: String = ""
    @State private var isShowingRenameAlert: Bool = false

    @State private var groupToRename: BrowserTabGroup? = nil
    @State private var renameGroupText: String = ""
    @State private var isShowingRenameGroupAlert: Bool = false

    @State private var tabForNewGroup: BrowserTabState? = nil
    @State private var newGroupName: String = ""
    @State private var isShowingNewGroupAlert: Bool = false

    @State private var dropTargetGroupID: UUID? = nil

    let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if viewModel.tabs.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 40)
                            Image(systemName: "square.on.square.dashed")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("No Open Tabs")
                                .font(.headline)
                            Text("Open a new tab to begin browsing.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer(minLength: 40)
                        }
                    } else {
                        // Render Groups (if any)
                        ForEach(viewModel.groups) { group in
                            groupSection(group)
                        }

                        // Render Ungrouped Tabs
                        let ungrouped = viewModel.ungroupedTabs()
                        if !ungrouped.isEmpty {
                            if !viewModel.groups.isEmpty {
                                HStack {
                                    Text("Tabs (\(ungrouped.count))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                            }

                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(ungrouped) { tab in
                                    tabCard(for: tab)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    actionButtons
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Tabs (\(viewModel.tabs.count))")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.isShowingTabSwitcher = false
                        dismiss()
                    }
                }
            }
            .alert("Rename Tab", isPresented: $isShowingRenameAlert) {
                TextField("Tab Title", text: $renameText)
                Button("Save") {
                    if let tab = tabToRename {
                        viewModel.renameTab(tab.id, newTitle: renameText)
                    }
                    tabToRename = nil
                }
                Button("Reset to Default") {
                    if let tab = tabToRename {
                        viewModel.renameTab(tab.id, newTitle: nil)
                    }
                    tabToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    tabToRename = nil
                }
            }
            .alert("Rename Group", isPresented: $isShowingRenameGroupAlert) {
                TextField("Group Name", text: $renameGroupText)
                Button("Save") {
                    if let group = groupToRename {
                        viewModel.renameGroup(group.id, newTitle: renameGroupText)
                    }
                    groupToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    groupToRename = nil
                }
            }
            .alert("New Tab Group", isPresented: $isShowingNewGroupAlert) {
                TextField("Group Name", text: $newGroupName)
                Button("Create") {
                    let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = trimmed.isEmpty ? "New Group" : trimmed
                    if let tab = tabForNewGroup {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            _ = viewModel.createGroup(title: title, tabIDs: [tab.id])
                        }
                    }
                    tabForNewGroup = nil
                    newGroupName = ""
                }
                Button("Cancel", role: .cancel) {
                    tabForNewGroup = nil
                    newGroupName = ""
                }
            }
        }
        .modernStackNavigation()
    }

    func groupSection(_ group: BrowserTabGroup) -> some View {
        let groupTabs = viewModel.tabsInGroup(group.id)
        let isDropTarget = dropTargetGroupID == group.id

        return VStack(alignment: .leading, spacing: 10) {
            // Group Header (Drop Target for adding tabs to group)
            HStack(spacing: 8) {
                Circle()
                    .fill(group.swiftUIColor)
                    .frame(width: 12, height: 12)

                Text(group.title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("(\(groupTabs.count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                // Collapse/Expand Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.toggleGroupCollapse(group.id)
                    }
                } label: {
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)

                // Group Menu
                Menu {
                    Button {
                        let newTabID = viewModel.createNewTab(isIncognito: false)
                        _ = viewModel.addTabToGroup(tabID: newTabID, groupID: group.id)
                        dismiss()
                    } label: {
                        Label("New Tab in Group", systemImage: "plus.square.on.square")
                    }

                    Button {
                        groupToRename = group
                        renameGroupText = group.title
                        isShowingRenameGroupAlert = true
                    } label: {
                        Label("Rename Group", systemImage: "pencil")
                    }

                    Button {
                        withAnimation {
                            viewModel.deleteGroup(group.id, closeContainedTabs: false)
                        }
                    } label: {
                        Label("Ungroup Tabs", systemImage: "folder.badge.minus")
                    }

                    Divider()

                    Button(role: .destructive) {
                        withAnimation {
                            viewModel.deleteGroup(group.id, closeContainedTabs: true)
                        }
                    } label: {
                        Label("Close Group", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTarget ? group.swiftUIColor.opacity(0.2) : Color.clear)
            )
            .onDrop(of: ["public.plain-text", "public.text"], isTargeted: Binding(
                get: { dropTargetGroupID == group.id },
                set: { targeted in dropTargetGroupID = targeted ? group.id : nil }
            )) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    if let str = string as? String, let sourceUUID = UUID(uuidString: str) {
                        DispatchQueue.main.async {
                            viewModel.addTabToGroup(tabID: sourceUUID, groupID: group.id)
                        }
                    }
                }
                return true
            }

            // Group Contained Tabs
            if !group.isCollapsed {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(groupTabs) { tab in
                        tabCard(for: tab)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    func tabCard(for tab: BrowserTabState) -> some View {
        BrowserTabCardView(
            tab: tab,
            isActive: tab.id == viewModel.activeTabID,
            previewData: viewModel.tabPreviewCache.preview(for: tab.id),
            availableGroups: viewModel.groups,
            onSelect: {
                _ = viewModel.selectTab(tab.id)
                dismiss()
            },
            onClose: {
                close(tab.id)
            },
            onRename: {
                tabToRename = tab
                renameText = tab.customTitle ?? tab.title
                isShowingRenameAlert = true
            },
            onResetName: {
                viewModel.renameTab(tab.id, newTitle: nil)
            },
            onRemoveFromGroup: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    _ = viewModel.removeTabFromGroup(tabID: tab.id)
                }
            },
            onMoveToGroup: { targetGroupID in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    _ = viewModel.addTabToGroup(tabID: tab.id, groupID: targetGroupID)
                }
            },
            onMoveToNewGroup: {
                tabForNewGroup = tab
                newGroupName = ""
                isShowingNewGroupAlert = true
            },
            onGroup: { sourceTabID in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    _ = viewModel.groupTabs(sourceTabID: sourceTabID, targetTabID: tab.id)
                }
            }
        )
    }

    var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    viewModel.createNewTab(isIncognito: false)
                    dismiss()
                } label: {
                    Label("New Tab", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.createNewTab(isIncognito: true)
                    dismiss()
                } label: {
                    Label("Private Tab", systemImage: "eyeglasses")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }

            if viewModel.tabs.contains(where: \.isIncognito) {
                Button {
                    viewModel.closeAllIncognitoTabs()
                } label: {
                    Label("Close All Private Tabs", systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.purple)
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
    }

    func close(_ tabID: UUID) {
        withAnimation(.easeInOut(duration: 0.25)) {
            _ = viewModel.closeTab(tabID)
        }
    }
}

// MARK: - Browser Tab Card View with Drag & Drop Grouping, Renaming & Left/Right Swipe-to-Close

public struct BrowserTabCardView: View {
    public let tab: BrowserTabState
    public let isActive: Bool
    public let previewData: Data?
    public let availableGroups: [BrowserTabGroup]
    public let onSelect: () -> Void
    public let onClose: () -> Void
    public let onRename: (() -> Void)?
    public let onResetName: (() -> Void)?
    public let onRemoveFromGroup: (() -> Void)?
    public let onMoveToGroup: ((UUID) -> Void)?
    public let onMoveToNewGroup: (() -> Void)?
    public let onGroup: ((UUID) -> Void)?

    @State private var dragOffset: CGSize = .zero
    @State private var isDismissing: Bool = false
    @State private var isDropTarget: Bool = false

    public init(
        tab: BrowserTabState,
        isActive: Bool,
        previewData: Data?,
        availableGroups: [BrowserTabGroup] = [],
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onRename: (() -> Void)? = nil,
        onResetName: (() -> Void)? = nil,
        onRemoveFromGroup: (() -> Void)? = nil,
        onMoveToGroup: ((UUID) -> Void)? = nil,
        onMoveToNewGroup: (() -> Void)? = nil,
        onGroup: ((UUID) -> Void)? = nil
    ) {
        self.tab = tab
        self.isActive = isActive
        self.previewData = previewData
        self.availableGroups = availableGroups
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRename = onRename
        self.onResetName = onResetName
        self.onRemoveFromGroup = onRemoveFromGroup
        self.onMoveToGroup = onMoveToGroup
        self.onMoveToNewGroup = onMoveToNewGroup
        self.onGroup = onGroup
    }

    public var body: some View {
        ZStack {
            // Swipe action background indicator (Left or Right)
            if dragOffset.width != 0 {
                swipeActionBackground
            }

            cardContent
                .offset(dragOffset)
                .rotationEffect(.degrees(max(-7, min(7, Double(dragOffset.width) / 26.0))))
                .opacity(isDismissing ? 0 : max(0.25, 1.0 - Double(abs(dragOffset.width) / 200.0)))
                .scaleEffect(isDismissing ? 0.85 : max(0.94, 1.0 - (abs(dragOffset.width) / 900.0)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: ["public.plain-text", "public.text"], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let str = string as? String, let sourceUUID = UUID(uuidString: str), sourceUUID != tab.id {
                    DispatchQueue.main.async {
                        onGroup?(sourceUUID)
                    }
                }
            }
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(-2)
        )
        .overlay(
            Group {
                if isDropTarget {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                            Text("Group Tabs")
                                .font(.caption.weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .foregroundColor(.primary)
                        .padding(.bottom, 8)
                    }
                }
            }
        )
        .contextMenu {
            if let onRename = onRename {
                Button(action: onRename) {
                    Label("Rename Tab", systemImage: "pencil")
                }
            }
            if tab.customTitle != nil, let onResetName = onResetName {
                Button(action: onResetName) {
                    Label("Reset Tab Name", systemImage: "arrow.counterclockwise")
                }
            }
            let otherGroups = availableGroups.filter { $0.id != tab.groupID }
            if !otherGroups.isEmpty || onMoveToNewGroup != nil {
                Menu {
                    ForEach(otherGroups) { group in
                        Button {
                            onMoveToGroup?(group.id)
                        } label: {
                            Label(group.title, systemImage: "folder.fill")
                        }
                    }
                    if let onMoveToNewGroup = onMoveToNewGroup {
                        if !otherGroups.isEmpty {
                            Divider()
                        }
                        Button(action: onMoveToNewGroup) {
                            Label("New Group...", systemImage: "folder.badge.plus")
                        }
                    }
                } label: {
                    Label("Move to Group", systemImage: "folder")
                }
            }
            if tab.groupID != nil, let onRemoveFromGroup = onRemoveFromGroup {
                Button(action: onRemoveFromGroup) {
                    Label("Remove from Group", systemImage: "folder.badge.minus")
                }
            }
            Divider()
            Button(role: .destructive, action: onClose) {
                Label("Close Tab", systemImage: "trash")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onChanged { value in
                    guard !isDismissing else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    if abs(dx) >= abs(dy) {
                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
                            dragOffset = CGSize(width: dx, height: 0)
                        }
                    } else if dy < -20 && abs(dx) < 20 {
                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.9)) {
                            dragOffset = CGSize(width: 0, height: dy)
                        }
                    }
                }
                .onEnded { value in
                    guard !isDismissing else { return }
                    let dx = Double(value.translation.width)
                    let dy = Double(value.translation.height)
                    let predictedDX = Double(value.predictedEndTranslation.width)
                    let predictedDY = Double(value.predictedEndTranslation.height)
                    let shouldClose = BrowserTabSwipePolicy.shouldClose(translationX: dx, translationY: dy) ||
                        (abs(dx) > 28 && BrowserTabSwipePolicy.shouldClose(translationX: predictedDX, translationY: predictedDY))
                    if shouldClose {
                        #if canImport(UIKit)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                        let horizontal = abs(dx) >= abs(dy)
                        withAnimation(.easeOut(duration: 0.18)) {
                            if horizontal {
                                dragOffset = CGSize(width: dx >= 0 ? 280 : -280, height: 0)
                            } else {
                                dragOffset = CGSize(width: 0, height: -280)
                            }
                            isDismissing = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                onClose()
                            }
                        }
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            dragOffset = .zero
                        }
                    }
                }
        )
    }

    var swipeActionBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.red)
            .overlay(
                HStack {
                    if dragOffset.width > 0 {
                        // Swiping right: show close indicator on the left
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                            Text("Close")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.leading, 16)
                        Spacer()
                    } else {
                        // Swiping left: show close indicator on the right
                        Spacer()
                        HStack(spacing: 6) {
                            Text("Close")
                                .font(.system(size: 14, weight: .bold))
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.trailing, 16)
                    }
                }
            )
            .opacity(min(1.0, Double(abs(dragOffset.width) / 60.0)))
    }

    var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Title & Dedicated Rename & Close Buttons
            HStack(spacing: 6) {
                if tab.isIncognito {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.purple)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                }

                Text(tab.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if tab.customTitle != nil {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 4)

                // Dedicated Rename Button
                if let onRename = onRename {
                    Button(action: onRename) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Rename \(tab.displayName)")
                }

                // Dedicated Close Button with explicit hit target
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        onClose()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Close \(tab.displayName)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            #if canImport(UIKit)
            .background(Color(UIColor.secondarySystemBackground))
            #else
            .background(Color.secondary.opacity(0.12))
            #endif

            Divider()

            // Thumbnail / Preview Body
            Button(action: onSelect) {
                ZStack {
                    #if canImport(UIKit)
                    if let previewData, let uiImage = UIImage(data: previewData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: 115)
                            .clipped()
                    } else {
                        placeholderPreview
                    }
                    #else
                    placeholderPreview
                    #endif
                }
                .frame(maxWidth: .infinity, minHeight: 115, maxHeight: 115)
                .background(tab.isIncognito ? Color.purple.opacity(0.06) : Color.secondary.opacity(0.04))
            }
            .buttonStyle(.plain)

            Divider()

            // Footer
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text(displayURL)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if tab.isDesktopMode {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                    }

                    if tab.isIncognito {
                        Text("Private")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                #if canImport(UIKit)
                .background(Color(UIColor.secondarySystemBackground))
                #else
                .background(Color.secondary.opacity(0.12))
                #endif
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isActive
                        ? (tab.isIncognito ? Color.purple : Color.blue)
                        : (tab.isIncognito ? Color.purple.opacity(0.3) : Color.secondary.opacity(0.2)),
                    lineWidth: isActive ? 2.5 : 1
                )
        )
        .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    var placeholderPreview: some View {
        VStack(spacing: 6) {
            Image(systemName: tab.isIncognito ? "eyeglasses" : "globe")
                .font(.system(size: 26))
                .foregroundColor(tab.isIncognito ? .purple.opacity(0.7) : .blue.opacity(0.7))

            Text(tab.url?.host ?? (tab.isIncognito ? "Private Tab" : "New Tab"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var displayURL: String {
        guard let url = tab.url else { return "New tab" }
        return BrowserURLResolver.sanitizeURLForLogging(url)
    }
}

// MARK: - Browser Error View

public struct BrowserErrorView: View {
    public let error: String
    public let onRetry: () -> Void
    public let onHome: () -> Void

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Unable to Load Page")
                .font(.headline)

            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 16) {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)

                Button("Return to Home", action: onHome)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding()
    }
}

// MARK: - Browser Download Modal Sheet

public struct BrowserMagnetConfirmationSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isSubmitting = false

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                if let magnet = viewModel.magnetCandidate {
                    Section(header: Text("Resource")) {
                        magnetDetailRow(label: "Resource type", value: "BitTorrent magnet link")
                        magnetDetailRow(label: "Name", value: magnet.presentationName)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Identifier")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(magnet.identifier)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(4)
                        }
                        magnetDetailRow(
                            label: "Source",
                            value: viewModel.magnetSourcePageURL.map(BrowserURLResolver.sanitizeURLForDisplay) ?? "Current webpage"
                        )
                        if let length = magnet.contentLength {
                            magnetDetailRow(label: "Declared size", value: "\(length) bytes")
                        }
                    }

                    if viewModel.isTorrentEngineAvailable {
                        Section {
                            Button {
                                submitMagnet()
                            } label: {
                                HStack {
                                    Spacer()
                                    if isSubmitting {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                    }
                                    Text("Add to Torrent Queue")
                                        .bold()
                                    Spacer()
                                }
                            }
                            .disabled(isSubmitting)
                        }
                    } else {
                        Section {
                            Text("Built-in torrent downloading is unavailable. You can hand this magnet link to an installed torrent application instead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Open in External Torrent App") {
                                openExternally()
                            }
                        }
                    }
                } else {
                    Text("No magnet link is awaiting confirmation.")
                        .foregroundColor(.secondary)
                }

                if let error = viewModel.magnetErrorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Torrent Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .modernStackNavigation()
        .modernSheetDetents()
    }

    func submitMagnet() {
        viewModel.magnetErrorMessage = nil
        isSubmitting = true
        Task { @MainActor in
            do {
                try await viewModel.confirmMagnetLink()
                isSubmitting = false
                presentationMode.wrappedValue.dismiss()
            } catch {
                isSubmitting = false
                viewModel.magnetErrorMessage = error.localizedDescription
            }
        }
    }

    func openExternally() {
        guard viewModel.openMagnetExternally() else {
            viewModel.magnetErrorMessage = "No external torrent application could be opened."
            return
        }
        presentationMode.wrappedValue.dismiss()
    }

    func magnetDetailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Confirms a prepared, finite streaming proposal before its resources are
/// submitted through the existing download coordinator.
public struct BrowserStreamingConfirmationSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode

    public init(viewModel: BrowserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationView {
            Form {
                if let proposal = viewModel.streamingProposal {
                    Section(header: Text("Stream")) {
                        detailRow(label: "Type", value: proposal.manifest.kind.rawValue.uppercased())
                        detailRow(label: "Resources", value: "\(proposal.resources.count) ordered segments")
                        if let bytes = proposal.estimatedTransferBytes {
                            detailRow(label: "Estimated size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Manifest")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(BrowserURLResolver.sanitizeURLForDisplay(proposal.manifest.manifestURL))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }
                    }

                    if let progress = viewModel.streamingProgress {
                        Section(header: Text("Progress")) {
                            ProgressView(value: progress.currentFraction)
                            Text("Segment \(progress.currentOrder) of \(progress.totalSegments)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = viewModel.streamingErrorMessage {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }

                    Section {
                        Button {
                            viewModel.executeStreamingProposal()
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isExecutingStreaming {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                }
                                Text(viewModel.isExecutingStreaming ? "Downloading Stream" : "Start Stream")
                                    .bold()
                                Spacer()
                            }
                        }
                        .disabled(viewModel.isExecutingStreaming)
                    }
                } else if viewModel.isPreparingStreaming {
                    ProgressView("Preparing manifest")
                } else {
                    Text("No streaming proposal is awaiting confirmation.")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Streaming Download")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelStreamingDownload()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }

    func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}

public struct BrowserDownloadSheet: View {
    @ObservedObject public var viewModel: BrowserViewModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var isSubmitting = false
    @State private var submitErrorMessage: String? = nil
    @State private var baseFilename: String = ""
    @State private var fileExtension: String = ""
    @State private var estimatedStreamBytes: Int64? = nil
    @State private var isEstimatingSize: Bool = false

    var isPreSelectedVariant: Bool {
        viewModel.activeDownloadResource?.hlsVariantPreferences != nil ||
        viewModel.activeDownloadResource?.dashVideoRepresentationID != nil
    }

    var preSelectedVariantQualityInfo: (badge: String, resolution: String?, details: String?, isAudio: Bool, buttonTitle: String) {
        guard let res = viewModel.activeDownloadResource else {
            return ("Video", nil, nil, false, "Download Video")
        }

        let isAudio = res.resourceType == .audio

        // 1. Try matching HLSVariantStreamItem from viewModel.variantStreamItems
        if let item = viewModel.variantStreamItems[res.id] {
            let isLive = res.isLive || item.isLive
            let badge = item.qualityLabel
            let resText = item.resolutionText ?? item.resolution.map { "\($0.width) × \($0.height)" }
            var detailsParts: [String] = []
            if isLive {
                detailsParts.append("Live Broadcast")
            } else if let size = item.estimatedSizeText, !size.isEmpty && size != "Size unavailable" {
                detailsParts.append(size)
            }
            if !item.bitrateText.isEmpty {
                detailsParts.append(item.bitrateText)
            }
            let details = detailsParts.isEmpty ? nil : detailsParts.joined(separator: " • ")
            let title = isLive ? "Record Live Stream" : (isAudio ? "Download Audio" : "Download \(badge)")
            return (badge, resText, details, isAudio, title)
        }

        // 2. Derive from HLSVariantSelectionPreferences & resource metadata
        let badge: String = {
            if isAudio { return "Audio" }
            if let h = res.hlsVariantPreferences?.maximumHeight { return "\(h)p" }
            let stem = (res.suggestedFilename as NSString).deletingPathExtension
            if let match = stem.range(of: #"(?:^|[-_])(\d{3,4}p)(?:$|[-_])"#, options: .regularExpression) {
                return String(stem[match]).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            }
            return "Video"
        }()

        let resText: String? = {
            if let w = res.hlsVariantPreferences?.maximumWidth, let h = res.hlsVariantPreferences?.maximumHeight {
                return "\(w) × \(h)"
            }
            return nil
        }()

        let details: String? = {
            if let size = res.estimatedSize, size > 0 {
                return StreamQualityOption.formatByteSize(size)
            }
            return nil
        }()

        let title = isAudio ? "Download Audio" : "Download \(badge)"
        return (badge, resText, details, isAudio, title)
    }

    var downloadFileInfo: (badge: String, badgeColor: Color, resolution: String?, details: String?, isAudio: Bool, buttonTitle: String) {
        if isPreSelectedVariant {
            let info = preSelectedVariantQualityInfo
            let isLive = viewModel.activeDownloadResource?.isLive == true || (viewModel.activeDownloadResource != nil && viewModel.variantStreamItems[viewModel.activeDownloadResource!.id]?.isLive == true)
            let badgeColor: Color = isLive ? .red : (info.isAudio ? .orange : .blue)
            return (info.badge, badgeColor, info.resolution, info.details, info.isAudio, info.buttonTitle)
        }

        let res = viewModel.activeDownloadResource
        let cand = viewModel.activeDownloadCandidate
        let url = viewModel.downloadCandidateURL

        let ext = fileExtension.lowercased()
        let isAudio = res?.resourceType == .audio || (cand?.kind == .completeBlob && cand?.mimeType?.contains("audio") == true) || ["mp3", "m4a", "aac", "flac", "wav", "ogg"].contains(ext)
        let isVideo = res?.resourceType == .video || cand?.kind == .directMedia || ["mp4", "mkv", "webm", "mov", "avi", "flv", "m4v"].contains(ext)

        let badge: String = {
            if !ext.isEmpty {
                return ext.uppercased()
            }
            if isAudio { return "Audio" }
            if isVideo { return "Video" }
            return "File"
        }()

        let badgeColor: Color = isAudio ? .orange : (isVideo ? .blue : .purple)

        var detailsParts: [String] = []
        if let size = res?.estimatedSize ?? cand?.estimatedSize, size > 0 {
            detailsParts.append(StreamQualityOption.formatByteSize(size))
        }
        if let host = url?.host {
            detailsParts.append(host)
        }
        let details = detailsParts.isEmpty ? nil : detailsParts.joined(separator: " • ")

        let buttonTitle = isAudio ? "Download Audio" : (isVideo ? "Download \(badge)" : "Start Download")
        return (badge, badgeColor, nil, details, isAudio, buttonTitle)
    }

    public var body: some View {
        NavigationView {
            Form {
                if let warning = viewModel.existingTransferWarning {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: warning.statusDot == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(warning.statusDot == .completed ? .blue : .orange)
                                .font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(warning.statusDot == .completed ? "Already Downloaded" : (warning.statusDot == .paused ? "Paused in Downloads" : "Already Downloading"))
                                    .font(.subheadline.bold())
                                Text(warning.statusDot == .completed
                                     ? "You already downloaded '\(warning.transferName)'. You can still download it again."
                                     : "'\(warning.transferName)' is already in your Downloads list.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - FILE NAME
                Section(header: Text("FILE NAME")) {
                    HStack(alignment: .center, spacing: 6) {
                        TextField("Filename", text: $baseFilename)
                            #if canImport(UIKit)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .font(.system(size: 15, weight: .medium))
                            .onChange(of: baseFilename) { newBase in
                                let cleanBase = FilenameExtensionHelper.sanitizeFilename(newBase)
                                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: cleanBase, ext: fileExtension)
                            }

                        Text(".")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)

                        TextField("ext", text: $fileExtension)
                            #if canImport(UIKit)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 55)
                            .onChange(of: fileExtension) { newExt in
                                let cleanExt = FilenameExtensionHelper.sanitizeFilename(newExt)
                                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: cleanExt)
                            }
                    }
                }

                // MARK: - DOWNLOAD DETAILS
                let info = downloadFileInfo
                let detailRows = technicalDetailRows
                Section(header: Text(info.isAudio ? "AUDIO DETAILS" : (info.badge == "Video" || ["MKV", "MP4", "WEBM", "MOV"].contains(info.badge) || isPreSelectedVariant ? "MEDIA DETAILS" : "DETAILS"))) {
                    HStack(spacing: 12) {
                        Text(info.badge)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(info.badgeColor)
                            .cornerRadius(6)

                        if let res = info.resolution {
                            Text(res)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        Spacer()

                        if let details = info.details, !details.isEmpty {
                            Text(details)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    ForEach(detailRows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(row.value)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                // If unexpanded HLS or DASH manifest, provide the quality picker button
                if !isPreSelectedVariant,
                   let cand = viewModel.activeDownloadCandidate,
                   (cand.kind == .hlsManifest || cand.kind == .dashManifest || cand.url?.pathExtension.lowercased() == "m3u8" || cand.url?.pathExtension.lowercased() == "mpd") {
                    Section(header: Text("Stream Resolution"), footer: Text("Choose from available multi-variant resolutions or download audio only.")) {
                        Button {
                            viewModel.isShowingDownloadSheet = false
                            if let res = viewModel.activeDownloadResource {
                                viewModel.presentQualityPicker(for: res)
                            } else {
                                viewModel.presentQualityPicker(for: cand)
                            }
                        } label: {
                            HStack {
                                Label("Select Stream Quality...", systemImage: "slider.horizontal.3")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let selected = viewModel.selectedQualityOption {
                                    Text(selected.qualityBadge)
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(selected.badgeColor)
                                        .cornerRadius(5)
                                } else {
                                    Text("Choose")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: - Advanced Options (Collapsed by default so it stays clean)
                Section {
                    DisclosureGroup("Advanced Settings") {
                        VStack(spacing: 12) {
                            Stepper("Worker Threads: \(viewModel.downloadCandidateThreads)", value: $viewModel.downloadCandidateThreads, in: 1...32)

                            HStack {
                                Text("Speed Limit (KB/s)")
                                Spacer()
                                TextField("Unlimited", text: $viewModel.downloadCandidateSpeedLimitKBps)
                                    #if canImport(UIKit)
                                    .keyboardType(.numberPad)
                                    #endif
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 120)
                            }

                            if viewModel.downloadCandidateRequestContext != nil {
                                Toggle("Use browser credentials", isOn: $viewModel.useBrowserCredentials)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                if let err = submitErrorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                // MARK: - Action Button
                Section {
                    Button {
                        submitDownload()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isResumeMode ? "Resume" : (viewModel.existingTransferWarning?.statusDot == .completed ? "Download Again" : info.buttonTitle))
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(isSubmitting || viewModel.downloadCandidateURL == nil)
                    .listRowBackground(isResumeMode ? Color.green : info.badgeColor)
                }
            }
            .navigationTitle(isResumeMode ? "Resume Download" : "Download File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.resumeTargetTransferID = nil
                        viewModel.resumeTargetTransferName = nil
                        viewModel.existingTransferWarning = nil
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .task {
                await estimateStreamingSizeIfNeeded()
            }
            .onAppear {
                let (base, ext) = FilenameExtensionHelper.split(filename: viewModel.downloadCandidateFilename)
                baseFilename = base
                let defaultExt: String = {
                    if let resExt = viewModel.activeDownloadResource?.suggestedExtension, !resExt.isEmpty {
                        return resExt
                    }
                    if let candExt = viewModel.activeDownloadCandidate?.suggestedFilename {
                        let e = FilenameExtensionHelper.split(filename: candExt).ext
                        if !e.isEmpty { return e }
                    }
                    let detected = FilenameExtensionHelper.detectExtension(
                        from: viewModel.downloadCandidateURL,
                        mimeType: viewModel.activeDownloadCandidate?.mimeType ?? viewModel.activeDownloadResource?.mimeType
                    )
                    return detected.isEmpty ? "mp4" : detected
                }()
                fileExtension = ext.isEmpty ? defaultExt : ext
                viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)
            }
        }
    }

    var isResumeMode: Bool {
        viewModel.resumeTargetTransferID != nil
    }

    struct TechnicalDetailRow {
        let label: String
        let value: String
    }

    var technicalDetailRows: [TechnicalDetailRow] {
        let res = viewModel.activeDownloadResource
        let cand = viewModel.activeDownloadCandidate
        let variant = res.flatMap { viewModel.variantStreamItems[$0.id] }
        let selected = viewModel.selectedQualityOption
        var rows: [TechnicalDetailRow] = []

        // Size / Predicted Size
        if res?.isLive == true || variant?.isLive == true {
            rows.append(TechnicalDetailRow(label: "Size", value: "Live Broadcast"))
        } else if let bytes = selected?.estimatedSizeBytes ?? variant?.estimatedSizeBytes ?? estimatedStreamBytes {
            rows.append(TechnicalDetailRow(label: "Predicted Size", value: "~\(StreamQualityOption.formatByteSize(bytes))"))
        } else if let sizeText = selected?.estimatedSizeText ?? variant?.estimatedSizeText,
                  !sizeText.isEmpty && sizeText != "Size unavailable" {
            rows.append(TechnicalDetailRow(label: "Predicted Size", value: sizeText))
        } else if let size = res?.estimatedSize ?? cand?.estimatedSize, size > 0 {
            rows.append(TechnicalDetailRow(label: "Size", value: StreamQualityOption.formatByteSize(size)))
        } else if isEstimatingSize {
            rows.append(TechnicalDetailRow(label: "Predicted Size", value: "Estimating..."))
        } else {
            rows.append(TechnicalDetailRow(label: "Size", value: "Unknown"))
        }

        // Resolution
        let variantResText: String? = variant?.resolutionText ?? variant?.resolution.map { "\($0.width) × \($0.height)" }
        let resolvedResText: String? = selected?.resolutionText ?? variantResText ?? res?.resolutionText
        if let resText = resolvedResText, !resText.isEmpty {
            rows.append(TechnicalDetailRow(label: "Resolution", value: resText))
        } else if let w = res?.hlsVariantPreferences?.maximumWidth, let h = res?.hlsVariantPreferences?.maximumHeight {
            rows.append(TechnicalDetailRow(label: "Resolution", value: "\(w) × \(h)"))
        }

        // Audio
        if let res {
            switch res.trackType {
            case .muxed:
                rows.append(TechnicalDetailRow(label: "Audio", value: res.audioLanguage.map { "Yes (\($0.uppercased()))" } ?? "Yes"))
            case .audioOnly:
                rows.append(TechnicalDetailRow(label: "Audio", value: res.audioLanguage.map { "Audio Only (\($0.uppercased()))" } ?? "Audio Only"))
            case .videoOnly:
                rows.append(TechnicalDetailRow(label: "Audio", value: "No (Video Only)"))
            case .subtitles:
                rows.append(TechnicalDetailRow(label: "Audio", value: "No (Subtitles)"))
            default:
                if res.resourceType == .audio {
                    rows.append(TechnicalDetailRow(label: "Audio", value: "Audio Only"))
                } else if res.resourceType == .video {
                    rows.append(TechnicalDetailRow(label: "Audio", value: "Unknown"))
                }
            }
        }

        // Subtitles
        if let res, res.resourceType == .video || res.isStreamingManifest || variant != nil || selected != nil {
            let hasSubs = (selected?.hasSubtitles == true) || (variant?.hasSubtitles == true) || res.trackType == .subtitles
            rows.append(TechnicalDetailRow(label: "Subtitles", value: hasSubs ? "Yes" : "No"))
        }

        // Bitrate
        if let bitrate = selected?.bitrateText ?? variant?.bitrateText, !bitrate.isEmpty {
            rows.append(TechnicalDetailRow(label: "Bitrate", value: bitrate))
        }

        // Codec
        if let codecs = selected?.codecs ?? variant?.codecs ?? res?.codecs ?? cand?.codecs, !codecs.isEmpty {
            rows.append(TechnicalDetailRow(label: "Codec", value: codecs))
        }

        // Duration
        if let duration = res?.formattedDuration, !duration.isEmpty {
            rows.append(TechnicalDetailRow(label: "Duration", value: duration))
        }

        // Format / Container
        let ext = fileExtension.uppercased()
        if res?.isStreamingManifest == true || cand?.kind == .hlsManifest || cand?.kind == .dashManifest {
            let streamKind = (viewModel.downloadCandidateURL?.pathExtension.lowercased() == "mpd" || cand?.kind == .dashManifest) ? "DASH (.mpd)" : "HLS (.m3u8)"
            rows.append(TechnicalDetailRow(label: "Format", value: ext.isEmpty ? streamKind : "\(streamKind) → \(ext)"))
        } else if let container = res?.container, !container.isEmpty {
            rows.append(TechnicalDetailRow(label: "Format", value: container))
        } else if !ext.isEmpty {
            rows.append(TechnicalDetailRow(label: "Format", value: ext))
        }

        if let host = viewModel.downloadCandidateURL?.host, !host.isEmpty {
            rows.append(TechnicalDetailRow(label: "Host", value: host))
        }

        return rows
    }

    func submitDownload() {
        submitErrorMessage = nil
        isSubmitting = true
        viewModel.downloadCandidateFilename = FilenameExtensionHelper.combine(base: baseFilename, ext: fileExtension)

        let resumeID = viewModel.resumeTargetTransferID
        let resource = viewModel.activeDownloadResource
        let url = viewModel.downloadCandidateURL

        Task { @MainActor in
            do {
                if let targetID = resumeID, let rm = viewModel.recoveryManager {
                    if let res = resource {
                        _ = try await rm.reconnectBrowserResource(transferID: targetID, resource: res)
                    } else if let url {
                        try await rm.updateDownloadLink(transferID: targetID, newURLText: url.absoluteString)
                    }
                    viewModel.resumeTargetTransferID = nil
                    viewModel.resumeTargetTransferName = nil
                    viewModel.existingTransferWarning = nil
                    isSubmitting = false
                    presentationMode.wrappedValue.dismiss()
                    viewModel.onOpenDownloads?()
                } else {
                    try await viewModel.executeDownload()
                    viewModel.existingTransferWarning = nil
                    isSubmitting = false
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                submitErrorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    @MainActor
    func estimateStreamingSizeIfNeeded() async {
        let res = viewModel.activeDownloadResource
        let cand = viewModel.activeDownloadCandidate
        let variant = res.flatMap { viewModel.variantStreamItems[$0.id] }
        let selected = viewModel.selectedQualityOption

        if res?.isLive == true || variant?.isLive == true { return }
        if selected?.estimatedSizeBytes != nil || variant?.estimatedSizeBytes != nil || estimatedStreamBytes != nil { return }
        if let size = res?.estimatedSize ?? cand?.estimatedSize, size > 0 { return }

        let isStreaming = res?.isStreamingManifest == true ||
            cand?.kind == .hlsManifest ||
            cand?.kind == .dashManifest ||
            viewModel.downloadCandidateURL?.pathExtension.lowercased() == "m3u8" ||
            viewModel.downloadCandidateURL?.pathExtension.lowercased() == "mpd"
        guard isStreaming, let targetURL = res?.url ?? viewModel.downloadCandidateURL else { return }

        isEstimatingSize = true
        defer { isEstimatingSize = false }

        do {
            let options = try await StreamQualityInspector.inspect(
                manifestText: res?.manifestText ?? cand?.cachedManifestText ?? "",
                url: targetURL,
                mimeType: res?.mimeType ?? cand?.mimeType,
                requestContext: res?.requestContext ?? cand?.requestContext
            )
            let matched: StreamQualityOption? = {
                if let exactURI = res?.hlsVariantPreferences?.exactURI {
                    return options.first(where: { $0.uri == exactURI })
                }
                if let maxH = res?.hlsVariantPreferences?.maximumHeight {
                    return options.first(where: { $0.resolution?.height == maxH })
                }
                if let repID = res?.dashVideoRepresentationID {
                    return options.first(where: { $0.dashVideoRepresentationID == repID })
                }
                return options.first
            }()
            if let bytes = matched?.estimatedSizeBytes ?? options.compactMap({ $0.estimatedSizeBytes }).first, bytes > 0 {
                estimatedStreamBytes = bytes
            }
        } catch {
            // Keep Size: Unknown when manifest inspection fails
        }
    }
}
#endif
