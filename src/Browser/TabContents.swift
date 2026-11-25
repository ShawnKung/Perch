import AppKit
import SwiftUI
import Combine

@MainActor
final class TabContentState: ObservableObject {
    let store: Store
    let tabID: UUID
    lazy var homeController = HomePageController(store: store, tabID: tabID)
    private var changes: AnyCancellable?
    private var selection: AnyCancellable?
    init(store: Store, tabID: UUID) {
        self.store = store; self.tabID = tabID
        changes = store.objectWillChange.sink { [weak self] in
            guard let self, (self.store.selected ?? AIController.homeID) == self.tabID else { return }
            self.objectWillChange.send()
        }
        // Published delivers the incoming selection before Store changes, so the returning page refreshes with it.
        selection = store.$selected.removeDuplicates().sink { [weak self] selected in
            guard let self, (selected ?? AIController.homeID) == self.tabID, selected != self.store.selected else { return }
            self.objectWillChange.send()
        }
    }
}

// AppKit selects one child content controller; inactive children retain state off-window.
struct TabContents: NSViewControllerRepresentable {
    @ObservedObject var store: Store
    let controlsInset: CGFloat

    func makeNSViewController(context: Context) -> TabContentsController {
        TabContentsController()
    }

    func updateNSViewController(_ controller: TabContentsController, context: Context) {
        controller.update(store: store, controlsInset: controlsInset)
    }
}

final class TabContentsController: NSTabViewController {
    private var pages: [UUID: NSTabViewItem] = [:]
    private var controlsInset: CGFloat?

    override func loadView() {
        super.loadView()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        if let host = tabViewItem?.viewController as? NSHostingController<TabContentView> {
            let page = host.rootView.page
            let tab = page.store.tabs.first { $0.id == page.tabID }
            // AppKit otherwise chooses the first text field and selects its entire address.
            tabViewItem?.initialFirstResponder = tab?.address.isEmpty == false ? host.view : nil
        }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    func update(store: Store, controlsInset: CGFloat) {
        _ = view
        let ids = Set(store.tabs.map(\.id) + (store.selected == nil ? [AIController.homeID] : []))
        for id in Array(pages.keys) where !ids.contains(id) {
            if let item = pages.removeValue(forKey: id) { removeTabViewItem(item) }
        }
        // Only the selected root follows Store changes; retained roots refresh when selected again.
        if self.controlsInset != controlsInset {
            self.controlsInset = controlsInset
            for item in pages.values {
                if let host = item.viewController as? NSHostingController<TabContentView> {
                    host.rootView = TabContentView(page: host.rootView.page, controlsInset: controlsInset)
                }
            }
        }
        let selected = store.selected ?? AIController.homeID
        if ids.contains(selected), pages[selected] == nil {
            let content = TabContentView(page: TabContentState(store: store, tabID: selected), controlsInset: controlsInset)
            if isEmptyHome(selected, store: store),
               let item = tabView.selectedTabViewItem, let previous = item.identifier as? UUID,
               isEmptyHome(previous, store: store),
               let host = item.viewController as? NSHostingController<TabContentView>,
               host.view.window?.attachedSheet == nil, hasNoRetainedInputOrScroll(host.view) {
                // Empty, unscrolled homes have no local state to retain; reuse their expensive hosting tree.
                pages[previous] = nil
                item.identifier = selected
                pages[selected] = item
                content.page.homeController = host.rootView.page.homeController
                content.page.homeController.tabID = selected
                host.rootView = content
            } else {
                let host = NSHostingController(rootView: content)
                host.sizingOptions = []
                let item = NSTabViewItem(viewController: host)
                item.identifier = selected
                pages[selected] = item
                addTabViewItem(item)
            }
        }
        if let item = pages[selected],
           let index = tabViewItems.firstIndex(of: item), selectedTabViewItemIndex != index {
            selectedTabViewItemIndex = index
        }
    }

    private func isEmptyHome(_ id: UUID, store: Store) -> Bool {
        guard let tab = store.tabs.first(where: { $0.id == id }),
              tab.address.isEmpty, tab.chatOwner == nil, store.cachedBrowser(for: id) == nil else { return false }
        return store.homeAddressDrafts[id]?.values.allSatisfy(\.isEmpty) ?? true
    }

    private func hasNoRetainedInputOrScroll(_ view: NSView) -> Bool {
        if let home = view as? HomePageWebView {
            // DOM updates are asynchronous; the native responder protects pending input too.
            if home.controller?.pristine != true ||
                (home.window?.firstResponder as? NSView)?.isDescendant(of: home) == true { return false }
        }
        if let field = view as? AddressTextField.Field {
            let editor = field.currentEditor() as? NSTextView
            if !field.stringValue.isEmpty || editor?.string.isEmpty == false || editor?.hasMarkedText() == true {
                return false
            }
        }
        if let scroll = view as? NSScrollView, scroll.contentView.bounds.origin != .zero { return false }
        return view.subviews.allSatisfy(hasNoRetainedInputOrScroll)
    }
}

struct TabContentView: View {
    @ObservedObject var page: TabContentState
    private var store: Store { page.store }
    private var tabID: UUID { page.tabID }
    let controlsInset: CGFloat
    private var tab: Tab? { store.tabs.first { $0.id == tabID } }
    private var browser: Browser? { tab?.address.isEmpty == false ? store.cachedBrowser(for: tabID) : nil }

    var body: some View {
        Group {
            if let owner = tab?.chatOwner {
                AIChatSidebar(store: store, ai: store.ai, fullPage: true,
                              owner: owner, windowControlsInset: controlsInset) { store.close(tabID) }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if let browser {
                            BrowserAddressBar(browser: browser, store: store, tabID: tabID).id(ObjectIdentifier(browser))
                        } else if let cached = store.cachedBrowser(for: tabID) {
                            HomeHistoryAddressBar(browser: cached, store: store, tabID: tabID)
                        } else { HomeAddressBar(store: store, tabID: tabID) }
                        WindowTools(store: store)
                    }
                    .frame(height: 28).padding(.horizontal, 8).padding(.leading, controlsInset)
                    .padding(.vertical, 8).background(Style.paper).background(WindowDragArea()).zIndex(10)
                    ZStack {
                        if let browser {
                            BrowserTabContent(browser: browser)
                        } else { HomeScreen(page: page) }
                    }.modifier(ContentTopChrome(enabled: true))
                }
                .overlayPreferenceValue(BookmarkButtonAnchor.self) { anchor in
                    GeometryReader { geometry in
                        if let anchor, let browser {
                            BrowserZoomOverlay(browser: browser, bookmark: geometry[anchor])
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultAppStorage(store.defaults)
        .foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light)
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct BrowserTabContent: View {
    @ObservedObject var browser: Browser
    var body: some View {
        WebContent(browser: browser)
        BrowserScreen(browser: browser)
    }
}
