import AppKit
import SwiftUI

/// Vertical tabs for a terminal window. Every native tab is its own window, so each
/// window hosts a sidebar that lists the windows in its tab group. The look follows
/// Steel's desktop chat sidebar: flat surface, 30pt rows, 10pt corners, 14pt type.
enum TerminalTabSidebar {
    static let visibleKey = "TerminalTabSidebarVisible"
    static let widthKey = "TerminalTabSidebarWidth"

    /// Posted when the sidebar is shown or hidden so windows can swap the native tab bar.
    static let visibilityDidChange = Notification.Name("TerminalTabSidebarVisibilityDidChange")

    static let defaultWidth: CGFloat = 275
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 520
    static let minTerminalWidth: CGFloat = 320
    static let divider: CGFloat = 0.5

    static var isVisible: Bool {
        get { UserDefaults.ghostty.object(forKey: visibleKey) as? Bool ?? true }
        set {
            UserDefaults.ghostty.set(newValue, forKey: visibleKey)
            NotificationCenter.default.post(name: visibilityDidChange, object: nil)
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

// MARK: - Model

/// Mirrors the tab group of one window. Titles, order and selection come straight from
/// AppKit, so native shortcuts (goto_tab, new_tab, close) keep working unchanged.
final class TerminalTabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    private weak var window: NSWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var windowsObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false

    init(window: NSWindow) {
        self.window = window

        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            TerminalWindow.titleDidChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setNeedsRefresh()
            }
        }

        setNeedsRefresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        windowsObservation?.invalidate()
    }

    func select(_ tab: Tab) {
        window(for: tab)?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        guard let target = window(for: tab) else { return }
        // Select first so a close confirmation appears on the visible tab.
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? TerminalController)?.closeTab(nil)
    }

    func rename(_ tab: Tab) {
        guard let target = window(for: tab) else { return }
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? BaseTerminalController)?.promptTabTitle()
    }

    func newTab() {
        (window?.windowController as? TerminalController)?.newTab(nil)
    }

    private func window(for tab: Tab) -> NSWindow? {
        let windows = observedTabGroup?.windows ?? [window].compactMap { $0 }
        return windows.first { ObjectIdentifier($0) == tab.id }
    }

    private func setNeedsRefresh() {
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

        let tabGroup = window.tabGroup
        if tabGroup !== observedTabGroup {
            observedTabGroup = tabGroup
            windowsObservation?.invalidate()
            windowsObservation = tabGroup?.observe(\.windows, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.setNeedsRefresh() }
            }
        }

        let windows = tabGroup?.windows ?? [window]
        let selected = tabGroup?.selectedWindow ?? window
        let next = windows.map { tabWindow in
            Tab(
                id: ObjectIdentifier(tabWindow),
                title: tabWindow.title.isEmpty ? "Terminal" : tabWindow.title,
                isSelected: tabWindow === selected)
        }
        if next != tabs { tabs = next }

        // AppKit can recreate the tab bar when the group changes.
        (window as? TerminalWindow)?.syncNativeTabBarVisibility()
    }
}

// MARK: - Design

private enum TabSidebarPalette {
    static let surface = adaptive(0xE0E0E0, 0x272727)
    static let selected = adaptive(0xD2D2D2, 0x383838)
    static let hovered = selected
    static let text = adaptive(0x363636, 0xDFDFDF)
    static let textSecondary = adaptive(0x5D5D5D, 0xAFAFAF)
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.1)
    })

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(isDark(appearance) ? dark : light)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

private enum TabSidebarTokens {
    static let row: CGFloat = 30
    static let rowGap: CGFloat = 1
    static let rowRadius: CGFloat = 10
    static let inset: CGFloat = 8
    static let fontSize: CGFloat = 14
}

private enum TabSidebarMotion {
    static let hover = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.15)
    static let selection = Animation.timingCurve(0.19, 1, 0.22, 1, duration: 0.15)
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

                TabSidebarPalette.hairline
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

    var body: some View {
        TabSidebarScrollView(bottomContentInset: 16) {
            TabSidebarAction(title: "New Tab", symbol: "plus", action: model.newTab)
                .padding(.top, 8)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: TabSidebarTokens.rowGap) {
                ForEach(model.tabs) { tab in
                    TabSidebarRow(
                        tab: tab,
                        onSelect: { model.select(tab) },
                        onClose: { model.close(tab) },
                        onRename: { model.rename(tab) })
                }
            }
            .padding(.bottom, 16)
        }
        .background(TabSidebarPalette.surface.ignoresSafeArea(.container, edges: .top))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

private struct TabSidebarAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: TabSidebarTokens.fontSize, weight: .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(TabSidebarPalette.text)
            .padding(.horizontal, 8)
            .frame(height: TabSidebarTokens.row)
            .contentShape(RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous))
        }
        .buttonStyle(TabSidebarPressStyle())
        .background(
            RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous)
                .fill(isHovered ? TabSidebarPalette.hovered : Color.clear))
        .onHover { hovering in
            withAnimation(TabSidebarMotion.hover) { isHovered = hovering }
        }
        .padding(.horizontal, TabSidebarTokens.inset)
    }
}

private struct TabSidebarRow: View {
    let tab: TerminalTabSidebarModel.Tab
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            TabSidebarTitle(text: tab.title, isActive: isHovered, trailingInset: isHovered ? 24 : 0)
                .foregroundColor(TabSidebarPalette.text)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TabSidebarTokens.row)
                .contentShape(RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabSidebarPressStyle())
            .foregroundColor(TabSidebarPalette.textSecondary)
            .help("Close Tab")
            .padding(.trailing, 8)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .background(
            RoundedRectangle(cornerRadius: TabSidebarTokens.rowRadius, style: .continuous)
                .fill(tab.isSelected
                      ? TabSidebarPalette.selected
                      : (isHovered ? TabSidebarPalette.hovered : Color.clear)))
        .onHover { hovering in
            withAnimation(TabSidebarMotion.hover) { isHovered = hovering }
        }
        .contextMenu {
            Button("Rename Tab…", action: onRename)
            Divider()
            Button("Close Tab", action: onClose)
        }
        .animation(TabSidebarMotion.selection, value: tab.isSelected)
        .padding(.horizontal, TabSidebarTokens.inset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TabSidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.68 : 1)
    }
}

// MARK: - Title

/// Long titles glide once to their end on hover after a short dwell, then stop.
private struct TabSidebarTitle: View {
    let text: String
    let isActive: Bool
    var trailingInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var isFinished = false

    private var textWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: TabSidebarTokens.fontSize, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
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
                    .font(.system(size: TabSidebarTokens.fontSize, weight: .regular))
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
        .frame(height: 20)
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

    static func offset(elapsed: TimeInterval, distance: CGFloat, fontSize: CGFloat = TabSidebarTokens.fontSize) -> CGFloat {
        guard distance > 0, elapsed > delay else { return 0 }
        let fraction = min(1, (elapsed - delay) / Double(distance / (fontSize * 2)))
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

// MARK: - Scroll

private struct TabSidebarContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// A scroll view without indicators that fades its edges only when content is hidden there.
private struct TabSidebarScrollView<Content: View>: View {
    var bottomContentInset: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @State private var showsTopEdge = false
    @State private var showsBottomEdge = false
    @State private var viewportHeight: CGFloat = 0

    private static var space: String { "TabSidebarScroll" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0, content: content)
                .background(GeometryReader { geometry in
                    Color.clear.preference(
                        key: TabSidebarContentFrameKey.self,
                        value: geometry.frame(in: .named(Self.space)))
                })
        }
        .coordinateSpace(name: Self.space)
        .scrollIndicators(.hidden)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { viewportHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { viewportHeight = $0 }
        })
        .onPreferenceChange(TabSidebarContentFrameKey.self) { frame in
            let top = frame.minY < -1
            let bottom = frame.maxY - viewportHeight > bottomContentInset + 1
            if showsTopEdge != top { showsTopEdge = top }
            if showsBottomEdge != bottom { showsBottomEdge = bottom }
        }
        .overlay(alignment: .top) {
            TabSidebarScrollEdge(top: true).opacity(showsTopEdge ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            TabSidebarScrollEdge(top: false).opacity(showsBottomEdge ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: showsTopEdge)
        .animation(.easeOut(duration: 0.12), value: showsBottomEdge)
    }
}

private struct TabSidebarScrollEdge: View {
    let top: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var start: UnitPoint { top ? .top : .bottom }
    private var end: UnitPoint { top ? .bottom : .top }

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(stops: [
                    .init(color: TabSidebarPalette.surface, location: 0),
                    .init(color: TabSidebarPalette.surface.opacity(reduceTransparency ? 1 : 0.65), location: 0.4),
                    .init(color: TabSidebarPalette.surface.opacity(reduceTransparency ? 1 : 0), location: 1),
                ], startPoint: start, endPoint: end)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.9), location: 0.25),
                    .init(color: .black.opacity(0.35), location: 0.65),
                    .init(color: .clear, location: 1),
                ], startPoint: start, endPoint: end)
            }
            .frame(height: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Resize

/// A 10pt hit region over the hairline. It must consume drags even though the
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
