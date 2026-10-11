import Foundation

/// Turns raw hotkey press/release edges from `HotkeyMonitor` into start/stop
/// recording gestures, supporting two independent ways to drive dictation:
///
/// - **Hold**: press and hold the hotkey to record, release to stop. This is
///   the original behavior.
/// - **Toggle**: double-tap the hotkey to start recording hands-free, then
///   tap once more (any duration) to stop it.
///
/// A "tap" is a press+release shorter than `tapThreshold`. Two taps in a row
/// within `doubleTapWindow` of each other count as a double-tap.
///
/// Must be driven from a single serial context (the main queue, matching
/// `HotkeyMonitor`'s own callback thread) — it's not thread-safe on its own.
final class DictationTrigger {
    enum Gesture { case start, stop }

    private enum State {
        case idle
        case recording(pressedAt: Date)  // down now; started via a hold or the first tap
        case awaitingSecondTap           // released quickly once; waiting to see if it's a double-tap
        case latched                     // started via double-tap; the next tap stops it
    }

    private let tapThreshold: TimeInterval
    private let doubleTapWindow: TimeInterval
    private var state: State = .idle
    private var pendingTimeout: DispatchWorkItem?

    init(tapThreshold: TimeInterval = 0.3, doubleTapWindow: TimeInterval = 0.35) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    func handle(_ event: HotkeyMonitor.Event, emit: @escaping (Gesture) -> Void) {
        switch (state, event) {
        case (.idle, .pressed):
            // Start immediately regardless of what this turns out to be —
            // don't make the user wait to find out if it's a hold or a tap.
            state = .recording(pressedAt: Date())
            emit(.start)

        case (.recording(let pressedAt), .released):
            let held = Date().timeIntervalSince(pressedAt)
            if held >= tapThreshold {
                state = .idle
                emit(.stop)
            } else {
                // Too quick to be a deliberate hold — might be the first half
                // of a double-tap. Keep recording and wait to find out.
                state = .awaitingSecondTap
                scheduleTimeout(doubleTapWindow) { [weak self] in
                    guard let self, case .awaitingSecondTap = self.state else { return }
                    self.state = .idle
                    emit(.stop)
                }
            }

        case (.awaitingSecondTap, .pressed):
            // Confirmed double-tap. Recording never stopped — just switch to
            // latched mode so the key can be released without ending it.
            cancelTimeout()
            state = .latched

        case (.latched, .pressed):
            // The closing tap.
            cancelTimeout()
            state = .idle
            emit(.stop)

        case (.awaitingSecondTap, .released), (.latched, .released),
             (.recording, .pressed), (.idle, .released):
            break  // spurious repeats from the event source; ignore
        }
    }

    private func scheduleTimeout(_ delay: TimeInterval, action: @escaping () -> Void) {
        cancelTimeout()
        let work = DispatchWorkItem(block: action)
        pendingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimeout() {
        pendingTimeout?.cancel()
        pendingTimeout = nil
    }
}
