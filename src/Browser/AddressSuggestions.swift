import AppKit
import SwiftUI

struct AddressSuggestion: Identifiable {
    var title: String
    var address: String
    var bookmark: Bool
    var id: String { address }
}

struct AddressSuggestionIndex {
    private struct Entry {
        let item: AddressSuggestion
        let title: String
        let host: String
        let haystack: String
    }
    private var bookmarks: [Entry] = []
    private var visits: [Entry] = []

    init(sites: [Site], imported: [String: [BookmarkNode]], history: [Visit]) throws {
        var known = Set<String>()
        func entry(title: String, address: String, bookmark: Bool) throws -> Entry? {
            try Task.checkCancellation()
            guard let url = URLInput.parse(address, search: false),
                  known.insert(url.absoluteString).inserted else { return nil }
            return Entry(item: AddressSuggestion(title: title, address: url.absoluteString, bookmark: bookmark),
                         title: title.lowercased(), host: (url.host ?? "").lowercased(),
                         haystack: (title + " " + address).lowercased())
        }
        for site in sites {
            if let value = try entry(title: site.title, address: site.address, bookmark: true) { bookmarks.append(value) }
        }
        func collect(_ nodes: [BookmarkNode]) throws {
            for node in nodes {
                try Task.checkCancellation()
                if let children = node.children { try collect(children) }
                else if let address = node.address,
                        let value = try entry(title: node.title, address: address, bookmark: true) {
                    bookmarks.append(value)
                }
            }
        }
        for source in imported.keys.sorted() { try collect(imported[source] ?? []) }
        known.removeAll(keepingCapacity: true)
        for visit in history {
            if let value = try entry(title: visit.title, address: visit.address, bookmark: false) { visits.append(value) }
        }
    }

    func suggestions(for query: String) throws -> [AddressSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func best(_ entries: [Entry], limit: Int, excluding: Set<String> = []) throws -> [AddressSuggestion] {
            var result: [(item: AddressSuggestion, score: Int)] = []
            for (offset, entry) in entries.enumerated() {
                if offset % 128 == 0 { try Task.checkCancellation() }
                guard !excluding.contains(entry.item.address),
                      words.allSatisfy({ entry.haystack.contains($0) }) else { continue }
                let score = (entry.title.hasPrefix(text) ? 4 : 0) + (entry.host.hasPrefix(text) ? 4 : 0)
                // Keep only the best eight; equal scores retain source order (recent history first).
                let position = result.firstIndex { $0.score < score } ?? result.count
                if position < limit {
                    result.insert((entry.item, score), at: position)
                    if result.count > limit { result.removeLast() }
                }
            }
            return result.map(\.item)
        }
        let result = try best(bookmarks, limit: 8)
        return result.count == 8 ? result : result + (try best(visits, limit: 8 - result.count, excluding: Set(result.map(\.address))))
    }
}

// Parsing and matching run on the actor's executor, never on the UI thread.
actor AddressSuggestionSearch {
    private var revision: Int?
    private var index: AddressSuggestionIndex?
    func suggestions(for query: String, revision: Int, sites: [Site],
                     imported: [String: [BookmarkNode]], history: [Visit]) throws -> [AddressSuggestion] {
        try Task.checkCancellation()
        if self.revision != revision {
            let updated = try AddressSuggestionIndex(sites: sites, imported: imported, history: history)
            try Task.checkCancellation()
            index = updated
            self.revision = revision
        }
        return try index?.suggestions(for: query) ?? []
    }
}

extension Store {
    func suggestions(for query: String) async throws -> [AddressSuggestion] {
        try await addressSuggestionSearch.suggestions(for: query, revision: suggestionRevision,
            sites: sites, imported: importedBookmarks, history: history)
    }
}

struct AddressTextField: NSViewRepresentable {
    @ObservedObject private var theme = PerchTheme.shared
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    var focusShortcut = true
    var ownerTab: UUID?
    var focusRequest: UUID?
    var canFocus: (UUID) -> Bool = { _ in true }
    var focusedRequest: () -> Void = {}
    let changed: () -> Void
    let command: (String) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Field: NSTextField {
        var ownerTab: UUID?
        var attached: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attached?()
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.window as? Panel else { return }
                panel.restoreCurrentTabFocus()
            }
        }
    }
    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.ownerTab = ownerTab
        field.attached = { [weak coordinator = context.coordinator, weak field] in
            if let field { coordinator?.requestFocus(field) }
        }
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = placeholder
        field.identifier = NSUserInterfaceItemIdentifier(focusShortcut ? "toolbarAddress" : "homeAddress")
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("网址")
        if focusShortcut {
            context.coordinator.observer = NotificationCenter.default.addObserver(forName: .focusAddress, object: nil, queue: .main) {
                [weak field] _ in field?.window?.makeFirstResponder(field); field?.selectText(nil)
            }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        (field as? Field)?.ownerTab = ownerTab
        context.coordinator.requestFocus(field)
        // State redraws must not replace the input method's uncommitted text.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
        (field.window as? Panel)?.restorePendingSelection(for: field)
    }
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressTextField
        var observer: NSObjectProtocol?
        init(_ parent: AddressTextField) { self.parent = parent }
        func requestFocus(_ field: NSTextField) {
            guard let request = parent.focusRequest else { return }
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.parent.focusRequest == request,
                      self.parent.canFocus(request), let window = field.window,
                      window.makeFirstResponder(field) else { return }
                field.selectText(nil)
                self.parent.focusedRequest()
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            (field.window as? Panel)?.cancelPendingFieldSelection()
            parent.text = field.currentEditor()?.string ?? field.stringValue; parent.changed()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), parent.text != textView.string {
                parent.text = textView.string
                parent.changed()
            }
            return parent.command(NSStringFromSelector(commandSelector))
        }
    }
}

struct AddressEntry: View {
    @ObservedObject private var theme = PerchTheme.shared
    let store: Store
    var currentAddress = ""
    var focusShortcut = true
    var homeTab: UUID?
    private let ownerTab: UUID?
    private let focusRequest: UUID?
    private let suggestionRevision: Int
    @State private var text = ""
    @State private var focused = false
    @State private var editing = false
    @State private var selected = -1
    @State private var items: [AddressSuggestion] = []
    private struct Request: Hashable {
        let text: String
        let revision: Int
        let active: Bool
    }
    init(store: Store, currentAddress: String = "", focusShortcut: Bool = true, homeTab: UUID? = nil,
         ownerTab: UUID? = nil) {
        self.store = store; self.currentAddress = currentAddress
        self.focusShortcut = focusShortcut; self.homeTab = homeTab
        self.ownerTab = ownerTab ?? homeTab ?? store.selected
        focusRequest = focusShortcut && self.ownerTab == store.selected ? store.pendingAddressFocus : nil
        suggestionRevision = store.suggestionRevision
    }
    private var request: Request { Request(text: text, revision: suggestionRevision, active: focused && editing) }
    var body: some View {
        AddressTextField(text: $text, focused: $focused, placeholder: "输入网址或搜索", focusShortcut: focusShortcut,
                         ownerTab: ownerTab,
                         focusRequest: focusRequest,
                         canFocus: { id in store.pendingAddressFocus == id && store.selected == id && !store.isChatPage },
                         focusedRequest: { store.pendingAddressFocus = nil },
                         changed: {
                             if let homeTab { store.homeAddressDrafts[homeTab, default: [:]][focusShortcut] = text }
                             editing = true; selected = -1
                             if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items = [] }
                         }, command: handle)
            .frame(height: 22).padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(alignment: .topLeading) {
                if focused && editing && !items.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { navigate(item.address) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.bookmark ? "bookmark.fill" : "clock").frame(width: 16)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title.isEmpty ? item.address : item.title).font(.system(size: 12, weight: .medium))
                                        Text(item.address).font(.system(size: 10)).foregroundStyle(Style.muted)
                                    }.lineLimit(1)
                                    Spacer(minLength: 0)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == selected ? Style.mint : Style.paper)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.background(Style.paper).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Style.line))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 4).offset(y: 30)
                }
            }
            .onAppear { text = homeTab.flatMap { store.homeAddressDrafts[$0]?[focusShortcut] } ?? currentAddress }
            .onChange(of: currentAddress) { value in if !focused { text = value } }
            .onChange(of: focused) { value in if !value { dismissSuggestions() } }
            .task(id: request) {
                let pending = request
                selected = -1
                guard pending.active, !pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    items = []
                    return
                }
                do {
                    let result = try await store.suggestions(for: pending.text)
                    try Task.checkCancellation()
                    guard request == pending else { return }
                    selected = -1; items = result
                } catch { /* A new query or dismissal cancels the previous search. */ }
            }
    }
    private func handle(_ command: String) -> Bool {
        switch command {
        case "moveDown:":
            guard !items.isEmpty else { return false }; selected = min(selected + 1, items.count - 1); return true
        case "moveUp:":
            guard !items.isEmpty else { return false }; selected = max(selected - 1, -1); return true
        case "cancelOperation:": dismissSuggestions(); return true
        case "insertNewline:":
            navigate(items.indices.contains(selected) ? items[selected].address : text); return true
        default: return false
        }
    }
    private func dismissSuggestions() {
        editing = false; selected = -1; items = []
    }
    private func navigate(_ address: String) {
        dismissSuggestions()
        store.navigate(address)
    }
}
