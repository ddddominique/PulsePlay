//
//  WatchHeartRateView.swift
//  PulsePlay Watch App
//

import HealthKit
import SwiftUI

struct WatchHeartRateView: View {
    @State private var workoutManager = HeartRateWorkoutManager()

    var body: some View {
        VStack(spacing: 12) {
            Text("PulsePlay")
                .font(.headline)

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
                Label(workoutManager.isRunning ? "End" : "Start", systemImage: workoutManager.isRunning ? "stop.fill" : "heart.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(workoutManager.isRunning ? .red : .green)
        }
        .padding()
        .task {
            await workoutManager.requestAuthorization()
        }
    }
}

@MainActor
@Observable
final class HeartRateWorkoutManager: NSObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    var heartRate: Double?
    var isRunning = false
    var statusText = "Requesting Health access..."

    var heartRateText: String {
        guard let heartRate else {
            return "--"
        }

        return heartRate.formatted(.number.precision(.fractionLength(0)))
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusText = "Health data is unavailable on this device."
            return
        }

        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            statusText = "Heart rate data is unavailable."
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

    func toggleWorkout() async {
        if isRunning {
            await endWorkout()
        } else {
            await startWorkout()
        }
    }

    private func startWorkout() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)

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
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let statistics = builder.statistics(for: heartRateType) else {
            return
        }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let value = statistics.mostRecentQuantity()?.doubleValue(for: unit)
        heartRate = value
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

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            statusText = error.localizedDescription
            isRunning = false
        }
    }
}

extension HeartRateWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(where: { $0.identifier == HKQuantityTypeIdentifier.heartRate.rawValue }) else {
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
