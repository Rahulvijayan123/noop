import Foundation
import Sentry

/// Drops app-hang reports that are not hangs.
///
/// The iOS hang tracker (Sentry's V2, frame-delay based) opens a hang when the display link stops
/// delivering frames and closes it when frames resume. A phone that locks while the app is still
/// "active" stops delivering frames with the main thread parked in its run loop, and the hang then
/// stays open until the app is next foregrounded: 2026-10-08 produced 53 of these on one phone, with
/// durations of 6033 s, 2037 s and 860 s while the app was uploading in the background. The stack
/// the tracker captured when it opened the hang is an idle run loop (`mach_msg` under
/// `__CFRunLoopServiceMachPort`), which is the signature of a main thread with nothing to do.
///
/// A real hang has the main thread running or blocked on something, so its innermost frames are never
/// that run-loop wait. Matching the exact frame pair keeps a thread blocked in a synchronous
/// `mach_msg` (XPC, CARenderServer) reported.
enum SentryHangFilter {
    /// Innermost-first symbol names resolved from the frames' instruction addresses, or nil when a
    /// frame cannot be resolved. Injectable so the rule can be tested without a live process.
    typealias SymbolResolver = (_ instructionAddress: UInt) -> String?

    static func shouldDrop(_ event: Event, resolve: SymbolResolver = { symbol(at: $0) }) -> Bool {
        guard isAppHang(event), event.level != .fatal else { return false }
        guard let frames = hangStack(of: event)?.frames, !frames.isEmpty else { return false }
        let names: [String?] = frames.reversed().prefix(8).map { frame in
            guard let hex = frame.instructionAddress, let address = parseAddress(hex) else { return nil }
            return resolve(address)
        }
        return isIdleRunLoop(innermostFirst: names)
    }

    /// `mach_msg*` frames followed by `__CFRunLoopServiceMachPort`: the run loop waiting for work.
    static func isIdleRunLoop(innermostFirst names: [String?]) -> Bool {
        var index = 0
        while index < names.count, let name = names[index], name.hasPrefix("mach_msg") { index += 1 }
        guard index > 0, index < names.count, let next = names[index] else { return false }
        return next == "__CFRunLoopServiceMachPort"
    }

    private static func isAppHang(_ event: Event) -> Bool {
        event.exceptions?.contains { $0.mechanism?.type == "AppHang" } ?? false
    }

    /// The stack the tracker snapshotted when the hang opened: the exception's, else the current thread's.
    private static func hangStack(of event: Event) -> SentryStacktrace? {
        if let stack = event.exceptions?.first(where: { $0.mechanism?.type == "AppHang" })?.stacktrace {
            return stack
        }
        return event.threads?.first(where: { $0.current?.boolValue == true })?.stacktrace
    }

    private static func parseAddress(_ hex: String) -> UInt? {
        let digits = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt(digits, radix: 16)
    }

    /// The name of the exported symbol containing the address in this process (system libraries export
    /// `mach_msg2_trap` and `__CFRunLoopServiceMachPort`, so no symbol file is needed).
    static func symbol(at address: UInt) -> String? {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return nil }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let name = info.dli_sname else { return nil }
        return String(cString: name)
    }
}
