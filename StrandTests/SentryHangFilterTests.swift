import XCTest
import Sentry
@testable import Strand

/// The app-hang filter: a run-loop-idle "hang" is dropped, a real stall or a main thread blocked in a
/// synchronous mach call is kept. Names are injected, so nothing here depends on the test host's own frames.
final class SentryHangFilterTests: XCTestCase {
    private func hangEvent(addresses: [UInt], level: SentryLevel = .error, mechanism: String = "AppHang") -> Event {
        let frames = addresses.map { address -> Frame in
            let frame = Frame()
            frame.instructionAddress = "0x" + String(address, radix: 16)
            return frame
        }
        let stack = SentryStacktrace(frames: frames, registers: [:])
        let exception = Exception(value: "App hanging between 0.5 and 0.6 seconds.", type: "App Hang Fully Blocked")
        exception.mechanism = Mechanism(type: mechanism)
        exception.stacktrace = stack
        let event = Event(level: level)
        event.exceptions = [exception]
        return event
    }

    /// Frames are oldest-first, so the innermost frame is the last address.
    private func resolver(_ names: [UInt: String]) -> SentryHangFilter.SymbolResolver {
        { names[$0] }
    }

    private let idleRunLoop: [UInt: String] = [
        1: "start", 2: "__CFRunLoopRun", 3: "__CFRunLoopServiceMachPort",
        4: "mach_msg", 5: "mach_msg_overwrite", 6: "mach_msg2_internal", 7: "mach_msg2_trap",
    ]

    func testIdleRunLoopHangIsDropped() {
        let event = hangEvent(addresses: [1, 2, 3, 4, 5, 6, 7])
        XCTAssertTrue(SentryHangFilter.shouldDrop(event, resolve: resolver(idleRunLoop)))
    }

    func testMachMsgBlockedOnSomethingElseIsKept() {
        // A synchronous render-server call parks the thread in the same mach_msg frames, below a different caller.
        var names = idleRunLoop
        names[3] = "CARenderServerSnapshot"
        let event = hangEvent(addresses: [1, 2, 3, 4, 5, 6, 7])
        XCTAssertFalse(SentryHangFilter.shouldDrop(event, resolve: resolver(names)))
    }

    func testBusyMainThreadIsKept() {
        let names: [UInt: String] = [1: "start", 2: "runJob", 3: "__CFStringAppendFormatCore"]
        XCTAssertFalse(SentryHangFilter.shouldDrop(hangEvent(addresses: [1, 2, 3]), resolve: resolver(names)))
    }

    func testUnresolvedFramesAreKept() {
        XCTAssertFalse(SentryHangFilter.shouldDrop(hangEvent(addresses: [1, 2, 3]), resolve: { _ in nil }))
    }

    func testNonHangEventsAreNeverDropped() {
        let event = hangEvent(addresses: [1, 2, 3, 4, 5, 6, 7], mechanism: "NSError")
        XCTAssertFalse(SentryHangFilter.shouldDrop(event, resolve: resolver(idleRunLoop)))
    }

    func testFatalHangsAreKept() {
        // A fatal hang is sent by the next launch, when the addresses no longer resolve to this process's symbols.
        let event = hangEvent(addresses: [1, 2, 3, 4, 5, 6, 7], level: .fatal)
        XCTAssertFalse(SentryHangFilter.shouldDrop(event, resolve: resolver(idleRunLoop)))
    }

    func testIdleRunLoopRule() {
        XCTAssertTrue(SentryHangFilter.isIdleRunLoop(innermostFirst: ["mach_msg2_trap", "mach_msg", "__CFRunLoopServiceMachPort"]))
        XCTAssertFalse(SentryHangFilter.isIdleRunLoop(innermostFirst: ["__CFRunLoopServiceMachPort"]))
        XCTAssertFalse(SentryHangFilter.isIdleRunLoop(innermostFirst: ["mach_msg2_trap"]))
        XCTAssertFalse(SentryHangFilter.isIdleRunLoop(innermostFirst: []))
    }

    func testRealProcessSymbolResolves() {
        // The default resolver finds an exported libSystem symbol by address.
        let address = unsafeBitCast(getpid as @convention(c) () -> pid_t, to: UInt.self)
        // libsystem exports the implementation as `__getpid`; either spelling names the same function.
        XCTAssertEqual(SentryHangFilter.symbol(at: address)?.drop(while: { $0 == "_" }), "getpid")
    }
}
