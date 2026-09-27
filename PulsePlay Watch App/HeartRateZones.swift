import Foundation
import SwiftUI

struct PreferredHeartRateZone: Equatable, Identifiable {
    let id: Int
    let minimumBPM: Double?
    let maximumBPM: Double?

    var displayName: String {
        "Zone \(id + 1)"
    }

    func contains(_ beatsPerMinute: Double) -> Bool {
        if let minimumBPM, beatsPerMinute < minimumBPM {
            return false
        }
        if let maximumBPM, beatsPerMinute >= maximumBPM {
            return false
        }
        return true
    }
}

struct HeartRateZoneSettingsView: View {
    let workoutManager: HeartRateWorkoutManager
    let spotifyConnectivity = WatchSpotifyConnectivity.shared

    var body: some View {
        List {
            if workoutManager.preferredHeartRateZones.isEmpty {
                Section {
                    Text(workoutManager.zoneConfigurationStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Try Again") {
                        Task {
                            await workoutManager.loadPreferredHeartRateZones()
                        }
                    }
                }
            } else {
                Section {
                    ForEach(workoutManager.preferredHeartRateZones) { zone in
                        HeartRateZonePlaylistRow(
                            zone: zone,
                            playlistName: spotifyConnectivity.playlistName(for: zone.id)
                        )
                    }
                } footer: {
                    Text("Choose Spotify playlists in PulsePlay on iPhone. Zone boundaries come from HealthKit.")
                }
            }

            Section("Spotify") {
                Text(spotifyConnectivity.playbackStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Heart Zones")
    }
}

private struct HeartRateZonePlaylistRow: View {
    let zone: PreferredHeartRateZone
    let playlistName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(zone.displayName)
                .font(.headline)

            HeartRateZoneRangeView(
                minimumBPM: zone.minimumBPM,
                maximumBPM: zone.maximumBPM
            )

            Text(playlistName.isEmpty ? "Choose on iPhone" : playlistName)
                .font(.caption)
                .foregroundStyle(playlistName.isEmpty ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}

private struct HeartRateZoneRangeView: View {
    let minimumBPM: Double?
    let maximumBPM: Double?

    var body: some View {
        if let minimumBPM, let maximumBPM {
            Text(
                "\(minimumBPM, format: .number.precision(.fractionLength(0)))–\(maximumBPM, format: .number.precision(.fractionLength(0))) BPM"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let maximumBPM {
            Text(
                "Below \(maximumBPM, format: .number.precision(.fractionLength(0))) BPM"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let minimumBPM {
            Text(
                "\(minimumBPM, format: .number.precision(.fractionLength(0)))+ BPM"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
