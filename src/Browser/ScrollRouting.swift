import AppKit

final class ScrollRouting {
    // A non-scrollable element with overscroll containment can still swallow wheels in WebKit.
    // Handle only that case; real scroll containers retain native scrolling at their edges.
    static let script = #"""
    document.addEventListener('wheel', event => {
        if (!event.isTrusted || !event.cancelable || event.defaultPrevented ||
            event.ctrlKey || event.metaKey || (!event.deltaX && !event.deltaY)) return;
        const vertical = Math.abs(event.deltaY) >= Math.abs(event.deltaX);
        let trapped = false;
        for (let element = event.composedPath()[0]; element instanceof Element;
             element = element.parentElement || element.getRootNode().host) {
            const style = getComputedStyle(element);
            const overflow = vertical ? style.overflowY : style.overflowX;
            const range = vertical ? element.scrollHeight - element.clientHeight
                                   : element.scrollWidth - element.clientWidth;
            if (range > 1 && (/^(auto|scroll)$/.test(overflow) ||
                (element === document.scrollingElement && overflow === 'visible'))) {
                if (!trapped) return;
                const unit = event.deltaMode === 1 ? (parseFloat(style.lineHeight) || 16) : 1;
                const delta = (vertical ? event.deltaY : event.deltaX) *
                    (event.deltaMode === 2 ? (vertical ? element.clientHeight : element.clientWidth) : unit);
                event.preventDefault();
                element.scrollBy({top: vertical ? delta : 0, left: vertical ? 0 : delta,
                                  behavior: 'instant'});
                return;
            }
            const containment = vertical ? style.overscrollBehaviorY : style.overscrollBehaviorX;
            if (/^(contain|none)$/.test(containment) && /^(auto|scroll|hidden)$/.test(overflow)) {
                trapped = true;
            }
        }
    }, {capture: true, passive: false});
    """#
    private var location: NSPoint?

    func events(for event: NSEvent) -> [NSEvent] {
        let previous = location
        let continuous = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        location = continuous ? event.locationInWindow : nil
        if event.phase.contains(.cancelled) ||
            event.momentumPhase.contains(.ended) {
            location = nil
        }
        guard continuous,
              !event.phase.contains(.ended), !event.phase.contains(.cancelled),
              !event.momentumPhase.contains(.ended),
              let previous, hypot(event.locationInWindow.x - previous.x,
                                  event.locationInWindow.y - previous.y) > 1,
              let end = copy(event, at: previous, phase: 0, zeroDelta: true),
              let begin = copy(event, at: event.locationInWindow, phase: 1, zeroDelta: false) else {
            return [event]
        }
        // WebKit latches continuous wheels to their initial target. End that gesture at its
        // old location and begin at the actual pointer, preserving native hit testing and scrolling.
        return [end, begin]
    }

    private func copy(_ event: NSEvent, at point: NSPoint, phase: Int64, zeroDelta: Bool) -> NSEvent? {
        guard let cg = event.cgEvent?.copy() else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        // WebKit keeps a recent latch after finger-up. A terminal momentum phase clears both
        // the DOM and scrolling-tree latch before the new gesture, without waiting for a timeout.
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: zeroDelta ? 3 : 0)
        if zeroDelta {
            for field: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                       .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
                                       .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
                cg.setIntegerValueField(field, value: 0)
            }
        }
        // CG-created NSEvents have no associated NSWindow; WebKit then reads locationInWindow
        // directly. Supply window coordinates instead of the original global screen coordinates.
        cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        return NSEvent(cgEvent: cg)
    }
}
