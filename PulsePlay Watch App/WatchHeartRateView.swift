//
//  WatchHeartRateView.swift
//  PulsePlay Watch App
//

import HealthKit
import SwiftUI

struct WatchHeartRateView: View {
    @State private var workoutManager = HeartRateWorkoutManager()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("PulsePlay")
                        .font(.headline)

                    HeartRateModeSelector(
                        mode: workoutManager.mode,
                        selectMode: { workoutManager.mode = $0 }
                    )

                    if workoutManager.mode == .pulsePlay {
                        PulsePlayWorkoutView(workoutManager: workoutManager)
                    } else {
                        AppleWorkoutHeartRateView(workoutManager: workoutManager)
                    }
                }
                .padding()
            }
        }
        .task {
            await workoutManager.prepareCurrentMode()
        }
        .onChange(of: workoutManager.mode) { _, mode in
            Task {
                await workoutManager.activate(mode)
            }
        }
    }
}

private struct HeartRateModeSelector: View {
    let mode: HeartRateMode
    let selectMode: (HeartRateMode) -> Void

    var body: some View {
        HStack {
            Button {
                selectMode(.pulsePlay)
            } label: {
                Image(systemName: "figure.run")
            }
            .tint(mode == .pulsePlay ? .green : .gray)
            .accessibilityLabel("PulsePlay Workout")
            .accessibilityAddTraits(mode == .pulsePlay ? .isSelected : [])

            Button {
                selectMode(.appleWorkout)
            } label: {
                Image(systemName: "applewatch")
            }
            .tint(mode == .appleWorkout ? .green : .gray)
            .accessibilityLabel("Use with Apple Workout")
            .accessibilityAddTraits(mode == .appleWorkout ? .isSelected : [])
        }
        .buttonStyle(.bordered)
    }
}

private struct PulsePlayWorkoutView: View {
    let workoutManager: HeartRateWorkoutManager

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(workoutManager.heartRateText)
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Text("BPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Text(workoutManager.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await workoutManager.toggleWorkout()
                }
            } label: {
                Label(
                    workoutManager.isRunning ? "End" : "Start",
                    systemImage: workoutManager.isRunning ? "stop.fill" : "heart.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(workoutManager.isRunning ? .red : .green)
        }
    }
}

private struct AppleWorkoutHeartRateView: View {
    let workoutManager: HeartRateWorkoutManager

    var body: some View {
        VStack(spacing: 8) {
            Text("Use with Apple Workout")
                .font(.caption)
                .foregroundStyle(.secondary)

            CompanionReadingStatus(
                reading: workoutManager.appleWorkoutReadings.first,
                zone: workoutManager.currentZone,
                pendingZone: workoutManager.pendingZone,
                playlistName: workoutManager.currentPlaylistName,
                statusText: workoutManager.statusText,
                playbackStatus: workoutManager.spotifyConnectivity.playbackStatus
            )

            Button {
                Task {
                    await workoutManager.toggleAppleWorkoutMonitoring()
                }
            } label: {
                Label(
                    workoutManager.isMonitoringAppleWorkout
                        ? "Stop PulsePlay"
                        : "Start PulsePlay",
                    systemImage: workoutManager.isMonitoringAppleWorkout
                        ? "stop.fill"
                        : "waveform.path.ecg"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(workoutManager.isMonitoringAppleWorkout ? .red : .green)

            NavigationLink {
                HeartRateZoneSettingsView(workoutManager: workoutManager)
            } label: {
                Label("Configure Zones", systemImage: "slider.horizontal.3")
            }
        }
    }
}

private struct CompanionReadingStatus: View {
    let reading: HeartRateReading?
    let zone: PreferredHeartRateZone?
    let pendingZone: PreferredHeartRateZone?
    let playlistName: String
    let statusText: String
    let playbackStatus: String

    @State private var now = Date()

    var body: some View {
        VStack(spacing: 4) {
            if let reading,
               reading.age(at: now) <= HeartRateReading.recentSampleInterval {
                CompanionHeartRateSummary(
                    reading: reading,
                    zone: zone,
                    pendingZone: pendingZone,
                    playlistName: playlistName,
                    now: now
                )
            } else {
                ContentUnavailableView {
                    Label("No Recent Sample", systemImage: "heart.slash")
                } description: {
                    Text(statusText)
                }
            }

            Text(playbackStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }
}

private struct CompanionHeartRateSummary: View {
    let reading: HeartRateReading
    let zone: PreferredHeartRateZone?
    let pendingZone: PreferredHeartRateZone?
    let playlistName: String
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            Text("\(reading.beatsPerMinute, format: .number.precision(.fractionLength(0))) BPM")
                .font(.title2)
                .monospacedDigit()

            if let zone {
                Text(zone.displayName)
                    .font(.headline)
                Text(playlistName.isEmpty ? "No playlist assigned" : playlistName)
                    .font(.body)
                    .foregroundStyle(playlistName.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.center)
            }

            if let pendingZone {
                Text("Holding for \(pendingZone.displayName)…")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(reading.date, format: .dateTime.hour().minute().second())
                .font(.caption2)

            Text("\(reading.age(at: now)) seconds old")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

enum HeartRateMode: Hashable {
    case pulsePlay
    case appleWorkout
}

struct HeartRateReading: Identifiable, Equatable {
    static let recentSampleInterval = 30

    let id: UUID
    let beatsPerMinute: Double
    let date: Date

    func age(at date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(self.date)))
    }
}

@MainActor
@Observable
final class HeartRateWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    let spotifyConnectivity = WatchSpotifyConnectivity.shared
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var pendingZoneID: Int?
    private var pendingZoneStartDate: Date?

    var mode = HeartRateMode.pulsePlay
    var heartRate: Double?
    var isRunning = false
    var statusText = "Requesting Health access..."
    var zoneConfigurationStatus = "Loading preferred heart-rate zones…"
    private(set) var preferredHeartRateZones: [PreferredHeartRateZone] = []
    private(set) var isMonitoringAppleWorkout = false
    private(set) var appleWorkoutReadings: [HeartRateReading] = []
    private(set) var currentZoneID: Int?

    var currentZone: PreferredHeartRateZone? {
        preferredHeartRateZones.first { $0.id == currentZoneID }
    }

    var pendingZone: PreferredHeartRateZone? {
        preferredHeartRateZones.first { $0.id == pendingZoneID }
    }

    var currentPlaylistName: String {
        guard let currentZoneID else {
            return ""
        }
        return spotifyConnectivity.playlistName(for: currentZoneID)
    }

    var heartRateText: String {
        guard let heartRate else {
            return "--"
        }

        return heartRate.formatted(.number.precision(.fractionLength(0)))
    }

    func prepareCurrentMode() async {
        await activate(mode)
    }

    func loadPreferredHeartRateZones() async {
        guard HKHealthStore.isHealthDataAvailable(), let heartRateType else {
            preferredHeartRateZones = []
            zoneConfigurationStatus = "Health data is unavailable on this device."
            return
        }

        guard #available(watchOS 27.0, *) else {
            preferredHeartRateZones = []
            zoneConfigurationStatus = "Preferred HealthKit heart-rate zones require watchOS 27."
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: [heartRateType])
            guard let configuration = try await healthStore.preferredWorkoutZoneConfiguration(
                for: heartRateType
            ) else {
                preferredHeartRateZones = []
                zoneConfigurationStatus = "No preferred heart-rate zone configuration is available. Configure heart-rate zones in Apple’s Health settings."
                return
            }

            let unit = HKUnit.count().unitDivided(by: .minute())
            preferredHeartRateZones = configuration.zones.map { zone in
                PreferredHeartRateZone(
                    id: zone.index,
                    minimumBPM: zone.minimum?.doubleValue(for: unit),
                    maximumBPM: zone.maximum?.doubleValue(for: unit)
                )
            }
            zoneConfigurationStatus = "Using the preferred zones from HealthKit."
            refreshCurrentZone()
            spotifyConnectivity.sendZoneConfiguration(preferredHeartRateZones)
        } catch {
            preferredHeartRateZones = []
            zoneConfigurationStatus = "Unable to load preferred heart-rate zones: \(error.localizedDescription)"
        }
    }

    func activate(_ mode: HeartRateMode) async {
        switch mode {
        case .pulsePlay:
            stopHeartRateQuery()
            await requestWorkoutAuthorization()
        case .appleWorkout:
            if isRunning {
                await endWorkout()
            }
            stopHeartRateQuery()
            await loadPreferredHeartRateZones()
            statusText = preferredHeartRateZones.isEmpty
                ? zoneConfigurationStatus
                : "Tap Start to monitor Apple Workout heart rate."
        }
    }

    func toggleWorkout() async {
        guard mode == .pulsePlay else {
            return
        }

        if isRunning {
            await endWorkout()
        } else {
            await startWorkout()
        }
    }

    func toggleAppleWorkoutMonitoring() async {
        guard mode == .appleWorkout else {
            return
        }

        if isMonitoringAppleWorkout {
            stopHeartRateQuery()
            statusText = "Apple Workout monitoring stopped."
        } else {
            await startAppleWorkoutMonitoring()
        }
    }

    private func requestWorkoutAuthorization() async {
        guard let heartRateType = heartRateType else {
            statusText = "Heart rate data is unavailable."
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            statusText = "Health data is unavailable on this device."
            return
        }

        do {
            try await healthStore.requestAuthorization(
                toShare: [HKObjectType.workoutType()],
                read: [heartRateType]
            )
            statusText = "Ready"
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func startAppleWorkoutMonitoring() async {
        stopHeartRateQuery()
        appleWorkoutReadings = []
        currentZoneID = nil
        clearPendingZone()
        spotifyConnectivity.resetZoneDelivery()

        guard HKHealthStore.isHealthDataAvailable() else {
            statusText = "Health data is unavailable on this device."
            return
        }

        guard let heartRateType else {
            statusText = "Heart rate data is unavailable."
            return
        }

        await loadPreferredHeartRateZones()
        guard !preferredHeartRateZones.isEmpty else {
            statusText = zoneConfigurationStatus
            return
        }

        statusText = "Waiting for a recent sample from Apple Workout..."

        let recentStart = Date().addingTimeInterval(-5 * 60)
        let predicate = HKQuery.predicateForSamples(
            withStart: recentStart,
            end: nil,
            options: .strictStartDate
        )
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak manager = self] _, samples, _, _, error in
            Task { @MainActor [manager] in
                manager?.receiveHeartRateSamples(samples, error: error)
            }
        }

        query.updateHandler = { [weak manager = self] _, samples, _, _, error in
            Task { @MainActor [manager] in
                manager?.receiveHeartRateSamples(samples, error: error)
            }
        }

        heartRateQuery = query
        isMonitoringAppleWorkout = true
        healthStore.execute(query)
    }

    private func stopHeartRateQuery() {
        if let heartRateQuery {
            healthStore.stop(heartRateQuery)
            self.heartRateQuery = nil
        }
        isMonitoringAppleWorkout = false
    }

    private func receiveHeartRateSamples(_ samples: [HKSample]?, error: (any Error)?) {
        guard mode == .appleWorkout, isMonitoringAppleWorkout else {
            return
        }

        if let error {
            statusText = error.localizedDescription
            return
        }

        guard let samples else {
            statusText = "No recent heart-rate sample is available."
            return
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let newReadings = samples.compactMap { sample -> HeartRateReading? in
            guard let quantitySample = sample as? HKQuantitySample else {
                return nil
            }

            return HeartRateReading(
                id: quantitySample.uuid,
                beatsPerMinute: quantitySample.quantity.doubleValue(for: unit),
                date: quantitySample.endDate
            )
        }

        guard !newReadings.isEmpty else {
            if appleWorkoutReadings.isEmpty {
                statusText = "No recent heart-rate sample is available."
            }
            return
        }

        let existingIDs = Set(appleWorkoutReadings.map(\.id))
        let uniqueReadings = newReadings
            .filter { !existingIDs.contains($0.id) }
            .sorted { $0.date < $1.date }

        let previousZoneID = currentZoneID
        for reading in uniqueReadings {
            updateZone(for: reading)
        }
        if let currentZoneID, currentZoneID != previousZoneID {
            spotifyConnectivity.sendZoneChange(currentZoneID)
        }

        appleWorkoutReadings.append(contentsOf: uniqueReadings)
        appleWorkoutReadings.sort { $0.date > $1.date }
        appleWorkoutReadings = Array(appleWorkoutReadings.prefix(5))
        statusText = "Receiving heart rate from Apple Workout."
    }

    private func updateZone(for reading: HeartRateReading) {
        guard let measuredZone = zone(for: reading.beatsPerMinute) else {
            return
        }

        guard let currentZoneID else {
            self.currentZoneID = measuredZone.id
            clearPendingZone()
            return
        }

        if measuredZone.id == currentZoneID {
            clearPendingZone()
            return
        }

        if measuredZone.id != pendingZoneID {
            pendingZoneID = measuredZone.id
            pendingZoneStartDate = reading.date
            return
        }

        guard let pendingZoneStartDate,
              reading.date.timeIntervalSince(pendingZoneStartDate) >= 20 else {
            return
        }

        self.currentZoneID = measuredZone.id
        clearPendingZone()
    }

    private func zone(for beatsPerMinute: Double) -> PreferredHeartRateZone? {
        preferredHeartRateZones.first { $0.contains(beatsPerMinute) }
    }

    private func clearPendingZone() {
        pendingZoneID = nil
        pendingZoneStartDate = nil
    }

    private func refreshCurrentZone() {
        guard let reading = appleWorkoutReadings.first else {
            currentZoneID = nil
            clearPendingZone()
            return
        }

        currentZoneID = zone(for: reading.beatsPerMinute)?.id
        clearPendingZone()
    }

    private func startWorkout() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )

            session.delegate = self
            builder.delegate = self

            let startDate = Date()
            self.session = session
            self.builder = builder

            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)

            isRunning = true
            statusText = "Workout active"
        } catch {
            statusText = error.localizedDescription
            session = nil
            builder = nil
        }
    }

    private func endWorkout() async {
        let endDate = Date()
        session?.end()

        do {
            try await builder?.endCollection(at: endDate)
            _ = try await builder?.finishWorkout()
        } catch {
            statusText = error.localizedDescription
        }

        session = nil
        builder = nil
        isRunning = false
        statusText = "Ready"
    }

    private func updateHeartRate(from builder: HKLiveWorkoutBuilder) {
        guard let heartRateType,
              let statistics = builder.statistics(for: heartRateType) else {
            return
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        heartRate = statistics.mostRecentQuantity()?.doubleValue(for: unit)
    }

    private var heartRateType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRate)
    }
}

extension HeartRateWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            isRunning = toState == .running
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            statusText = error.localizedDescription
            isRunning = false
        }
    }
}

extension HeartRateWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard collectedTypes.contains(where: {
            $0.identifier == HKQuantityTypeIdentifier.heartRate.rawValue
        }) else {
            return
        }

        Task { @MainActor in
            updateHeartRate(from: workoutBuilder)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
    }
}

#Preview {
    WatchHeartRateView()
}
