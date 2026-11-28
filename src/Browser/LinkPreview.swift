import AppKit
import WebKit

@MainActor
final class HoverLinkTracker: NSObject, WKScriptMessageHandler {
    private(set) var site: Site?
    private(set) var editing = false
    var changed: (() -> Void)?
    func clear() {
        site = nil; editing = false; changed?()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let address = body["address"] as? String, address.utf8.count <= 16384 else { return }
        let wasEditing = editing
        editing = body["editing"] as? Bool ?? false
        let next = URLInput.parse(address, search: false).map {
            Site(title: String((body["title"] as? String ?? "").prefix(512)), address: $0.absoluteString)
        }
        if next?.address != site?.address || editing != wasEditing {
            site = next
            changed?()
        }
    }
    static let script = """
    (() => {
      let last = '', point = null, hovered = null;
      function report(node) {
        hovered = node;
        const link = node?.closest?.('a[href],area[href]');
        const active = document.activeElement;
        const editing = !!active && (active.matches('input,textarea,select') || active.isContentEditable);
        const address = link?.href || '';
        const title = (link?.textContent || link?.getAttribute('aria-label') || '').trim().slice(0,512);
        const signature = address + '\\n' + editing;
        if (signature === last) return;
        last = signature;
        window.webkit.messageHandlers.perchHoverLink.postMessage({address, title, editing});
      }
      document.addEventListener('pointermove', e => {
        point = {x:e.clientX, y:e.clientY};
        report(e.composedPath()[0]);
      }, true);
      document.addEventListener('pointerover', e => report(e.composedPath()[0]), true);
      document.addEventListener('pointerout', e => {
        report(e.relatedTarget);
        if (!e.relatedTarget) point = null;
      }, true);
      document.addEventListener('focusin', () => report(hovered), true);
      document.addEventListener('focusout', () => setTimeout(() => report(hovered), 0), true);
      document.addEventListener('scroll', () => {
        if (point) report(document.elementFromPoint(point.x,point.y));
      }, true);
      window.addEventListener('blur', () => { point = null; report(null); });
      window.addEventListener('pagehide', () => report(null));
    })();
    """
}

@MainActor
final class LinkPreviewController {
    private weak var store: Store?
    private var monitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var held = false
    private var fired = false
    private var waitingAddress: String?
    private var waitingBrowser: ObjectIdentifier?
    private var pointer = NSPoint.zero
    private(set) var preview: BookmarkPreviewController?
    init(store: Store) { self.store = store }
    deinit {
        pending?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .mouseMoved,
            .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event, pointer: NSEvent.mouseLocation)
            return event
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }
    static func modifier(_ code: UInt32) -> NSEvent.ModifierFlags? {
        switch code {
        case 58, 61: return .option
        case 56, 60: return .shift
        case 59, 62: return .control
        case 55, 54: return .command
        default: return nil
        }
    }
    func handle(_ event: NSEvent, pointer: NSPoint) {
        self.pointer = pointer
        guard let store else { return }
        let key = store.settings.linkPreviewKey
        if let modifier = Self.modifier(key.code) {
            if event.type == .flagsChanged {
                let down = event.modifierFlags.intersection([.option, .control, .shift, .command]) == modifier
                if !down { reset(); return }
                if !held { held = true; fired = false }
            } else if event.type == .keyDown || event.type == .leftMouseDown || event.type == .rightMouseDown {
                cancelWaiting(); fired = true; return
            }
        } else {
            if event.type == .keyUp && UInt32(event.keyCode) == key.code { reset(); return }
            if event.type == .keyDown {
                guard UInt32(event.keyCode) == key.code,
                      event.modifierFlags.intersection([.option, .control, .shift, .command]).isEmpty else {
                    cancelWaiting(); fired = true; return
                }
                if !event.isARepeat && !held { held = true; fired = false }
            } else if event.type == .flagsChanged || event.type == .leftMouseDown || event.type == .rightMouseDown {
                reset(); return
            }
        }
        schedule()
    }
    func hoverChanged() { schedule() }
    func settingsChanged() {
        reset()
        if store?.settings.linkPreviewEnabled == false { preview?.close() }
    }
    private func eligibleBrowser() -> Browser? {
        guard let store, store.settings.linkPreviewEnabled, !store.adding,
              store.pendingPassword == nil, let browser = store.browser,
              let window = browser.webView.window, window.isKeyWindow, window.isVisible,
              window.attachedSheet == nil, NSApp.isActive,
              Self.modifier(store.settings.linkPreviewKey.code) != nil ||
                (browser.hoverLinks?.editing == false && !(window.firstResponder is NSTextView)) else { return nil }
        let point = browser.webView.convert(window.convertPoint(fromScreen: pointer), from: nil)
        return browser.webView.visibleRect.contains(point) ? browser : nil
    }
    private func schedule() {
        guard held, !fired, preview == nil, let browser = eligibleBrowser(),
              let site = browser.hoverLinks?.site else { cancelWaiting(); return }
        let identity = ObjectIdentifier(browser)
        guard waitingAddress != site.address || waitingBrowser != identity else { return }
        cancelWaiting()
        waitingAddress = site.address; waitingBrowser = identity
        let delay = store?.settings.linkPreviewDelay ?? 1
        if delay == 0 {
            present(site, browser: browser)
            return
        }
        pending = Task { @MainActor [weak self, weak browser] in
            let start = ProcessInfo.processInfo.systemUptime
            var remaining = delay
            do {
                // Sleep in bounded chunks so any finite nonnegative setting is safe to cancel.
                while remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(min(remaining, 3600) * 1_000_000_000))
                    remaining = delay - (ProcessInfo.processInfo.systemUptime - start)
                }
            }
            catch { return }
            guard let self, let browser, !Task.isCancelled else { return }
            self.present(site, browser: browser)
        }
    }
    private func present(_ site: Site, browser: Browser) {
        pending = nil; waitingAddress = nil; waitingBrowser = nil
        guard held, !fired, eligibleBrowser() === browser, browser.hoverLinks?.site?.address == site.address,
              let parent = browser.webView.window, let store,
              let temporary = store.bookmarkPreviewBrowser(for: site) else { return }
        fired = true
        let controller = BookmarkPreviewController(browser: temporary, title: site.title, parent: parent,
                                                   defaults: temporary.previewDefaults)
        controller.onOpenTab = { [weak store] site in
            store?.open(site)
        }
        controller.onClose = { [weak self, weak browser] in
            self?.preview = nil
            self?.cancelWaiting()
            if let browser { browser.webView.window?.makeFirstResponder(browser.webView) }
        }
        preview = controller
        controller.show(in: parent)
    }
    private func cancelWaiting() {
        pending?.cancel(); pending = nil
        waitingAddress = nil; waitingBrowser = nil
    }
    private func reset() {
        held = false; fired = false; cancelWaiting()
    }
}
