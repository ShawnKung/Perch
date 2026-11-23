import AppKit
import SwiftUI
import UniformTypeIdentifiers

func copyAddress(_ address: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(address, forType: .string)
}

struct WindowDragArea: NSViewRepresentable {
    class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
            (window?.delegate as? AppDelegate)?.clampToScreen()
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

struct WindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) { view.positionButtons() }

    final class ControlsView: NSView {
        private var windowObservers: [NSObjectProtocol] = []
        private var hoverTracking: NSTrackingArea?
        private(set) var hovered = false
        var buttons: [NSButton] {
            [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.positionButtons() }
                })
            }
            positionButtons()
        }
        override func layout() { super.layout(); positionButtons() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            hoverTracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                          owner: self)
            addTrackingArea(hoverTracking!)
        }
        override func mouseEntered(with event: NSEvent) { setHovered(true, event: event) }
        override func mouseExited(with event: NSEvent) { setHovered(false, event: event) }
        private func setHovered(_ value: Bool, event: NSEvent) {
            hovered = value
            if value { buttons.first?.superview?.mouseEntered(with: event) }
            else { buttons.first?.superview?.mouseExited(with: event) }
        }
        func positionButtons() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            // Keep the window's own titlebar group so AppKit draws native hover symbols.
            for (index, button) in buttons.enumerated() {
                guard let parent = button.superview else { continue }
                let origin = convert(NSPoint(x: CGFloat(index) * 22, y: 7), to: parent)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
                button.isHidden = false
                if index > 0 {
                    button.target = self
                    button.action = index == 1 ? #selector(minimizeWindow) : #selector(fullScreenWindow)
                }
            }
        }
        deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
        @objc private func minimizeWindow() {
            clearHover()
            if let parent = window?.parent { parent.removeChildWindow(window!) }
            window?.miniaturize(nil)
        }
        @objc private func fullScreenWindow() {
            clearHover()
            if let parent = window?.parent { parent.removeChildWindow(window!) }
            window?.toggleFullScreen(nil)
        }
        private func clearHover() {
            hovered = false
        }
    }
}

private struct SidebarChromeShape: Shape {
    var width: CGFloat
    let top: CGFloat
    let filled: Bool
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let radius = min(Style.chromeRadius, width)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: width - radius, y: top))
        path.addArc(tangent1End: CGPoint(x: width, y: top),
                    tangent2End: CGPoint(x: width, y: top + radius), radius: radius)
        if filled {
            path.addLine(to: CGPoint(x: width, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

struct TabSidebar: View, Animatable {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    var compact = false
    var expansion: CGFloat = 1
    var topBarHeight: CGFloat = 44
    var contentHeight: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(expansion, contentHeight) }
        set { expansion = newValue.first; contentHeight = newValue.second }
    }
    var body: some View {
        let palette = theme.selection
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - 122 - (store.availableUpdate == nil ? 0 : 40))
            VStack(alignment: .leading, spacing: 4) {
                NativeTabList(store: store, compact: compact, expansion: expansion)
                    .frame(height: min(contentHeight, availableHeight))
                    .padding(.leading, -2 - TabListContainer.railGutter)
                    .padding(.trailing, -2)
                    .padding(.top, 38)
                Button { store.newTab() } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: TabSelectionRow.rowHeight)
                        .background {
                            RoundedRectangle(cornerRadius: 8).fill(Style.paper)
                                .frame(height: TabSelectionRow.highlightHeight(width: geometry.size.width,
                                    rowHeight: TabSelectionRow.rowHeight, compact: compact))
                        }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("新建标签页 ⌘T").accessibilityLabel("新建标签页")
                Spacer(minLength: 0)
                if let version = store.availableUpdate {
                    UpdateIndicator(version: version, compact: compact)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .padding(.horizontal, compact ? 0 : 8)
                }
                Color(palette.line).frame(height: 1)
                Button { store.library = .settings } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape").font(.system(size: 15))
                        if !compact { Text("设置").font(.system(size: 12)) }
                    }.frame(maxWidth: .infinity, alignment: compact ? .center : .leading).frame(height: 36)
                        .padding(.horizontal, compact ? 0 : 8).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Style.muted)
                    .help("设置 ⌘,").accessibilityLabel("设置")
            }
            .padding(.bottom, 4)
        }.padding(.horizontal, 8).padding(.top, 12)
            .frame(maxHeight: .infinity).background {
                GeometryReader { geometry in
                        let width = geometry.size.width
                        Style.paper
                        SidebarChromeShape(width: width, top: topBarHeight, filled: true).fill(Color(palette.sidebar))
                        SidebarChromeShape(width: width, top: topBarHeight, filled: false).stroke(Color(palette.line), lineWidth: 1)
                    }.allowsHitTesting(false)
            }
    }
}

struct LibraryView: View {
    @ObservedObject private var theme = PerchTheme.shared
    @ObservedObject var store: Store
    @State var page: LibraryPage
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("完成") { store.library = nil }.keyboardShortcut(.cancelAction).disabled(store.importing)
            }.padding(20)
            Picker("", selection: $page) {
                ForEach(LibraryPage.allCases) { page in Text(page.rawValue).tag(page) }
            }.labelsHidden().pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 14).disabled(store.importing)
            Divider()
            switch page {
            case .ai: AISettingsPage(store: store, ai: store.ai) {
                store.aiVisible = true; store.library = nil
            }
            case .settings: SettingsPage(store: store, openPasswords: { page = .passwords })
            case .importer: ImportPage(store: store)
            case .passwords: PasswordsPage(store: store)
            case .bookmarks: BookmarksPage(store: store)
            }
        }.frame(width: 780, height: 580)
            .background(Style.paper).interactiveDismissDisabled(store.importing)
            .foregroundStyle(Style.ink).tint(Style.accent).preferredColorScheme(.light)
            .alert("提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("知道了") { store.notice = nil }
            } message: { Text(store.notice ?? "") }
    }
}
