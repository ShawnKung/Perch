import AppKit
import SwiftUI

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

    override func loadView() {
        super.loadView()
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
    }

    func update(store: Store, controlsInset: CGFloat) {
        _ = view
        let ids = store.tabs.map(\.id) + (store.selected == nil ? [AIController.homeID] : [])
        for id in Array(pages.keys) where !ids.contains(id) {
            if let item = pages.removeValue(forKey: id) { removeTabViewItem(item) }
        }
        for id in ids {
            let content = TabContentView(store: store, tabID: id, controlsInset: controlsInset)
            if let host = pages[id]?.viewController as? NSHostingController<TabContentView> {
                host.rootView = content
            } else {
                let host = NSHostingController(rootView: content)
                host.sizingOptions = []
                let item = NSTabViewItem(viewController: host)
                item.identifier = id
                pages[id] = item
                addTabViewItem(item)
            }
        }
        if let item = pages[store.selected ?? AIController.homeID],
           let index = tabViewItems.firstIndex(of: item), selectedTabViewItemIndex != index {
            selectedTabViewItemIndex = index
        }
    }
}

struct TabContentView: View {
    @ObservedObject var store: Store
    let tabID: UUID
    let controlsInset: CGFloat
    private var tab: Tab? { store.tabs.first { $0.id == tabID } }

    var body: some View {
        Group {
            if let owner = tab?.chatOwner {
                AIChatSidebar(store: store, ai: store.ai, fullPage: true,
                              owner: owner, windowControlsInset: controlsInset) { store.close(tabID) }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if let browser = store.cachedBrowser(for: tabID) {
                            BrowserAddressBar(browser: browser, store: store).id(ObjectIdentifier(browser))
                        } else { HomeAddressBar(store: store) }
                        WindowTools(store: store)
                    }
                    .frame(height: 28).padding(.horizontal, 8).padding(.leading, controlsInset)
                    .padding(.vertical, 8).background(Style.paper).background(WindowDragArea()).zIndex(10)
                    ZStack {
                        if let browser = store.cachedBrowser(for: tabID) {
                            WebContent(browser: browser)
                            BrowserScreen(browser: browser)
                        } else { HomeScreen(store: store) }
                    }.modifier(ContentTopChrome(enabled: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultAppStorage(store.defaults)
        .foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light)
        .ignoresSafeArea(.container, edges: .top)
    }
}
