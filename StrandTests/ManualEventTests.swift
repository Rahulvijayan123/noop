import XCTest
@testable import Strand

final class ManualEventTests: XCTestCase {
    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "22222222-2222-4222-8222-222222222222"
    private func event() -> ManualEventEntry {
        ManualEventEntry(id: UUID(), kind: .event, label: "Walking", typeId: UUID(),
                         startUnixSeconds: 1_791_000_000, endUnixSeconds: 1_791_000_300)
    }

    func testArchiveRetainsOriginalAndEveryEditAcrossReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("event-test-\(UUID()).sqlite").path
        let store = try ManualEventStore(path: path)
        var entry = event()
        try store.save(entry, owner: ownerA)
        entry.note = "Morning walk"; try store.save(entry, owner: ownerA)
        entry.archived = true; entry.archivedAt = 1_791_000_600; try store.save(entry, owner: ownerA)
        let reopened = try ManualEventStore(path: path)
        XCTAssertEqual(try reopened.history(owner: ownerA).count, 3)
        XCTAssertNil(try reopened.history(owner: ownerA).first?.entry.note)
        XCTAssertEqual(try reopened.latest(owner: ownerA), [entry])
        XCTAssertTrue(try reopened.latest(owner: ownerB).isEmpty)
    }

    func testRawSQLCannotEraseOrChangeEventContent() throws {
        let store = try ManualEventStore(path: ":memory:")
        try store.save(event(), owner: ownerA)
        XCTAssertThrowsError(try store.executeForTesting("DELETE FROM manualEventRevision"))
        XCTAssertThrowsError(try store.executeForTesting("UPDATE manualEventRevision SET body = '{}'"))
        XCTAssertEqual(try store.history(owner: ownerA).count, 1)
    }

    func testAcknowledgementOnlyMarksExactAccountRevisionAndLaterEditStaysPending() throws {
        let store = try ManualEventStore(path: ":memory:")
        var entry = event()
        let first = try store.save(entry, owner: ownerA)
        try store.insert(first, owner: ownerB, synced: false)
        entry.note = "New note"; let edit = try store.save(entry, owner: ownerA)
        try store.markSynced(owner: ownerA, ids: [first.revisionId])
        XCTAssertEqual(try store.pending(owner: ownerA).map(\.revisionId), [edit.revisionId])
        XCTAssertEqual(try store.pending(owner: ownerB).count, 1)
    }

    func testIdenticalCloudReplayIsIdempotentButConflictingUUIDIsRejected() throws {
        let store = try ManualEventStore(path: ":memory:")
        let revision = try store.save(event(), owner: ownerA)
        try store.insert(revision, owner: ownerA, synced: true)
        XCTAssertEqual(try store.history(owner: ownerA).count, 1)
        XCTAssertTrue(try store.pending(owner: ownerA).isEmpty)
        var other = revision.entry; other.label = "Different"
        XCTAssertThrowsError(try store.insert(ManualEventRevision(revisionId: revision.revisionId,
            updatedAtMs: revision.updatedAtMs, entry: other), owner: ownerA, synced: true))
    }

    func testClockMovingBackwardsDoesNotLoseLatestArchive() throws {
        let store = try ManualEventStore(path: ":memory:")
        var entry = event()
        let a = try store.save(entry, owner: ownerA, now: Date(timeIntervalSince1970: 1000))
        entry.archived = true; entry.archivedAt = 10
        let b = try store.save(entry, owner: ownerA, now: Date(timeIntervalSince1970: 10))
        XCTAssertGreaterThan(b.updatedAtMs, a.updatedAtMs)
        XCTAssertEqual(try store.latest(owner: ownerA).first?.archived, true)
    }

    func testMovingFiveMinuteWindowAcrossMidnightPreservesDurationThenEndpointsCanChangeIt() {
        let anchor = Date(timeIntervalSince1970: 1_791_000_000)
        var window = ManualEventWindow(anchor: anchor, durationMinutes: 5)
        window.shift(minutes: -1440)
        XCTAssertEqual(window.durationMinutes, 5)
        XCTAssertEqual(window.start, anchor.addingTimeInterval(-86400))
        window.end = window.end.addingTimeInterval(120)
        XCTAssertEqual(window.durationMinutes, 7)
    }

    @MainActor
    func testAccountSwitchHidesOldHistoryAndStaleEditorCannotSaveAsNewUser() throws {
        let store = try ManualEventStore(path: ":memory:")
        var active: CloudPushIdentity? = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString,
                                                          tokenId: UUID().uuidString, uploadToken: "fixture")
        let center = ManualEventCenter(store: store, identity: { active }, endpoint: { nil })
        center.bindAccount()
        let entry = event()
        XCTAssertTrue(center.save(entry, for: ownerA))
        active = CloudPushIdentity(ownerId: ownerB, sourceId: UUID().uuidString, tokenId: UUID().uuidString, uploadToken: "fixture")
        center.bindAccount()
        XCTAssertTrue(center.events.isEmpty)
        XCTAssertFalse(center.save(entry, for: ownerA))
        XCTAssertTrue(try store.latest(owner: ownerB).allSatisfy { $0.kind != .event })
        active = nil; center.bindAccount()
        XCTAssertNil(center.owner); XCTAssertTrue(center.entries.isEmpty)
    }

    @MainActor
    func testArchiveEndsRunningEventAndRestoreKeepsLabel() throws {
        let store = try ManualEventStore(path: ":memory:")
        let id = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString, tokenId: UUID().uuidString, uploadToken: "fixture")
        let center = ManualEventCenter(store: store, identity: { id }, endpoint: { nil })
        center.bindAccount()
        var entry = event(); entry.endUnixSeconds = nil
        XCTAssertTrue(center.save(entry, for: ownerA))
        center.archive(entry)
        XCTAssertTrue(center.events.isEmpty)
        let archived = try XCTUnwrap(center.archived.first { $0.id == entry.id })
        XCTAssertNotNil(archived.endUnixSeconds)
        center.restore(archived)
        XCTAssertEqual(center.events.first?.label, entry.label)
        XCTAssertEqual(try store.history(owner: ownerA).filter { $0.entry.id == entry.id }.count, 3)
    }

    func testReducedCatalogKeepsStableIDsAndArchivesOldTypesWithoutChangingEvents() throws {
        XCTAssertEqual(ManualEventEntry.defaultTypes.map(\.label), ["Rest", "Walking", "Exercise"])
        XCTAssertEqual(ManualEventEntry.defaultTypes.last?.id.uuidString.lowercased(), "00000000-0000-4000-8000-000000000011")
        let store = try ManualEventStore(path: ":memory:")
        let old = try XCTUnwrap(ManualEventEntry.retiredDefaultTypes.first { $0.label == "Medication" })
        try store.insert(ManualEventRevision(revisionId: old.id, updatedAtMs: 1, entry: old), owner: ownerA, synced: false)
        var past = event(); past.typeId = old.id; past.label = old.label; past.symbol = old.symbol
        try store.save(past, owner: ownerA)
        try store.retireLegacyDefaults(owner: ownerA)
        XCTAssertEqual(try store.latest(owner: ownerA).first { $0.id == old.id }?.archived, true)
        XCTAssertEqual(try store.latest(owner: ownerA).first { $0.id == past.id }, past)
        XCTAssertEqual(try store.history(owner: ownerA).filter { $0.entry.id == old.id }.count, 2)
        let count = try store.history(owner: ownerA).count
        try store.retireLegacyDefaults(owner: ownerA)
        XCTAssertEqual(try store.history(owner: ownerA).count, count)
        var restored = try XCTUnwrap(store.latest(owner: ownerA).first { $0.id == old.id })
        restored.archived = false; restored.archivedAt = nil
        try store.save(restored, owner: ownerA)
        try store.retireLegacyDefaults(owner: ownerA)
        XCTAssertEqual(try store.latest(owner: ownerA).first { $0.id == old.id }?.archived, false)
    }

    func testCatalogTrimPreservesCustomizedTypesAndIsAccountScoped() throws {
        let store = try ManualEventStore(path: ":memory:")
        var renamed = ManualEventEntry.retiredDefaultTypes[0]; renamed.label = "My label"
        var icon = ManualEventEntry.retiredDefaultTypes[1]; icon.symbol = "star.fill"
        var favorite = ManualEventEntry.retiredDefaultTypes[2]; favorite.favorite = true
        for entry in [renamed, icon, favorite] { try store.save(entry, owner: ownerA) }
        let retired = ManualEventEntry.retiredDefaultTypes[3]
        let seed = ManualEventRevision(revisionId: retired.id, updatedAtMs: 1, entry: retired)
        try store.insert(seed, owner: ownerA, synced: false); try store.insert(seed, owner: ownerB, synced: false)
        try store.retireLegacyDefaults(owner: ownerA)
        let latest = try store.latest(owner: ownerA)
        for entry in [renamed, icon, favorite] { XCTAssertTrue(latest.contains(entry)) }
        XCTAssertEqual(try store.latest(owner: ownerB).first?.archived, false)
        try store.retireLegacyDefaults(owner: ownerB)
        XCTAssertEqual(try store.latest(owner: ownerB).first?.archived, true)
    }

    func testOldFactoryTypeReceivedLaterStillGetsArchived() throws {
        let store = try ManualEventStore(path: ":memory:")
        try store.retireLegacyDefaults(owner: ownerA)
        let old = ManualEventEntry.retiredDefaultTypes[0]
        try store.insert(ManualEventRevision(revisionId: old.id, updatedAtMs: 1, entry: old), owner: ownerA, synced: true)
        try store.retireLegacyDefaults(owner: ownerA)
        XCTAssertEqual(try store.latest(owner: ownerA).first?.archived, true)
        XCTAssertEqual(try store.pending(owner: ownerA).count, 1)
    }

    func testCustomIconSurvivesPersistenceAndChangesKeepOriginalIconRevision() throws {
        let store = try ManualEventStore(path: ":memory:")
        var type = ManualEventEntry(id: UUID(), kind: .eventType, label: "My activity", symbol: "bicycle")
        try store.save(type, owner: ownerA)
        type.symbol = "moon.fill"; try store.save(type, owner: ownerA)
        XCTAssertEqual(try store.latest(owner: ownerA).first?.symbol, "moon.fill")
        XCTAssertEqual(try store.history(owner: ownerA).first?.entry.symbol, "bicycle")
    }

    func testActivityKindDefaultsForFactoryTypesWithoutChangingTheirSeedBytes() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for type in ManualEventEntry.defaultTypes {
            let body = String(decoding: try encoder.encode(type), as: UTF8.self)
            XCTAssertFalse(body.contains("activityKind"), "a seed revision must stay byte-identical across app versions")
        }
        XCTAssertEqual(ManualEventEntry.defaultTypes.map { $0.effectiveActivityKind }, [.rest, .walking, .exercise])
        var event = event(); event.typeId = ManualEventEntry.defaultTypes[1].id
        XCTAssertEqual(event.effectiveActivityKind, .walking)
        event.activityKind = "running"
        XCTAssertEqual(event.effectiveActivityKind, .running)
        XCTAssertNil(ManualEventEntry(id: UUID(), kind: .eventType, label: "Reading").effectiveActivityKind)
    }

    @MainActor
    func testAnEventWithoutItsOwnKindFollowsItsTypeLikeTheServer() throws {
        let store = try ManualEventStore(path: ":memory:")
        let id = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString, tokenId: UUID().uuidString, uploadToken: "fixture")
        let center = ManualEventCenter(store: store, automaticallySync: false, identity: { id }, endpoint: { nil })
        center.bindAccount()
        var walking = try XCTUnwrap(center.types.first { $0.label == "Walking" })
        var old = event(); old.typeId = walking.id; old.label = walking.label
        XCTAssertTrue(center.save(old, for: ownerA))
        XCTAssertEqual(center.effectiveKind(of: old), .walking)
        walking.activityKind = "running"
        XCTAssertTrue(center.save(walking, for: ownerA))
        XCTAssertEqual(center.effectiveKind(of: old), .running, "the server resolves the type's current kind first")
        var own = old; own.activityKind = "rest"
        XCTAssertEqual(center.effectiveKind(of: own), .rest)
    }

    func testValidationMatchesTheServerRules() throws {
        var bad = event(); bad.activityKind = "sprinting"
        XCTAssertThrowsError(try bad.validate())
        bad = event(); bad.startUnixSeconds = 1000; bad.endUnixSeconds = 2000
        XCTAssertThrowsError(try bad.validate(), "events before 2000 are refused by the server")
        bad = event(); bad.durationMinutes = 0
        XCTAssertThrowsError(try bad.validate())
        let store = try ManualEventStore(path: ":memory:")
        var huge = event(); huge.note = String(repeating: "\u{1}", count: 2000)
        XCTAssertNoThrow(try huge.validate())
        // The worst case the field limits allow still fits the server's 16 KiB cap once JSON-escaped.
        let saved = try store.save(huge, owner: ownerA)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertLessThanOrEqual(try encoder.encode(saved).count, ManualEventStore.maxRevisionBytes)
        var kind = event(); kind.activityKind = "walking"
        XCTAssertNoThrow(try store.save(kind, owner: ownerA))
    }

    @MainActor
    func testSavingWhatIsAlreadyCurrentAddsNoRevision() throws {
        let store = try ManualEventStore(path: ":memory:")
        let id = CloudPushIdentity(ownerId: ownerA, sourceId: UUID().uuidString, tokenId: UUID().uuidString, uploadToken: "fixture")
        let center = ManualEventCenter(store: store, automaticallySync: false, identity: { id }, endpoint: { nil })
        center.bindAccount()
        var entry = event(); entry.note = ""
        XCTAssertTrue(center.save(entry, for: ownerA))
        let saved = try XCTUnwrap(center.events.first)
        XCTAssertNil(saved.note, "an empty note is no note")
        XCTAssertTrue(center.save(saved, for: ownerA))
        XCTAssertEqual(try store.history(owner: ownerA).filter { $0.entry.id == entry.id }.count, 1)
    }

    func testWindowEndingNowCoversTheJustFinishedPresetAndMovesAsAUnit() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        var window = ManualEventWindow(endingAt: now, durationMinutes: 15)
        XCTAssertEqual(window.end, now); XCTAssertEqual(window.durationMinutes, 15)
        window.shift(minutes: -60)
        XCTAssertEqual(window.end, now.addingTimeInterval(-3600)); XCTAssertEqual(window.durationMinutes, 15)
    }

    func testRefusalStateSurvivesReopenAndAServerCopyClearsIt() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("event-test-\(UUID()).sqlite").path
        let store = try ManualEventStore(path: path)
        let revision = try store.save(event(), owner: ownerA)
        try store.markRejected(owner: ownerA, reasons: [revision.revisionId: "invalid_time"])
        let reopened = try ManualEventStore(path: path)
        XCTAssertTrue(try reopened.pending(owner: ownerA).isEmpty)
        XCTAssertEqual(try reopened.rejected(owner: ownerA)[revision.entry.id], "invalid_time")
        try reopened.insert(revision, owner: ownerA, synced: true)
        XCTAssertTrue(try reopened.rejected(owner: ownerA).isEmpty)
        XCTAssertTrue(try reopened.rejected(owner: ownerB).isEmpty)
    }

    func testCatalogTrimPreservesATypeAlreadyRestoredOnAnotherPhone() throws {
        let store = try ManualEventStore(path: ":memory:")
        let old = ManualEventEntry.retiredDefaultTypes[0]
        try store.insert(ManualEventRevision(revisionId: old.id, updatedAtMs: 1, entry: old), owner: ownerA, synced: true)
        var archived = old; archived.archived = true; archived.archivedAt = 100
        try store.insert(ManualEventRevision(revisionId: UUID(), updatedAtMs: 100000, entry: archived), owner: ownerA, synced: true)
        try store.insert(ManualEventRevision(revisionId: UUID(), updatedAtMs: 200000, entry: old), owner: ownerA, synced: true)
        try store.retireLegacyDefaults(owner: ownerA)
        XCTAssertEqual(try store.latest(owner: ownerA).first?.archived, false)
        XCTAssertTrue(try store.pending(owner: ownerA).isEmpty)
    }
}
