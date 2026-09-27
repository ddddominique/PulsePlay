import SwiftUI

struct ContentView: View {
    @State private var model = PhoneAppModel.shared

    var body: some View {
        NavigationStack {
            List {
                spotifySection
                watchSection
                zoneSection
            }
            .navigationTitle("PulsePlay")
            .task {
                if model.isSignedIn && model.playlists.isEmpty {
                    await model.refreshPlaylists()
                }
            }
            .refreshable {
                await model.refreshPlaylists()
            }
            .alert(
                "Spotify Sign-In",
                isPresented: Binding(
                    get: { model.alertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.dismissAlert()
                        }
                    }
                )
            ) {
                Button("OK") {
                    model.dismissAlert()
                }
            } message: {
                Text(model.alertMessage ?? "Spotify sign-in failed.")
            }
        }
    }

    private var spotifySection: some View {
        Section("Spotify") {
            LabeledContent("Account") {
                Text(model.isSignedIn ? "Signed in" : "Signed out")
                    .foregroundStyle(model.isSignedIn ? .green : .secondary)
            }

            if model.isSignedIn {
                Button("Refresh Playlists") {
                    Task {
                        await model.refreshPlaylists()
                    }
                }
                Button("Sign Out", role: .destructive) {
                    model.signOut()
                }
            } else {
                if !model.isSpotifyConfigured {
                    Label(
                        "Spotify Client ID is not configured.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                Button("Sign in with Spotify") {
                    Task {
                        await model.signIn()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if model.isBusy {
                ProgressView()
            }

            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var watchSection: some View {
        Section("Apple Watch") {
            LabeledContent("Connection") {
                Text(model.watchIsReachable ? "Reachable" : "Background sync")
                    .foregroundStyle(model.watchIsReachable ? .green : .secondary)
            }
            Text("PulsePlay reads heart rate beside Apple Workout. It does not start a second workout session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var zoneSection: some View {
        Section {
            if model.zones.isEmpty {
                ContentUnavailableView(
                    "No Zones from Watch",
                    systemImage: "applewatch",
                    description: Text(
                        "Open Use with Apple Workout on your watch to sync HealthKit’s preferred zones."
                    )
                )
            } else {
                ForEach(model.zones) { zone in
                    NavigationLink {
                        PlaylistPickerView(zone: zone, model: model)
                    } label: {
                        ZoneAssignmentLabel(
                            zone: zone,
                            assignment: model.assignment(for: zone.id)
                        )
                    }
                }
            }
        } header: {
            Text("Zone Playlists")
        } footer: {
            Text("Zone boundaries are read-only and come from HealthKit on Apple Watch.")
        }
    }
}

private struct ZoneAssignmentLabel: View {
    let zone: SyncedHeartRateZone
    let assignment: SpotifyPlaylistAssignment?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(zone.displayName)
                .font(.headline)
            Text(zone.rangeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(assignment?.playlist.name ?? "No playlist assigned")
                .foregroundStyle(assignment == nil ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }
}

private struct PlaylistPickerView: View {
    let zone: SyncedHeartRateZone
    let model: PhoneAppModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredPlaylists: [SpotifyPlaylist] {
        guard !searchText.isEmpty else {
            return model.playlists
        }
        return model.playlists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(zone.displayName)
                        .font(.headline)
                    Text(zone.rangeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Spotify Playlists") {
                if !model.isSignedIn {
                    Text("Sign in to Spotify on the main screen first.")
                        .foregroundStyle(.secondary)
                } else if model.playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "music.note.list",
                        description: Text("Refresh playlists on the main screen.")
                    )
                } else {
                    ForEach(filteredPlaylists) { playlist in
                        Button {
                            model.assign(playlist, to: zone.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                if model.assignment(for: zone.id)?.playlist.id == playlist.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            if model.assignment(for: zone.id) != nil {
                Section {
                    Button("Remove Assignment", role: .destructive) {
                        model.removeAssignment(for: zone.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Choose Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search playlists")
    }
}

#Preview {
    ContentView()
}
