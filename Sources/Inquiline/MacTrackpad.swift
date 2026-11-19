import AppKit
import ApplicationServices

/// The phone's Mac tab as the Mac's trackpad: the pointer, clicks, dragging, scrolling with
/// momentum, and the gestures macOS lets an app make, by the keys and apps the Mac's own
/// gestures use. The page tells gestures apart; this makes the Mac's events, which needs the
/// user's Accessibility permission.
///
/// Moves and scrolls come as running totals, over WebRTC, where one may be lost or late: the
/// newest total holds every move before it. They go to the Mac at a steady 120 a second, so the
/// pointer glides through Wi-Fi's bursts and gaps instead of jumping.
final class MacTrackpad {
    /// To the phones: whether the Mac lets Inquiline move the pointer.
    var tell: (([String: Any]) -> Void)?

    private let queue = DispatchQueue(label: "inquiline.mac-trackpad", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    private struct Totals { var s = 0.0, moveX = 0.0, moveY = 0.0, scrollX = 0.0, scrollY = 0.0 }
    private var totals: [ObjectIdentifier: Totals] = [:]
    /// What's yet to go to the Mac, in the phone's pixels.
    private var scrollX = 0.0, scrollY = 0.0
    /// The finger's moves, in the phone's pixels: all received so far and when the last came;
    /// its speed, by the phone's own clock, as the network bunches moves up; the way it last
    /// went; and how far the pointer has gone. Through a gap in the Wi-Fi the pointer keeps
    /// going the way it went, for up to 100 ms, as it most likely did. It never goes back, as
    /// a real one doesn't: past where the finger turns out to be, it waits for it.
    private var receivedX = 0.0, receivedY = 0.0, receivedAt: TimeInterval = 0, phoneTime = 0.0
    private var speedOfMoveX = 0.0, speedOfMoveY = 0.0, shownX = 0.0, shownY = 0.0
    private var wayX = 0.0, wayY = 0.0
    private var dragging = false
    private var scrolling = false, scrollEnding = false
    /// The scroll's speed as it went out, in pixels a tick, carried on as momentum after.
    private var speedX = 0.0, speedY = 0.0
    private var coasting = false
    private var lastClick: (time: TimeInterval, at: CGPoint, count: Int64)?
    private var pacer: DispatchSourceTimer?
    private var trusted = false, asked = false
    private var watcher: DispatchSourceTimer?
    /// How evenly moves arrive, for the log.
    private var moveStart: TimeInterval = 0, lastMove: TimeInterval = 0, longestGap: TimeInterval = 0, moves = 0
    private var longestPhoneGap: TimeInterval = 0

    func handle(_ message: [String: Any], phone: ObjectIdentifier) {
        queue.async { [self] in
            guard allowed() else { return }
            func number(_ name: String) -> Double { (message[name] as? NSNumber)?.doubleValue ?? 0 }
            switch message["k"] as? String {
            case "move", "scroll":
                var known = totals[phone] ?? Totals()
                let s = number("s")
                guard s > known.s else { return }
                known.s = s
                let x = number("x"), y = number("y")
                if message["k"] as? String == "move" {
                    let now = ProcessInfo.processInfo.systemUptime
                    let dx = x - known.moveX, dy = y - known.moveY
                    known.moveX = x; known.moveY = y
                    let resting = message["rest"] != nil
                    let time = number("ts") / 1000, dt = time - phoneTime
                    phoneTime = time
                    if !resting, moves > 0, dt < 1 { longestPhoneGap = max(longestPhoneGap, dt) }
                    if resting || dt <= 0 || dt > 0.25 {
                        speedOfMoveX = 0; speedOfMoveY = 0
                    } else {
                        speedOfMoveX = speedOfMoveX * 0.5 + dx / dt * 0.5
                        speedOfMoveY = speedOfMoveY * 0.5 + dy / dt * 0.5
                    }
                    if dx != 0 { wayX = dx > 0 ? 1 : -1 }
                    if dy != 0 { wayY = dy > 0 ? 1 : -1 }
                    receivedX += dx; receivedY += dy; receivedAt = now
                    // The finger stopped short of where the pointer went: it stays.
                    if resting {
                        if (receivedX - shownX) * wayX < 0 { shownX = receivedX }
                        if (receivedY - shownY) * wayY < 0 { shownY = receivedY }
                    }
                    if resting {
                        if moves >= 30 {
                            AppLog.write(String(format: "Mac trackpad move: %d moves in %.1f s (%.0f a second), longest gap %.0f ms, on the phone %.0f ms",
                                                moves, now - moveStart, Double(moves) / (now - moveStart), longestGap * 1000,
                                                longestPhoneGap * 1000))
                        }
                        moves = 0
                    } else {
                        if moves == 0 { moveStart = now; longestGap = 0; longestPhoneGap = 0 } else { longestGap = max(longestGap, now - lastMove) }
                        lastMove = now; moves += 1
                    }
                } else {
                    if !scrolling { stopCoasting(); scrolling = true; scrollEnding = false; post(scroll: 0, 0, phase: 1) }
                    scrollX += x - known.scrollX; scrollY += y - known.scrollY
                    known.scrollX = x; known.scrollY = y
                }
                totals[phone] = known
                startPacing()
            case "hold":
                // A finger on the trackpad stops a coasting scroll, as on the Mac's own; and the
                // pointer starts from where it is, as the mouse may have moved it.
                stopCoasting()
                if !dragging { cursor = nil }
            case "scrollEnd":
                scrollEnding = true
                startPacing()
            case "click":
                if message["b"] as? String == "right" {
                    press(.rightMouseDown, .rightMouseUp, button: .right)
                } else {
                    press(.leftMouseDown, .leftMouseUp, button: .left)
                }
            case "down":
                flushMove()
                post(mouse: .leftMouseDown, button: .left, clicks: clickCount())
                dragging = true
            case "up":
                flushMove()
                post(mouse: .leftMouseUp, button: .left, clicks: lastClick?.count ?? 1)
                dragging = false
            case "swipe":
                swipe(message["d"] as? String ?? "")
            case "zoom":
                key(message["d"] as? String == "in" ? 24 : 27, flags: .maskCommand) // ⌘= and ⌘-
            case "lookup":
                // A force click's action: Look Up, ⌃⌘D.
                key(2, flags: [.maskCommand, .maskControl])
            default:
                break
            }
        }
    }

    /// The phones are gone: let go of anything held.
    func reset() {
        queue.async { [self] in
            if dragging { post(mouse: .leftMouseUp, button: .left, clicks: 1); dragging = false }
            if scrolling { post(scroll: 0, 0, phase: 4); scrolling = false }
            stopCoasting()
            totals = [:]
            cursor = nil
            asked = false
            shownX = receivedX; shownY = receivedY; speedOfMoveX = 0; speedOfMoveY = 0; scrollX = 0; scrollY = 0
        }
    }

    // MARK: Permission

    private func allowed() -> Bool {
        if trusted { return true }
        trusted = AXIsProcessTrusted()
        if trusted {
            tell?(["t": "access", "ok": true])
            return true
        }
        tell?(["t": "access", "ok": false])
        // Asked once for each time a phone connects, as it may have been turned down or
        // removed from the list since.
        if !asked {
            asked = true
            AppLog.write("The Mac's trackpad waits for Accessibility permission")
            DispatchQueue.main.async {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        }
        // The phone hears as soon as it's given, without another touch.
        if watcher == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, AXIsProcessTrusted() else { return }
                self.watcher?.cancel()
                self.watcher = nil
                self.trusted = true
                AppLog.write("The Mac's trackpad has Accessibility permission")
                self.tell?(["t": "access", "ok": true])
            }
            timer.resume()
            watcher = timer
        }
        return false
    }

    // MARK: Pacing

    private func startPacing() {
        guard pacer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .nanoseconds(500_000))
        timer.setEventHandler { [weak self] in self?.pace() }
        timer.resume()
        pacer = timer
    }

    private func pace() {
        var busy = false
        // Most of the way each tick: smooth, and only a few milliseconds behind.
        let now = ProcessInfo.processInfo.systemUptime
        let ahead = min(max(now - receivedAt, 0), 0.1)
        let targetX = receivedX + speedOfMoveX * ahead, targetY = receivedY + speedOfMoveY * ahead
        var dx = (targetX - shownX) * 0.5, dy = (targetY - shownY) * 0.5
        if dx * wayX < 0 { dx = 0 }
        if dy * wayY < 0 { dy = 0 }
        if abs(dx) >= 0.05 || abs(dy) >= 0.05 {
            shownX += dx; shownY += dy
            movePointer(dx, dy)
            busy = true
        }
        if now - receivedAt < 0.12 && (speedOfMoveX != 0 || speedOfMoveY != 0) { busy = true }
        if scrolling {
            let dx = scrollX * 0.6, dy = scrollY * 0.6
            scrollX -= dx; scrollY -= dy
            if abs(dx) >= 0.05 || abs(dy) >= 0.05 {
                post(scroll: dx, dy, phase: 2)
                speedX = speedX * 0.6 + dx * 0.4; speedY = speedY * 0.6 + dy * 0.4
            }
            if scrollEnding && abs(scrollX) < 0.5 && abs(scrollY) < 0.5 {
                post(scroll: 0, 0, phase: 4)
                scrolling = false; scrollEnding = false
                coasting = hypot(speedX, speedY) > 1
                if coasting { post(scroll: speedX, speedY, momentum: 1) } else { speedX = 0; speedY = 0 }
            }
            busy = true
        } else if coasting {
            // Slowing as the Mac's own trackpad does, for about a second.
            speedX *= 0.965; speedY *= 0.965
            if hypot(speedX, speedY) < 0.3 { stopCoasting() } else { post(scroll: speedX, speedY, momentum: 2) }
            busy = true
        }
        if !busy {
            pacer?.cancel()
            pacer = nil
        }
    }

    private func stopCoasting() {
        guard coasting else { return }
        coasting = false
        speedX = 0; speedY = 0
        post(scroll: 0, 0, momentum: 3)
    }

    private func flushMove() {
        let dx = receivedX - shownX, dy = receivedY - shownY
        movePointer(dx * wayX < 0 ? 0 : dx, dy * wayY < 0 ? 0 : dy)
        shownX = receivedX; shownY = receivedY
        speedOfMoveX = 0; speedOfMoveY = 0
    }

    // MARK: Events

    /// Where this has put the pointer. The Mac's own answer lags behind events just posted, so
    /// moves read from it would be lost and a click would land where the pointer was.
    private var cursor: CGPoint?
    private var pointer: CGPoint { cursor ?? CGEvent(source: nil)?.location ?? .zero }

    /// Faster the faster the finger goes, as the Mac's own pointer: by the finger's speed, in
    /// the phone's pixels a second, which changes smoothly, not by each step's size.
    private func movePointer(_ dx: Double, _ dy: Double) {
        let speed = hypot(speedOfMoveX, speedOfMoveY)
        let gain = 1.0 + 2.6 * pow(min(speed / 1200, 1), 0.8)
        let from = pointer
        var to = CGPoint(x: from.x + dx * gain, y: from.y + dy * gain)
        // On a screen: past the edge of all of them it stops at the edge of the one it's on.
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(to, 0, nil, &count)
        if count == 0 {
            var display: CGDirectDisplayID = CGMainDisplayID()
            CGGetDisplaysWithPoint(from, 1, &display, &count)
            let bounds = CGDisplayBounds(display)
            to.x = min(max(to.x, bounds.minX), bounds.maxX - 1)
            to.y = min(max(to.y, bounds.minY), bounds.maxY - 1)
        }
        let event = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: to, mouseButton: .left)
        event?.setDoubleValueField(.mouseEventDeltaX, value: to.x - from.x)
        event?.setDoubleValueField(.mouseEventDeltaY, value: to.y - from.y)
        event?.post(tap: .cghidEventTap)
        cursor = to
    }

    /// One more for a click soon after another in the same place, as a double click.
    private func clickCount() -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime, at = pointer
        var count: Int64 = 1
        if let last = lastClick, now - last.time < NSEvent.doubleClickInterval,
           abs(at.x - last.at.x) < 5, abs(at.y - last.at.y) < 5 { count = last.count + 1 }
        lastClick = (now, at, count)
        return count
    }

    private func press(_ down: CGEventType, _ up: CGEventType, button: CGMouseButton) {
        flushMove()
        let clicks = button == .left ? clickCount() : 1
        post(mouse: down, button: button, clicks: clicks)
        post(mouse: up, button: button, clicks: clicks)
    }

    private func post(mouse type: CGEventType, button: CGMouseButton, clicks: Int64) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pointer, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        // A plain click: no modifier the Mac thinks is held, as Control would make it a right click.
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }

    /// In the phone's pixels, which follow the finger; the Mac's scroll direction setting,
    /// natural or not, as its own trackpad.
    private func post(scroll dx: Double, _ dy: Double, phase: Int64 = 0, momentum: Int64 = 0) {
        let natural = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
        let sign = natural ? 1.0 : -1.0
        let y = Int32((dy * sign).rounded()), x = Int32((dx * sign).rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy * sign)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx * sign)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Three fingers, as on the Mac's trackpad: up for Mission Control, down for the app's
    /// windows, sideways for the next or previous desktop.
    private func swipe(_ direction: String) {
        switch direction {
        case "up", "down":
            let app = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            let configuration = NSWorkspace.OpenConfiguration()
            if direction == "down" { configuration.arguments = ["2"] }
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        case "left":
            key(124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]) // ⌃→: the desktop on the right
        case "right":
            key(123, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad]) // ⌃←
        default:
            break
        }
    }
}
