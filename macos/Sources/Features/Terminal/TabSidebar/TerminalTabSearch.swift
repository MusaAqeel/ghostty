import AppKit
import SwiftUI

/// ⌘K search across every tab, open and archived, by title and terminal text.
/// It takes ⌘K from the default `clear_screen` binding.
enum TerminalTabSearch {
    /// Toggles search in the key terminal window. Returns true if the event was used.
    static func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard modifiers == .command,
              event.charactersIgnoringModifiers?.lowercased() == "k",
              let controller = NSApp.keyWindow?.windowController as? TerminalController,
              let model = controller.tabSidebarModel else { return false }
        model.toggleSearch()
        return true
    }
}

// MARK: - Model

/// Collects every tab when search opens, reads terminal text in the background of
/// the main queue one tab at a time, and matches off the main thread.
final class TerminalTabSearchModel: ObservableObject, @unchecked Sendable {
    enum Scope: String, CaseIterable, Identifiable {
        case all
        case open
        case archived

        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .archived: "Archived"
            }
        }

        func includes(isArchived: Bool) -> Bool {
            switch self {
            case .all: true
            case .open: !isArchived
            case .archived: isArchived
            }
        }
    }

    /// Text with the parts that matched the query marked.
    struct Highlighted: Equatable {
        struct Part: Equatable {
            let text: String
            let isMatch: Bool
        }

        let parts: [Part]

        init(_ text: String) {
            parts = [Part(text: text, isMatch: false)]
        }

        init(_ text: String, matching ranges: [Range<String.Index>]) {
            var parts: [Part] = []
            var cursor = text.startIndex
            for range in Self.merged(ranges) where range.lowerBound >= cursor {
                if cursor < range.lowerBound {
                    parts.append(Part(text: String(text[cursor..<range.lowerBound]), isMatch: false))
                }
                parts.append(Part(text: String(text[range]), isMatch: true))
                cursor = range.upperBound
            }
            if cursor < text.endIndex {
                parts.append(Part(text: String(text[cursor...]), isMatch: false))
            }
            self.parts = parts
        }

        private static func merged(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
            var merged: [Range<String.Index>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            return merged
        }
    }

    struct Result: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: Highlighted
        let snippet: Highlighted?
        let date: Date
        let isArchived: Bool
    }

    /// Terminal text, bridged once so every search runs on a native string.
    fileprivate struct SearchText: @unchecked Sendable {
        let string: NSString
    }

    fileprivate struct Document {
        let id: ObjectIdentifier
        let title: String
        let date: Date
        let isArchived: Bool
        var text: SearchText?
    }

    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }

    @Published var scope: Scope = .all {
        didSet { if scope != oldValue { scheduleSearch() } }
    }

    @Published private(set) var results: [Result] = []
    @Published var selection: ObjectIdentifier?

    /// Set when the keyboard moves the selection, so the list scrolls to it.
    @Published private(set) var scrollTarget: ObjectIdentifier?

    private var documents: [Document] = []
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var session = 0
    private var generation = 0
    private let latestGeneration = NSLock()
    private var latestGenerationValue = 0
    private static let queue = DispatchQueue(label: "com.mitchellh.ghostty.tab-search", qos: .userInitiated)

    var selectedResult: Result? {
        results.first { $0.id == selection } ?? results.first
    }

    func window(for id: ObjectIdentifier) -> NSWindow? {
        windows[id]
    }

    func open() {
        session += 1
        collect()
        query = ""
        scope = .all
        scheduleSearch()
        loadText(at: 0, session: session)
    }

    func close() {
        session += 1
        documents = []
        windows = [:]
        query = ""
        results = []
        selection = nil
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : results.count)
        let next = (current + delta + results.count) % results.count
        selection = results[next].id
        scrollTarget = selection
    }

    // MARK: Documents

    private func collect() {
        let activity = TerminalTabActivity.shared
        let archived = TerminalTabArchive.shared.entries
        let archivedIDs = Set(archived.map(\.id))

        var windows: [ObjectIdentifier: NSWindow] = [:]
        var documents: [Document] = []

        for controller in TerminalController.all {
            guard let window = controller.window, !archivedIDs.contains(ObjectIdentifier(window)) else { continue }
            windows[ObjectIdentifier(window)] = window
            documents.append(Document(
                id: ObjectIdentifier(window),
                title: TerminalTabArchive.title(for: window),
                date: activity.date(for: window),
                isArchived: false))
        }

        for entry in archived {
            windows[entry.id] = entry.window
            documents.append(Document(
                id: entry.id,
                title: entry.title,
                date: activity.date(for: entry.window),
                isArchived: true))
        }

        // Read the most recent tabs first.
        self.documents = documents.sorted { $0.date > $1.date }
        self.windows = windows
    }

    /// Reads one tab's text per main-queue turn so opening search never stalls.
    private func loadText(at index: Int, session: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, session == self.session, index < self.documents.count else { return }
            if let window = self.windows[self.documents[index].id] {
                self.documents[index].text = SearchText(string: NSString(string: Self.text(for: window)))
            }
            if !self.trimmedQuery.isEmpty { self.scheduleSearch() }
            self.loadText(at: index + 1, session: session)
        }
    }

    private static func text(for window: NSWindow) -> String {
        guard let controller = window.windowController as? BaseTerminalController else { return "" }
        return controller.surfaceTree
            .map { $0.cachedScreenContents.get() }
            .joined(separator: "\n")
    }

    // MARK: Searching

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch() {
        generation += 1
        let generation = self.generation
        latestGeneration.lock()
        latestGenerationValue = generation
        latestGeneration.unlock()

        let documents = self.documents
        let query = trimmedQuery
        let scope = self.scope

        // Recents need no text, so they show on the first frame.
        guard !query.isEmpty else {
            apply(Self.search(query, scope: scope, in: documents) { false })
            return
        }

        Self.queue.async { [weak self] in
            let isStale = { [weak self] in
                guard let self else { return true }
                self.latestGeneration.lock()
                defer { self.latestGeneration.unlock() }
                return self.latestGenerationValue != generation
            }
            guard !isStale() else { return }
            let results = Self.search(query, scope: scope, in: documents, isStale: isStale)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation else { return }
                self.apply(results)
            }
        }
    }

    private func apply(_ results: [Result]) {
        if results != self.results { self.results = results }
        if !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    /// Title matches rank above text matches; newer tabs break ties.
    private static func search(
        _ query: String,
        scope: Scope,
        in documents: [Document],
        isStale: () -> Bool
    ) -> [Result] {
        let candidates = documents.filter { scope.includes(isArchived: $0.isArchived) }
        guard !query.isEmpty else {
            return candidates
                .sorted { $0.date > $1.date }
                .map { Result(id: $0.id, title: Highlighted($0.title), snippet: nil, date: $0.date, isArchived: $0.isArchived) }
        }

        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(result: Result, score: Int)] = []
        for document in candidates {
            if isStale() { return [] }
            let title = TabSearchMatch.title(document.title, phrase: query, tokens: tokens)
            let content = document.text.flatMap { TabSearchMatch.content($0.string, phrase: query, tokens: tokens) }
            guard title != nil || content != nil else { continue }

            let score = max(title?.score ?? 0, content?.score ?? 0) + (title != nil && content != nil ? 50 : 0)
            scored.append((Result(
                id: document.id,
                title: title?.text ?? Highlighted(document.title),
                snippet: content?.text,
                date: document.date,
                isArchived: document.isArchived), score))
        }

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.result.date > $1.result.date }
            .map(\.result)
    }
}

// MARK: - Matching

private enum TabSearchMatch {
    typealias Highlighted = TerminalTabSearchModel.Highlighted

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The whole query, then every word, then the query's letters in order.
    static func title(_ title: String, phrase: String, tokens: [String]) -> (score: Int, text: Highlighted)? {
        if let range = title.range(of: phrase, options: options) {
            return (range.lowerBound == title.startIndex ? 1200 : 1000, Highlighted(title, matching: [range]))
        }

        if tokens.count > 1 {
            let ranges = tokens.compactMap { title.range(of: $0, options: options) }
            if ranges.count == tokens.count { return (800, Highlighted(title, matching: ranges)) }
        }

        let needle = phrase.lowercased().filter { !$0.isWhitespace }
        var ranges: [Range<String.Index>] = []
        var cursor = title.startIndex
        for character in needle {
            guard let found = title[cursor...].firstIndex(where: { $0.lowercased() == String(character) }) else {
                return nil
            }
            let next = title.index(after: found)
            ranges.append(found..<next)
            cursor = next
        }
        guard let first = ranges.first, let last = ranges.last else { return nil }

        // Letters scattered across a long title are noise, not a match.
        let spread = title.distance(from: first.lowerBound, to: last.upperBound) - needle.count
        guard spread <= needle.count * 2 + 4 else { return nil }
        return (600 - spread * 10, Highlighted(title, matching: ranges))
    }

    /// The most recent line with the whole query, else with every word.
    static func content(_ text: NSString, phrase: String, tokens: [String]) -> (score: Int, text: Highlighted)? {
        let backwards: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .backwards]
        var match = text.range(of: phrase, options: backwards)
        var score = 300

        if match.location == NSNotFound {
            guard tokens.count > 1 else { return nil }
            var first: NSRange?
            for token in tokens {
                let range = text.range(of: token, options: backwards)
                guard range.location != NSNotFound else { return nil }
                if first == nil { first = range }
            }
            guard let first else { return nil }
            match = first
            score = 200
        }

        return (score, snippet(text, around: match, phrase: phrase, tokens: tokens))
    }

    /// The match's line, starting a little before the match like "…eck the Faire emails".
    private static func snippet(_ text: NSString, around match: NSRange, phrase: String, tokens: [String]) -> Highlighted {
        let lead = 40
        let length = 200
        let line = text.lineRange(for: match)
        let start = max(line.location, match.location - lead)
        let end = min(NSMaxRange(line), max(start + length, NSMaxRange(match)))
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))

        var snippet = text.substring(with: range)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if range.location > line.location { snippet = "…" + snippet }

        let terms = snippet.range(of: phrase, options: options) != nil ? [phrase] : tokens
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var from = snippet.startIndex
            while let found = snippet.range(of: term, options: options, range: from..<snippet.endIndex) {
                ranges.append(found)
                from = found.upperBound
            }
        }
        return Highlighted(snippet, matching: ranges)
    }
}

// MARK: - View

/// A centered panel over the window, colored by the terminal theme.
struct TerminalTabSearchView: View {
    @ObservedObject var search: TerminalTabSearchModel
    let theme: TerminalTabSidebarTheme
    let onOpen: (TerminalTabSearchModel.Result) -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var background: Color { Color(nsColor: theme.background.withAlphaComponent(1)) }
    private var border: Color { Color(nsColor: theme.foreground.withAlphaComponent(0.12)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Clicking outside the panel closes it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)

                panel
                    .frame(
                        width: min(720, max(320, geometry.size.width - 48)),
                        height: min(460, max(220, geometry.size.height - 48)))
                    .padding(.top, max(24, geometry.size.height * 0.08))
            }
        }
        .environment(\.colorScheme, theme.background.isLightColor ? .light : .dark)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            scopes
            resultList
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(border))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 14)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                // Arrow keys and Control-N/P move the selection while typing.
                Group {
                    Button { search.moveSelection(by: -1) } label: { Color.clear }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button { search.moveSelection(by: 1) } label: { Color.clear }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    Button { search.moveSelection(by: -1) } label: { Color.clear }
                        .keyboardShortcut(.init("p"), modifiers: [.control])
                    Button { search.moveSelection(by: 1) } label: { Color.clear }
                        .keyboardShortcut(.init("n"), modifiers: [.control])
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

                TextField("Search Tabs", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundColor(theme.text)
                    .focused($isFieldFocused)
                    .onSubmit {
                        if let result = search.selectedResult { onOpen(result) }
                    }
                    .onExitCommand(perform: onClose)
                    .onAppear {
                        // Focus on the next turn, as the command palette does.
                        DispatchQueue.main.async { isFieldFocused = true }
                    }
            }

            if !search.query.isEmpty {
                Button("Clear") { search.query = "" }
                    .buttonStyle(TabSearchTextButtonStyle(theme: theme))
                border.frame(width: 1, height: 20)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabSearchTextButtonStyle(theme: theme))
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .frame(height: 62)
    }

    private var scopes: some View {
        HStack(spacing: 2) {
            ForEach(TerminalTabSearchModel.Scope.allCases) { scope in
                TabSearchScopeButton(
                    title: scope.title,
                    isSelected: search.scope == scope,
                    theme: theme
                ) {
                    search.scope = scope
                }
            }

            Spacer(minLength: 0)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TabSearchTextButtonStyle(theme: theme))
            .help("Sidebar Settings")
            .accessibilityLabel("Sidebar Settings")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var resultList: some View {
        if search.results.isEmpty {
            Text(search.query.isEmpty ? "No Tabs" : "No Results")
                .font(.system(size: 13))
                .foregroundColor(theme.faintText)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 28)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(search.results) { result in
                            TabSearchRow(result: result, isSelected: result.id == search.selection, theme: theme)
                                .id(result.id)
                                .onTapGesture { onOpen(result) }
                                .onHover { hovering in
                                    if hovering { search.selection = result.id }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: search.scrollTarget) { target in
                    guard let target else { return }
                    proxy.scrollTo(target)
                }
            }
        }
    }
}

private struct TabSearchRow: View {
    let result: TerminalTabSearchModel.Result
    let isSelected: Bool
    let theme: TerminalTabSidebarTheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: result.isArchived ? "archivebox" : "bubble.left")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(theme.secondaryText)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(attributed(result.title, size: 14, base: theme.text, match: theme.text))
                    .lineLimit(1)
                if let snippet = result.snippet {
                    Text(attributed(snippet, size: 12.5, base: theme.secondaryText, match: theme.text))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Text(Self.format(result.date))
                .font(.system(size: 12))
                .foregroundColor(theme.faintText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? theme.selected : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func attributed(
        _ text: TerminalTabSearchModel.Highlighted,
        size: CGFloat,
        base: Color,
        match: Color
    ) -> AttributedString {
        var output = AttributedString()
        for part in text.parts {
            var piece = AttributedString(part.text)
            piece.font = .system(size: size, weight: part.isMatch ? .semibold : .regular)
            piece.foregroundColor = part.isMatch ? match : base
            output += piece
        }
        return output
    }

    /// The time today, the day this year, otherwise the full date.
    private static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct TabSearchScopeButton: View {
    let title: String
    let isSelected: Bool
    let theme: TerminalTabSidebarTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? theme.selected : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? theme.text : theme.secondaryText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TabSearchTextButtonStyle: ButtonStyle {
    let theme: TerminalTabSidebarTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundColor(theme.secondaryText)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
