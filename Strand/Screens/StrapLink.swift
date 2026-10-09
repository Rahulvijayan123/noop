import Combine
import Foundation

/// The strap-link values the Pair & connect page is built from, copied out of `LiveState` and `AppModel`.
///
/// Both of those publish every second a heart-rate sample arrives, and a view that observes either one runs its
/// whole body at that rate whether or not anything it shows has changed. This is the short list the page
/// actually reads. Holding it as one value that is only replaced when it differs is what lets the page sit
/// still while a strap streams.
struct StrapLinkInputs: Equatable {
    var connected = false
    var bonded = false
    var encryptedBond = false
    var restarting = false
    var pairingHint: String?
    var hasReconnectGuide = false
    /// The "Bluetooth is off / not allowed" message, when that is what is wrong.
    var radioProblem: String?
    var batteryPct: Double?
    var charging: Bool?
    var firmware: String?
    /// A strap is registered or was connected before, even if nothing in this session has bonded yet.
    var knownStrap = false
    var isWhoop4 = false
}

extension StrapConnectionStatus {
    init(link: StrapLinkInputs, searching: Bool = false, searchIsSlow: Bool = false, userDisconnected: Bool = false) {
        self.init(connected: link.connected,
                  bonded: link.bonded,
                  encryptedBond: link.encryptedBond,
                  restarting: link.restarting,
                  searching: searching,
                  searchIsSlow: searchIsSlow,
                  knownStrap: link.knownStrap,
                  pairingHint: link.pairingHint,
                  hasReconnectGuide: link.hasReconnectGuide,
                  radioProblem: link.radioProblem,
                  isWhoop4: link.isWhoop4,
                  batteryPct: link.batteryPct,
                  userDisconnected: userDisconnected)
    }
}

/// Publishes `StrapLinkInputs`, and only when they differ from the last ones published.
///
/// `triggers` say when to look again; they are hopped to the next main-queue turn first, because a `@Published`
/// property announces its change before it holds the new value. Several properties usually move together (a
/// connect flips three flags), and every one of those looks at the final state, so a burst costs one publish.
@MainActor
final class StrapLinkObserver: ObservableObject {
    @Published private(set) var inputs: StrapLinkInputs

    private let read: () -> StrapLinkInputs
    private var subscription: AnyCancellable?

    init(read: @escaping () -> StrapLinkInputs, triggers: [AnyPublisher<Void, Never>]) {
        self.read = read
        self.inputs = read()
        subscription = Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    /// Look at the link now. For changes the triggers cannot see, such as the strap model being picked.
    func refresh() {
        let latest = read()
        if latest != inputs { inputs = latest }
    }
}

extension StrapLinkObserver {
    /// An observer wired to the live link and to the registry that decides whether a strap is "known".
    static func bound(to live: LiveState, model: AppModel) -> StrapLinkObserver {
        func ping<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
            publisher.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        let registeredDevices = model.$deviceRegistry
            .compactMap { $0 }
            .map { $0.$devices }
            .switchToLatest()
        return StrapLinkObserver(
            read: { [weak live, weak model] in
                guard let live, let model else { return StrapLinkInputs() }
                return StrapLinkInputs.read(live: live, model: model)
            },
            triggers: [
                ping(live.$connected), ping(live.$bonded), ping(live.$encryptedBond),
                ping(live.$rebootInProgress), ping(live.$pairingHint), ping(live.$reconnectGuide),
                ping(live.$lastSyncError), ping(live.$batteryPct), ping(live.$charging),
                ping(live.$strapFirmware), ping(model.$deviceRegistry), ping(registeredDevices),
            ])
    }
}

extension StrapLinkInputs {
    /// Reads the live link. The radio message is the one `BLEManager` sets for Bluetooth off / not allowed /
    /// unsupported; no other sync error mentions Bluetooth.
    @MainActor
    static func read(live: LiveState, model: AppModel) -> StrapLinkInputs {
        let registeredWhoop = model.deviceRegistry?.devices.contains {
            SourceCoordinator.isWhoop($0) && $0.status != .archived
        } ?? false
        let rememberedStrap = UserDefaults.standard.string(forKey: BLEManager.lastConnectedPeripheralKey) != nil
        var knownStrap = registeredWhoop || rememberedStrap
        #if DEBUG
        if let forced = StrapDemoSeed.knownStrapOverride { knownStrap = forced }
        #endif
        return StrapLinkInputs(
            connected: live.connected,
            bonded: live.bonded,
            encryptedBond: live.encryptedBond,
            restarting: live.rebootInProgress,
            pairingHint: live.pairingHint,
            hasReconnectGuide: live.reconnectGuide != nil,
            radioProblem: live.lastSyncError.flatMap { $0.contains("Bluetooth") ? $0 : nil },
            batteryPct: live.batteryPct,
            charging: live.isChargingNow,
            firmware: live.strapFirmware,
            knownStrap: knownStrap,
            isWhoop4: live.connected && model.ble.isWhoop4)
    }
}
