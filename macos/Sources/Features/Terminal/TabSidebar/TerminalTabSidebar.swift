import AppKit
import SwiftUI

/// Vertical tabs for a terminal window. Every native tab is its own window, so each
/// window hosts a sidebar that lists the windows in its tab group. Colors come from
/// the terminal theme so the sidebar reads as part of the terminal.
enum TerminalTabSidebar {
    static let visibleKey = "TerminalTabSidebarVisible"
    static let widthKey = "TerminalTabSidebarWidth"

    /// Posted when the sidebar is shown or hidden so windows can swap the native tab bar.
    static let visibilityDidChange = Notification.Name("TerminalTabSidebarVisibilityDidChange")

    static let defaultWidth: CGFloat = 240
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 480
    static let minTerminalWidth: CGFloat = 320
    static let divider: CGFloat = 1

    static var isVisible: Bool {
        get { UserDefaults.ghostty.object(forKey: visibleKey) as? Bool ?? true }
        set {
            UserDefaults.ghostty.set(newValue, forKey: visibleKey)
            NotificationCenter.default.post(name: visibilityDidChange, object: nil)
        }
    }

    static let sortKey = "TerminalTabSidebarSort"

    /// Posted when the sort order setting changes.
    static let sortDidChange = Notification.Name("TerminalTabSidebarSortDidChange")

    /// How the sidebar orders tabs. Manual follows the native tab order, which
    /// dragging rearranges. Last Messaged lists the most recently messaged tab first.
    enum Sort: String, CaseIterable, Identifiable {
        case manual
        case lastMessaged

        var id: Self { self }

        var title: String {
            switch self {
            case .manual: "Manual"
            case .lastMessaged: "Last Messaged"
            }
        }
    }

    static var sort: Sort {
        get { UserDefaults.ghostty.string(forKey: sortKey).flatMap(Sort.init(rawValue:)) ?? .manual }
        set {
            UserDefaults.ghostty.set(newValue.rawValue, forKey: sortKey)
            NotificationCenter.default.post(name: sortDidChange, object: nil)
        }
    }

    static var currentWidth: CGFloat {
        let stored = UserDefaults.ghostty.object(forKey: widthKey) as? Double
        return clampedWidth(stored.map { CGFloat($0) } ?? defaultWidth, containerWidth: 0)
    }

    /// The terminal always keeps at least `minTerminalWidth` points.
    static func clampedWidth(_ preferred: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let upper = containerWidth > 0
            ? min(maxWidth, max(minWidth, containerWidth - minTerminalWidth - divider))
            : maxWidth
        return min(max(preferred, minWidth), upper)
    }
}

// MARK: - Theme

/// The sidebar's colors and font, derived from the terminal theme.
struct TerminalTabSidebarTheme: Equatable {
    var background: NSColor
    var foreground: NSColor
    var fontFamily: String?

    static let fallback = TerminalTabSidebarTheme(
        background: .windowBackgroundColor,
        foreground: .labelColor,
        fontFamily: nil)

    var backgroundColor: Color { Color(nsColor: background) }
    var text: Color { Color(nsColor: foreground) }
    var secondaryText: Color { Color(nsColor: foreground.withAlphaComponent(0.6)) }
    var faintText: Color { Color(nsColor: foreground.withAlphaComponent(0.4)) }
    var selected: Color { Color(nsColor: foreground.withAlphaComponent(0.1)) }
    var hovered: Color { Color(nsColor: foreground.withAlphaComponent(0.05)) }
    var hairline: Color { Color(nsColor: foreground.withAlphaComponent(0.08)) }

    static let fontSize: CGFloat = 13

    var font: Font {
        if let fontFamily { return .custom(fontFamily, size: Self.fontSize) }
        return .system(size: Self.fontSize)
    }

    var nsFont: NSFont {
        fontFamily.flatMap { NSFont(name: $0, size: Self.fontSize) } ?? .systemFont(ofSize: Self.fontSize)
    }
}

private enum TabSidebarTokens {
    static let row: CGFloat = 28
    static let rowGap: CGFloat = 2
    static var rowPitch: CGFloat { row + rowGap }
    static let rowRadius: CGFloat = 7
    static let inset: CGFloat = 8
}

private enum TabSidebarMotion {
    static let hover = Animation.easeOut(duration: 0.1)
    static let reorder = Animation.easeOut(duration: 0.12)
}

// MARK: - Activity

/// When each tab was last messaged: the last time Return was pressed in its
/// terminal. A tab counts as messaged when it is first seen. Dates last until
/// Ghostty quits.
final class TerminalTabActivity {
    static let shared = TerminalTabActivity()

    /// Posted with the messaged window as the object.
    static let didChange = Notification.Name("TerminalTabActivityDidChange")

    private var dates: [ObjectIdentifier: Date] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.dates[ObjectIdentifier(window)] = nil
        }
    }

    func date(for window: NSWindow) -> Date {
        let id = ObjectIdentifier(window)
        if let date = dates[id] { return date }
        let now = Date()
        dates[id] = now
        return now
    }

    /// Called for every key down in the app. Plain Return in a terminal sends a
    /// message; Shift-Return and other chords only edit it.
    func noteKeyDown(_ event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76,
              !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let window = event.window as? TerminalWindow,
              window.firstResponder is Ghostty.SurfaceView else { return }
        dates[ObjectIdentifier(window)] = Date()
        NotificationCenter.default.post(name: Self.didChange, object: window)
    }
}

// MARK: - Archive

/// Archived tabs keep running in hidden windows until they are restored or closed.
/// Archives last until Ghostty quits.
final class TerminalTabArchive: ObservableObject {
    static let shared = TerminalTabArchive()

    struct Entry: Identifiable {
        let id: ObjectIdentifier
        let window: NSWindow
        var title: String
    }

    @Published private(set) var entries: [Entry] = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            self?.entries.removeAll { $0.window === window }
        })
        observers.append(center.addObserver(
            forName: TerminalWindow.titleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow,
                  let index = self.entries.firstIndex(where: { $0.window === window }) else { return }
            self.entries[index].title = Self.title(for: window)
        })
    }

    static func title(for window: NSWindow) -> String {
        window.title.isEmpty ? "Terminal" : window.title
    }

    /// Archives a tab. The last tab in a window can't be archived.
    func archive(_ window: NSWindow) {
        guard let tabGroup = window.tabGroup, tabGroup.windows.count > 1 else { return }

        // Select a neighbor first so the window doesn't flash empty.
        let windows = tabGroup.windows
        if tabGroup.selectedWindow === window, let index = windows.firstIndex(of: window) {
            let neighbor = index + 1 < windows.count ? windows[index + 1] : windows[index - 1]
            neighbor.makeKeyAndOrderFront(nil)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        tabGroup.removeWindow(window)
        window.orderOut(nil)
        NSAnimationContext.endGrouping()

        window.isExcludedFromWindowsMenu = true
        entries.insert(Entry(id: ObjectIdentifier(window), window: window, title: Self.title(for: window)), at: 0)
    }

    /// Restores an archived tab to the end of `host`'s tab group and selects it.
    func restore(_ entry: Entry, into host: NSWindow) {
        entries.removeAll { $0.id == entry.id }
        entry.window.isExcludedFromWindowsMenu = false

        let anchor = host.tabGroup?.windows.last ?? host
        anchor.addTabbedWindowSafely(entry.window, ordered: .above)
        entry.window.makeKeyAndOrderFront(nil)
    }

    /// Closes an archived tab, confirming first if a process is still running.
    func close(_ entry: Entry) {
        guard let controller = entry.window.windowController as? TerminalController else {
            entries.removeAll { $0.id == entry.id }
            entry.window.close()
            return
        }

        if controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            let alert = NSAlert()
            alert.messageText = "Close Archived Tab?"
            alert.informativeText = "The terminal still has a running process. If you close the tab the process will be killed."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        entries.removeAll { $0.id == entry.id }
        controller.closeWindowImmediately()
    }
}

// MARK: - Model

/// Mirrors the tab group of one window. Titles, order and selection come straight from
/// AppKit, so native shortcuts (goto_tab, new_tab, move_tab, close) keep working unchanged.
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let isSelected: Bool
    }

    /// What the sidebar shows above its footer.
    enum Page {
        case tabs
        case archive
        case settings
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var theme: TerminalTabSidebarTheme = .fallback
    @Published private(set) var sort: TerminalTabSidebar.Sort = TerminalTabSidebar.sort
    @Published var page: Page = .tabs

    /// Tabs can be dragged only in the manual order.
    var canReorder: Bool { sort == .manual }

    /// The tab being dragged, while a reorder is in progress.
    @Published private(set) var draggingID: ObjectIdentifier?

    /// How far the dragged row sits from its slot, so it follows the pointer.
    @Published private(set) var dragOffset: CGFloat = 0
    private var dragStartIndex = 0

    private(set) weak var window: NSWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var windowsObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false

    init(window: NSWindow) {
        self.window = window

        // Selection and titles refresh in the same pass as the change. A new tab is
        // added to its group before it becomes key, so its first frame already shows
        // the full list instead of an empty, unthemed sidebar.
        let immediate: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            TerminalWindow.titleDidChangeNotification,
        ]
        observers = immediate.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }

        // A closing window is still in its group, so wait a turn.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setNeedsRefresh()
        })

        let reorders: [Notification.Name] = [
            TerminalTabSidebar.sortDidChange,
            TerminalTabActivity.didChange,
        ]
        observers += reorders.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }

        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        windowsObservation?.invalidate()
    }

    var canArchive: Bool { tabs.count > 1 }

    func select(_ tab: Tab) {
        window(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        guard let target = window(for: tab) else { return }
        // Select first so a close confirmation appears on the visible tab.
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? TerminalController)?.closeTab(nil)
    }

    func archive(_ tab: Tab) {
        guard let target = window(for: tab) else { return }
        TerminalTabArchive.shared.archive(target)
    }

    func restore(_ entry: TerminalTabArchive.Entry) {
        guard let window else { return }
        TerminalTabArchive.shared.restore(entry, into: window)
    }

    func rename(_ tab: Tab) {
        guard let target = window(for: tab) else { return }
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    func setSort(_ sort: TerminalTabSidebar.Sort) {
        TerminalTabSidebar.sort = sort
    }

    // MARK: Reordering

    /// Moves the dragged row in the sidebar only, by whole rows of `translation`.
    /// AppKit's order changes when the drag ends.
    func drag(_ tab: Tab, translation: CGFloat) {
        guard canReorder else { return }
        if draggingID == nil {
            guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            draggingID = tab.id
            dragStartIndex = index
        }
        guard let from = tabs.firstIndex(where: { $0.id == draggingID }) else { return }

        let pitch = TabSidebarTokens.rowPitch
        let to = min(max(dragStartIndex + Int((translation / pitch).rounded()), 0), tabs.count - 1)
        if from != to {
            var next = tabs
            next.insert(next.remove(at: from), at: to)
            withAnimation(TabSidebarMotion.reorder) { tabs = next }
        }
        dragOffset = translation - CGFloat(to - dragStartIndex) * pitch
    }

    /// Applies the dragged order to the native tab group.
    func endDrag() {
        defer {
            // Settle the row into its slot.
            withAnimation(TabSidebarMotion.reorder) {
                draggingID = nil
                dragOffset = 0
            }
            setNeedsRefresh()
        }

        guard let draggingID,
              let tabGroup = observedTabGroup,
              let destination = tabs.firstIndex(where: { $0.id == draggingID }),
              let moving = tabGroup.windows.first(where: { ObjectIdentifier($0) == draggingID }),
              tabGroup.windows.firstIndex(of: moving) != destination else { return }

        let selected = tabGroup.selectedWindow

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        tabGroup.removeWindow(moving)
        let remaining = tabGroup.windows
        if destination < remaining.count {
            remaining[destination].addTabbedWindowSafely(moving, ordered: .below)
        } else if let last = remaining.last {
            last.addTabbedWindowSafely(moving, ordered: .above)
        }
        (selected ?? moving).makeKeyAndOrderFront(nil)

        NSAnimationContext.endGrouping()

        // Keep the goto_tab shortcut labels in sync with the new order.
        (window?.windowController as? TerminalController)?.relabelTabs()
    }

    // MARK: Refresh

    private func window(for tab: Tab) -> NSWindow? {
        let windows = observedTabGroup?.windows ?? [window].compactMap { $0 }
        return windows.first { ObjectIdentifier($0) == tab.id }
    }

    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let window else {
            tabs = []
            return
        }

        let nextTheme = Self.theme(for: window)
        if nextTheme != theme { theme = nextTheme }

        let tabGroup = window.tabGroup
        if tabGroup !== observedTabGroup {
            observedTabGroup = tabGroup
            windowsObservation?.invalidate()
            windowsObservation = tabGroup?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.setNeedsRefresh() }
            }
        }

        // AppKit can recreate the tab bar when the group changes.
        (window as? TerminalWindow)?.syncNativeTabBarVisibility()

        // Don't fight an in-progress drag preview.
        guard draggingID == nil else { return }

        let nextSort = TerminalTabSidebar.sort
        if nextSort != sort { sort = nextSort }

        var windows = tabGroup?.windows ?? [window]

        // Reading the dates also stamps tabs seen for the first time.
        let dates = windows.map { TerminalTabActivity.shared.date(for: $0) }
        if sort == .lastMessaged {
            // Newest first; ties keep the native order.
            windows = windows.indices
                .sorted { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : $0 < $1 }
                .map { windows[$0] }
        }

        let selected = tabGroup?.selectedWindow ?? window
        let next = windows.map { tabWindow in
            Tab(
                id: ObjectIdentifier(tabWindow),
                title: TerminalTabArchive.title(for: tabWindow),
                isSelected: tabWindow === selected)
        }
        guard next != tabs else { return }

        // Slide rows when only the order changed, such as a tab moving to the top
        // after a message. Anything else, like a new tab, appears in place.
        if !tabs.isEmpty, next.map(\.id).sorted() == tabs.map(\.id).sorted(),
           next.map(\.id) != tabs.map(\.id) {
            withAnimation(TabSidebarMotion.reorder) { tabs = next }
        } else {
            tabs = next
        }
    }

    private static func theme(for window: NSWindow) -> TerminalTabSidebarTheme {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return .fallback }
        let background = (window as? TerminalWindow)?.preferredBackgroundColor
            ?? NSColor(config.backgroundColor).withAlphaComponent(config.backgroundOpacity)
        return TerminalTabSidebarTheme(
            background: background,
            foreground: NSColor(config.foregroundColor),
            fontFamily: config.windowTitleFontFamily)
    }
}

// MARK: - Layout

/// Places the sidebar to the left of the terminal. Showing, hiding and resizing are
/// instant: every width change resizes the terminal, which reflows TUIs like Claude Code.
struct TerminalTabSidebarLayout<Content: View>: View {
    @ObservedObject var model: TerminalTabSidebarModel
    let content: Content

    @AppStorage(TerminalTabSidebar.visibleKey, store: .ghostty)
    private var isVisible = true

    @AppStorage(TerminalTabSidebar.widthKey, store: .ghostty)
    private var preferredWidth: Double = TerminalTabSidebar.defaultWidth

    @State private var dragWidth: CGFloat?
    @State private var dragStartWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    init(model: TerminalTabSidebarModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    private var width: CGFloat {
        TerminalTabSidebar.clampedWidth(dragWidth ?? CGFloat(preferredWidth), containerWidth: containerWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isVisible {
                TerminalTabSidebarView(model: model)
                    .frame(width: width)

                model.theme.hairline
                    .frame(width: TerminalTabSidebar.divider)
                    .ignoresSafeArea(.container, edges: .top)
            }

            content
        }
        .overlay(alignment: .leading) {
            if isVisible {
                TabSidebarResizeHandle(
                    width: width,
                    onDrag: { delta, ended in
                        if dragWidth == nil { dragStartWidth = width }
                        let next = TerminalTabSidebar.clampedWidth(dragStartWidth + delta, containerWidth: containerWidth)
                        if ended {
                            preferredWidth = Double(next)
                            dragWidth = nil
                        } else {
                            dragWidth = next
                        }
                    },
                    onAdjust: { delta in
                        preferredWidth = Double(TerminalTabSidebar.clampedWidth(width + delta, containerWidth: containerWidth))
                    })
                    .frame(width: 10)
                    .offset(x: width + TerminalTabSidebar.divider / 2 - 5)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { containerWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { containerWidth = $0 }
        })
    }
}

// MARK: - Sidebar

struct TerminalTabSidebarView: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @ObservedObject private var archive = TerminalTabArchive.shared

    private var theme: TerminalTabSidebarTheme { model.theme }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.page {
                    case .tabs: tabList
                    case .archive: archiveList
                    case .settings: settings
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)

            footer
                .padding(.vertical, 8)
        }
        .background(theme.backgroundColor.ignoresSafeArea(.container, edges: .top))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    @ViewBuilder
    private var tabList: some View {
        TabSidebarActionRow(title: "New Tab", symbol: "plus", theme: theme, action: model.newTab)
            .padding(.bottom, 6)

        VStack(alignment: .leading, spacing: TabSidebarTokens.rowGap) {
            ForEach(model.tabs) { tab in
                TabSidebarRow(
                    title: tab.title,
                    isSelected: tab.isSelected,
                    theme: theme,
                    actions: [
                        .init(symbol: "archivebox", help: "Archive Tab", enabled: model.canArchive) { model.archive(tab) },
                        .init(symbol: "xmark", help: "Close Tab") { model.close(tab) },
                    ],
                    onSelect: { model.select(tab) }
                )
                .contextMenu {
                    Button("Rename Tab…") { model.rename(tab) }
                    Button("Archive Tab") { model.archive(tab) }
                        .disabled(!model.canArchive)
                    Divider()
                    Button("Close Tab") { model.close(tab) }
                }
                .offset(y: model.draggingID == tab.id ? model.dragOffset : 0)
                .zIndex(model.draggingID == tab.id ? 1 : 0)
                // The dragged row tracks the pointer; only its neighbors animate.
                .transaction { if model.draggingID == tab.id { $0.animation = nil } }
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .onChanged { model.drag(tab, translation: $0.translation.height) }
                        .onEnded { _ in model.endDrag() },
                    including: model.canReorder ? .all : .subviews)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.page == .tabs {
            HStack(spacing: 2) {
                TabSidebarActionRow(
                    title: "Archived",
                    symbol: "archivebox",
                    trailing: archive.entries.isEmpty ? nil : "\(archive.entries.count)",
                    horizontalInset: 0,
                    theme: theme
                ) {
                    model.page = .archive
                }

                TabSidebarIconButton(symbol: "gearshape", help: "Sidebar Settings", theme: theme) {
                    model.page = .settings
                }
            }
            .padding(.horizontal, TabSidebarTokens.inset)
        } else {
            TabSidebarActionRow(title: "Back to Tabs", symbol: "chevron.left", theme: theme) {
                model.page = .tabs
            }
        }
    }

    @ViewBuilder
    private var settings: some View {
        Text("Sort Tabs")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.faintText)
            .padding(.horizontal, TabSidebarTokens.inset + 10)
            .frame(height: 22)

        VStack(alignment: .leading, spacing: TabSidebarTokens.rowGap) {
            ForEach(TerminalTabSidebar.Sort.allCases) { option in
                TabSidebarActionRow(
                    title: option.title,
                    symbol: model.sort == option ? "checkmark" : nil,
                    theme: theme
                ) {
                    model.setSort(option)
                }
                .accessibilityAddTraits(model.sort == option ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var archiveList: some View {
        if archive.entries.isEmpty {
            Text("No archived tabs")
                .font(theme.font)
                .foregroundColor(theme.faintText)
                .padding(.horizontal, TabSidebarTokens.inset + 10)
                .frame(height: TabSidebarTokens.row)
        } else {
            VStack(alignment: .leading, spacing: TabSidebarTokens.rowGap) {
                ForEach(archive.entries) { entry in
                    TabSidebarRow(
                        title: entry.title,
                        isSelected: false,
                        theme: theme,
                        actions: [
                            .init(symbol: "arrow.uturn.left", help: "Restore Tab") { restore(entry) },
                            .init(symbol: "xmark", help: "Close Tab") { archive.close(entry) },
                        ],
                        onSelect: { restore(entry) }
                    )
                    .contextMenu {
                        Button("Restore Tab") { restore(entry) }
                        Divider()
                        Button("Close Tab") { archive.close(entry) }
                    }
                }
            }
        }
    }

    private func restore(_ entry: TerminalTabArchive.Entry) {
        model.page = .tabs
        model.restore(entry)
    }
}

private struct TabSidebarIconButton: View {
    let symbol: String
    let help: String
    let theme: TerminalTabSidebarTheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: TabSidebarTokens.row, height: TabSidebarTokens.row)
                .contentShape(RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous))
        }
        .buttonStyle(TabSidebarPressStyle())
        .foregroundColor(theme.secondaryText)
        .background(
            RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous)
                .fill(isHovered ? theme.hovered : Color.clear))
        .onHover { hovering in
            withAnimation(TabSidebarMotion.hover) { isHovered = hovering }
        }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TabSidebarActionRow: View {
    let title: String
    /// Without a symbol the title keeps its indent, like an unchecked menu item.
    let symbol: String?
    var trailing: String?
    var horizontalInset = TabSidebarTokens.inset
    let theme: TerminalTabSidebarTheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .regular))
                    }
                }
                .frame(width: 16, height: 16)
                Text(title)
                    .font(theme.font)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(theme.font)
                        .foregroundColor(theme.faintText)
                }
            }
            .foregroundColor(theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: TabSidebarTokens.row)
            .contentShape(RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous))
        }
        .buttonStyle(TabSidebarPressStyle())
        .background(
            RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous)
                .fill(isHovered ? theme.hovered : Color.clear))
        .onHover { hovering in
            withAnimation(TabSidebarMotion.hover) { isHovered = hovering }
        }
        .padding(.horizontal, horizontalInset)
    }
}

private struct TabSidebarRowAction {
    let symbol: String
    let help: String
    var enabled = true
    let perform: () -> Void
}

private struct TabSidebarRow: View {
    let title: String
    let isSelected: Bool
    let theme: TerminalTabSidebarTheme
    let actions: [TabSidebarRowAction]
    let onSelect: () -> Void

    @State private var isHovered = false

    private var actionsWidth: CGFloat { CGFloat(actions.count) * 22 + 4 }

    var body: some View {
        // A tap rather than a Button, so a drag on the row can reorder it.
        TabSidebarTitle(
            text: title,
            font: theme.font,
            nsFont: theme.nsFont,
            isActive: isHovered,
            trailingInset: isHovered ? actionsWidth : 0)
            .foregroundColor(isSelected ? theme.text : theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: TabSidebarTokens.row)
            .contentShape(RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous))
            .onTapGesture(perform: onSelect)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    ForEach(actions, id: \.symbol) { action in
                        Button(action: action.perform) {
                            Image(systemName: action.symbol)
                                .font(.system(size: 11, weight: .regular))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TabSidebarPressStyle())
                        .foregroundColor(theme.secondaryText)
                        .disabled(!action.enabled)
                        .opacity(action.enabled ? 1 : 0.4)
                        .help(action.help)
                    }
                }
                .padding(.trailing, 6)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .background(
                RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous)
                    .fill(isSelected ? theme.selected : (isHovered ? theme.hovered : Color.clear)))
            .onHover { hovering in
                withAnimation(TabSidebarMotion.hover) { isHovered = hovering }
            }
            .padding(.horizontal, TabSidebarTokens.inset)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, onSelect)
    }
}

private struct TabSidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Title

/// Long titles glide once to their end on hover after a short dwell, then stop.
private struct TabSidebarTitle: View {
    let text: String
    let font: Font
    let nsFont: NSFont
    let isActive: Bool
    var trailingInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var isFinished = false

    private var textWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nsFont]).width)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - trailingInset)
            let distance = max(0, textWidth - width)
            let paused = !isActive || reduceMotion || distance == 0 || isFinished
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: paused)) { context in
                let offset = isActive && !reduceMotion
                    ? TabSidebarTitleMotion.offset(elapsed: context.date.timeIntervalSince(startedAt), distance: distance)
                    : 0
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -offset)
                    .frame(width: width, height: geometry.size.height, alignment: .leading)
                    .mask {
                        HStack(spacing: 0) {
                            if offset > 0 {
                                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 8)
                            }
                            Rectangle().fill(.black)
                            if distance > offset + 0.5 {
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 16)
                            }
                        }
                    }
                    .clipped()
                    .onChange(of: offset) { value in
                        if distance > 0 && value >= distance { isFinished = true }
                    }
            }
        }
        .frame(height: 18)
        .onChange(of: isActive) { _ in restart() }
        .onChange(of: text) { _ in restart() }
        .onChange(of: trailingInset) { _ in restart() }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
    }

    private func restart() {
        startedAt = .now
        isFinished = false
    }
}

private enum TabSidebarTitleMotion {
    static let delay: TimeInterval = 0.35

    static func offset(elapsed: TimeInterval, distance: CGFloat) -> CGFloat {
        guard distance > 0, elapsed > delay else { return 0 }
        let fraction = min(1, (elapsed - delay) / Double(distance / (TerminalTabSidebarTheme.fontSize * 2)))
        // Invert cubic-bezier(.49, .6, .7, 1) to evaluate progress by time.
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lower = 0.0, upper = 1.0
        for _ in 0..<16 {
            let midpoint = (lower + upper) / 2
            if cubic(midpoint, 0.49, 0.7) < fraction { lower = midpoint } else { upper = midpoint }
        }
        return fraction >= 1 ? distance : distance * cubic((lower + upper) / 2, 0.6, 1)
    }
}

// MARK: - Resize

/// A 10pt hit region over the divider. It must consume drags even though the
/// window background is movable.
private struct TabSidebarResizeHandle: NSViewRepresentable {
    let width: CGFloat
    let onDrag: (CGFloat, Bool) -> Void
    let onAdjust: (CGFloat) -> Void

    func makeNSView(context: Context) -> TabSidebarDividerView { TabSidebarDividerView() }

    func updateNSView(_ view: TabSidebarDividerView, context: Context) {
        view.onDrag = onDrag
        view.onAdjust = onAdjust
        view.setAccessibilityValue(Int(width))
    }
}

private final class TabSidebarDividerView: NSView {
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onAdjust: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize tab sidebar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        onDrag?(0, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDrag?(event.locationInWindow.x - dragStartX, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStartX else { return }
        self.dragStartX = nil
        onDrag?(event.locationInWindow.x - dragStartX, true)
    }

    override func accessibilityPerformIncrement() -> Bool { onAdjust?(24); return onAdjust != nil }
    override func accessibilityPerformDecrement() -> Bool { onAdjust?(-24); return onAdjust != nil }
}
