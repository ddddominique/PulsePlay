import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import UIKit
import WatchConnectivity

nonisolated struct SpotifyPlaylist: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let uri: String
}

nonisolated struct SpotifyPlaylistAssignment: Codable, Equatable, Sendable {
    let zoneID: Int
    let playlist: SpotifyPlaylist
}

nonisolated struct SyncedHeartRateZone: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let minimumBPM: Double?
    let maximumBPM: Double?

    var displayName: String {
        "Zone \(id + 1)"
    }

    var rangeDescription: String {
        switch (minimumBPM, maximumBPM) {
        case let (minimum?, maximum?):
            return "\(minimum.formatted(.number.precision(.fractionLength(0))))–\(maximum.formatted(.number.precision(.fractionLength(0)))) BPM"
        case let (nil, maximum?):
            return "Below \(maximum.formatted(.number.precision(.fractionLength(0)))) BPM"
        case let (minimum?, nil):
            return "\(minimum.formatted(.number.precision(.fractionLength(0))))+ BPM"
        case (nil, nil):
            return "Range unavailable"
        }
    }
}

private nonisolated struct SpotifyTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
}

private nonisolated struct SpotifyTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private nonisolated struct SpotifyPlaylistPage: Decodable, Sendable {
    let items: [SpotifyPlaylist]
    let next: URL?
}

private nonisolated struct SpotifyDevicesResponse: Decodable, Sendable {
    let devices: [SpotifyDevice]
}

private nonisolated struct SpotifyDevice: Decodable, Sendable {
    let id: String?
    let isActive: Bool
    let isRestricted: Bool
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case isActive = "is_active"
        case isRestricted = "is_restricted"
        case name
    }
}

enum SpotifyError: LocalizedError {
    case configuration(String)
    case authorization(String)
    case invalidResponse
    case api(statusCode: Int, message: String)
    case noActiveDevice
    case signedOut

    var errorDescription: String? {
        switch self {
        case .configuration(let message), .authorization(let message):
            return message
        case .invalidResponse:
            return "Spotify returned an invalid response."
        case .api(let statusCode, let message):
            return "Spotify error \(statusCode): \(message)"
        case .noActiveDevice:
            return "No active Spotify device. Start playing Spotify on a phone, computer, or speaker, then try again."
        case .signedOut:
            return "Sign in to Spotify on iPhone first."
        }
    }
}

@MainActor
final class SpotifyWebAPI {
    private static let redirectURI = "pulseplay-spotify-login://callback"
    private static let keychainService = "com.dominiquewang.PulsePlay.spotify"
    private static let tokenAccount = "oauth-tokens"

    private var tokens: SpotifyTokens?
    private var authenticationSession: ASWebAuthenticationSession?
    private let presentationProvider = SpotifyWebAuthenticationPresentationProvider()

    var isSignedIn: Bool {
        tokens != nil
    }

    var isConfigured: Bool {
        (try? configuredClientID()) != nil
    }

    init() {
        tokens = Self.loadTokens()
    }

    func signIn() async throws {
        let clientID = try configuredClientID()
        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafeString(length: 32)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(
                name: "scope",
                value: "playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state"
            )
        ]

        guard let authorizationURL = components?.url else {
            throw SpotifyError.configuration("Could not create the Spotify sign-in URL.")
        }

        let callbackURL = try await authenticate(at: authorizationURL)
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw SpotifyError.authorization("Spotify returned an invalid callback.")
        }
        let values = Dictionary(
            uniqueKeysWithValues: callbackComponents.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        )
        guard values["state"] == state else {
            throw SpotifyError.authorization("Spotify sign-in state did not match. Please try again.")
        }
        if let error = values["error"] {
            throw SpotifyError.authorization("Spotify sign-in failed: \(error)")
        }
        guard let code = values["code"], !code.isEmpty else {
            throw SpotifyError.authorization("Spotify did not return an authorization code.")
        }

        let response: SpotifyTokenResponse = try await tokenRequest(parameters: [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier
        ])
        tokens = SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expirationDate: Date().addingTimeInterval(response.expiresIn)
        )
        try saveTokens()
    }

    func signOut() {
        tokens = nil
        Self.deleteTokens()
    }

    func playlists() async throws -> [SpotifyPlaylist] {
        var allPlaylists: [SpotifyPlaylist] = []
        var nextURL: URL? = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50")

        while let url = nextURL {
            let page: SpotifyPlaylistPage = try await authorizedJSON(url: url)
            allPlaylists.append(contentsOf: page.items)
            nextURL = page.next
        }
        return allPlaylists
    }

    func startPlayback(playlist: SpotifyPlaylist) async throws -> String {
        let devices: SpotifyDevicesResponse = try await authorizedJSON(
            url: URL(string: "https://api.spotify.com/v1/me/player/devices")!
        )
        guard let device = devices.devices.first(where: { $0.isActive && !$0.isRestricted }),
              let deviceID = device.id else {
            throw SpotifyError.noActiveDevice
        }

        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        let body = try JSONSerialization.data(withJSONObject: ["context_uri": playlist.uri])
        _ = try await authorizedData(url: components.url!, method: "PUT", body: body)
        return "Playing \(playlist.name) on \(device.name)."
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "pulseplay-spotify-login"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.authenticationSession = nil
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: SpotifyError.authorization("Spotify sign-in was cancelled."))
                    }
                }
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: SpotifyError.authorization("Could not start Spotify sign-in."))
                return
            }
        }
    }

    private func configuredClientID() throws -> String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
              !clientID.isEmpty,
              clientID != "YOUR_SPOTIFY_CLIENT_ID" else {
            throw SpotifyError.configuration(
                "Add your Spotify Client ID to the PulsePlay target’s SpotifyClientID Info.plist value."
            )
        }
        return clientID
    }

    private func validAccessToken() async throws -> String {
        guard let current = tokens else {
            throw SpotifyError.signedOut
        }
        if current.expirationDate.timeIntervalSinceNow > 60 {
            return current.accessToken
        }
        guard let refreshToken = current.refreshToken else {
            signOut()
            throw SpotifyError.authorization("Your Spotify session expired. Sign in again.")
        }

        let response: SpotifyTokenResponse = try await tokenRequest(parameters: [
            "client_id": try configuredClientID(),
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        tokens = SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expirationDate: Date().addingTimeInterval(response.expiresIn)
        )
        try saveTokens()
        return response.accessToken
    }

    private func tokenRequest<Response: Decodable & Sendable>(
        parameters: [String: String]
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func authorizedJSON<Response: Decodable & Sendable>(url: URL) async throws -> Response {
        let data = try await authorizedData(url: url)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func authorizedData(url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else {
            throw SpotifyError.invalidResponse
        }
        guard (200...299).contains(response.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorObject = json?["error"] as? [String: Any]
            let message = errorObject?["message"] as? String
                ?? json?["error_description"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw SpotifyError.api(statusCode: response.statusCode, message: message)
        }
    }

    private func saveTokens() throws {
        guard let tokens else {
            return
        }
        let data = try JSONEncoder().encode(tokens)
        Self.deleteTokens()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SpotifyError.authorization("Could not securely save the Spotify session.")
        }
    }

    private static func loadTokens() -> SpotifyTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SpotifyTokens.self, from: data)
    }

    private static func deleteTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func randomURLSafeString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

private final class SpotifyWebAuthenticationPresentationProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else {
            preconditionFailure("Spotify sign-in requires an active window.")
        }
        return window
    }
}

@MainActor
@Observable
final class PhoneAppModel: NSObject {
    static let shared = PhoneAppModel()

    private static let assignmentsKey = "spotifyPlaylistAssignments"
    private let spotify = SpotifyWebAPI()
    private let session = WCSession.default
    private var handledEventIDs = Set<String>()
    private var lastPlaybackZoneID: Int?

    private(set) var playlists: [SpotifyPlaylist] = []
    private(set) var zones: [SyncedHeartRateZone] = []
    private(set) var assignments: [Int: SpotifyPlaylistAssignment] = PhoneAppModel.loadAssignments()
    private(set) var isBusy = false
    private(set) var watchIsReachable = false
    var statusText = "Open companion mode on Apple Watch to sync heart-rate zones."

    var alertMessage: String?

    var isSignedIn: Bool {
        spotify.isSignedIn
    }

    var isSpotifyConfigured: Bool {
        spotify.isConfigured
    }

    override private init() {
        super.init()
        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity is unavailable on this iPhone."
            return
        }
        session.delegate = self
        session.activate()
        applyWatchContext(session.receivedApplicationContext)
    }

    func signIn() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await spotify.signIn()
            statusText = "Signed in to Spotify."
            await refreshPlaylists()
        } catch {
            statusText = error.localizedDescription
            alertMessage = error.localizedDescription
        }
    }

    func dismissAlert() {
        alertMessage = nil
    }

    func signOut() {
        spotify.signOut()
        playlists = []
        statusText = "Signed out of Spotify."
    }

    func refreshPlaylists() async {
        guard isSignedIn else {
            statusText = "Sign in to Spotify to load playlists."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            playlists = try await spotify.playlists().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            statusText = playlists.isEmpty
                ? "No Spotify playlists are available for this account."
                : "Loaded \(playlists.count) Spotify playlists."
        } catch {
            statusText = error.localizedDescription
        }
    }

    func assignment(for zoneID: Int) -> SpotifyPlaylistAssignment? {
        assignments[zoneID]
    }

    func assign(_ playlist: SpotifyPlaylist, to zoneID: Int) {
        assignments[zoneID] = SpotifyPlaylistAssignment(zoneID: zoneID, playlist: playlist)
        saveAssignments()
        syncAssignmentsToWatch()
        statusText = "Assigned \(playlist.name) to Zone \(zoneID + 1)."
    }

    func removeAssignment(for zoneID: Int) {
        assignments.removeValue(forKey: zoneID)
        saveAssignments()
        syncAssignmentsToWatch()
        statusText = "Removed the playlist from Zone \(zoneID + 1)."
    }

    private func handleZoneChange(zoneID: Int, eventID: String) async -> String {
        guard handledEventIDs.insert(eventID).inserted else {
            return statusText
        }
        guard zoneID != lastPlaybackZoneID else {
            return "Zone \(zoneID + 1) is already active; no new playback command was sent."
        }

        lastPlaybackZoneID = zoneID
        guard let assignment = assignments[zoneID] else {
            statusText = "Zone \(zoneID + 1) has no Spotify playlist assigned."
            syncStatusToWatch()
            return statusText
        }
        guard isSignedIn else {
            statusText = "Zone \(zoneID + 1) selected \(assignment.playlist.name), but Spotify is signed out."
            syncStatusToWatch()
            return statusText
        }

        do {
            statusText = try await spotify.startPlayback(playlist: assignment.playlist)
        } catch {
            statusText = error.localizedDescription
        }
        syncStatusToWatch()
        return statusText
    }

    private func applyWatchContext(_ context: [String: Any]) {
        guard let zoneData = context["heartRateZones"] as? Data,
              let decoded = try? JSONDecoder().decode([SyncedHeartRateZone].self, from: zoneData) else {
            return
        }
        zones = decoded.sorted { $0.id < $1.id }
        statusText = zones.isEmpty
            ? "The watch could not provide a preferred heart-rate zone configuration."
            : "Heart-rate zones synced from Apple Watch."
    }

    private func syncAssignmentsToWatch() {
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(Array(assignments.values)) else {
            return
        }
        do {
            try session.updateApplicationContext([
                "playlistAssignments": data,
                "playbackStatus": statusText
            ])
        } catch {
            statusText = "Could not sync playlists to Apple Watch: \(error.localizedDescription)"
        }
    }

    private func syncStatusToWatch() {
        guard session.activationState == .activated,
              let data = try? JSONEncoder().encode(Array(assignments.values)) else {
            return
        }
        try? session.updateApplicationContext([
            "playlistAssignments": data,
            "playbackStatus": statusText
        ])
    }

    private func saveAssignments() {
        guard let data = try? JSONEncoder().encode(assignments) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.assignmentsKey)
    }

    private static func loadAssignments() -> [Int: SpotifyPlaylistAssignment] {
        guard let data = UserDefaults.standard.data(forKey: assignmentsKey),
              let assignments = try? JSONDecoder().decode(
                [Int: SpotifyPlaylistAssignment].self,
                from: data
              ) else {
            return [:]
        }
        return assignments
    }
}

extension PhoneAppModel: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            watchIsReachable = session.isReachable
            if let error {
                statusText = "Apple Watch connection failed: \(error.localizedDescription)"
            } else {
                applyWatchContext(session.receivedApplicationContext)
                syncAssignmentsToWatch()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.watchIsReachable = session.isReachable
            if session.isReachable {
                self?.syncAssignmentsToWatch()
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor [weak self] in
            self?.applyWatchContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let zoneID = userInfo["zoneID"] as? Int,
              let eventID = userInfo["eventID"] as? String else {
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.handleZoneChange(zoneID: zoneID, eventID: eventID)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let zoneID = message["zoneID"] as? Int,
              let eventID = message["eventID"] as? String else {
            replyHandler(["status": "Invalid zone message."])
            return
        }
        Task { @MainActor [weak self] in
            let status = await self?.handleZoneChange(zoneID: zoneID, eventID: eventID)
                ?? "PulsePlay is unavailable."
            replyHandler(["status": status])
        }
    }
}
