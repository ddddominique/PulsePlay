import Foundation
import Observation
import WatchConnectivity

struct WatchSpotifyPlaylist: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let uri: String
}

struct WatchSpotifyPlaylistAssignment: Codable, Equatable, Sendable {
    let zoneID: Int
    let playlist: WatchSpotifyPlaylist
}

private struct WatchSyncedHeartRateZone: Codable, Sendable {
    let id: Int
    let minimumBPM: Double?
    let maximumBPM: Double?
}

@MainActor
@Observable
final class WatchSpotifyConnectivity: NSObject {
    static let shared = WatchSpotifyConnectivity()

    private let session = WCSession.default
    private(set) var assignments: [Int: WatchSpotifyPlaylistAssignment] = [:]
    private(set) var playbackStatus = "Open PulsePlay on iPhone to connect Spotify."
    private(set) var isReachable = false
    private var lastSentZoneID: Int?
    private var pendingZoneConfigurationData: Data?

    override private init() {
        super.init()
        guard WCSession.isSupported() else {
            playbackStatus = "WatchConnectivity is unavailable."
            return
        }
        session.delegate = self
        session.activate()
        applyPhoneContext(session.receivedApplicationContext)
    }

    func playlistName(for zoneID: Int) -> String {
        assignments[zoneID]?.playlist.name ?? ""
    }

    func resetZoneDelivery() {
        lastSentZoneID = nil
    }

    func sendZoneConfiguration(_ zones: [PreferredHeartRateZone]) {
        let synced = zones.map {
            WatchSyncedHeartRateZone(
                id: $0.id,
                minimumBPM: $0.minimumBPM,
                maximumBPM: $0.maximumBPM
            )
        }
        guard let data = try? JSONEncoder().encode(synced) else {
            return
        }
        pendingZoneConfigurationData = data
        syncZoneConfiguration()
    }

    private func syncZoneConfiguration() {
        guard session.activationState == .activated,
              let pendingZoneConfigurationData else {
            return
        }
        do {
            try session.updateApplicationContext([
                "heartRateZones": pendingZoneConfigurationData
            ])
        } catch {
            playbackStatus = "Could not sync zones to iPhone: \(error.localizedDescription)"
        }
    }

    func sendZoneChange(_ zoneID: Int) {
        guard zoneID != lastSentZoneID else {
            return
        }
        lastSentZoneID = zoneID

        let payload: [String: Any] = [
            "zoneID": zoneID,
            "eventID": UUID().uuidString
        ]
        playbackStatus = assignments[zoneID] == nil
            ? "No Spotify playlist assigned to Zone \(zoneID + 1)."
            : "Sending Zone \(zoneID + 1) to iPhone…"

        guard session.activationState == .activated else {
            playbackStatus = "Waiting for the iPhone connection."
            return
        }

        if session.isReachable {
            session.sendMessage(payload) { [weak self] reply in
                guard let status = reply["status"] as? String else {
                    return
                }
                Task { @MainActor in
                    self?.playbackStatus = status
                }
            } errorHandler: { [weak self] _ in
                self?.session.transferUserInfo(payload)
                Task { @MainActor in
                    self?.playbackStatus = "Zone change queued for iPhone."
                }
            }
        } else {
            session.transferUserInfo(payload)
            playbackStatus = "Zone change queued for iPhone."
        }
    }

    private func applyPhoneContext(_ context: [String: Any]) {
        if let data = context["playlistAssignments"] as? Data,
           let values = try? JSONDecoder().decode([WatchSpotifyPlaylistAssignment].self, from: data) {
            assignments = Dictionary(uniqueKeysWithValues: values.map { ($0.zoneID, $0) })
        }
        if let status = context["playbackStatus"] as? String {
            playbackStatus = status
        }
    }
}

extension WatchSpotifyConnectivity: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            isReachable = session.isReachable
            applyPhoneContext(session.receivedApplicationContext)
            syncZoneConfiguration()
            if let error {
                playbackStatus = "iPhone connection failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isReachable = session.isReachable
            self?.syncZoneConfiguration()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.applyPhoneContext(applicationContext)
        }
    }
}
