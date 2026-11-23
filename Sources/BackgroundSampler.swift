import Foundation
import BackgroundTasks
import UIKit

/// Keeps the log alive once the screen goes off.
///
/// iOS freezes this app a few seconds after the display sleeps, which is why a
/// night of charging produced sixty seconds of samples. A background refresh task
/// cannot fix that in full -- the system decides when to run it, and it may skip
/// hours -- but it turns one continuous gap into a handful of sparser ones, and a
/// gap that gets sampled twice can be told apart from one that never was.
///
/// Everything here is best effort. Under TrollStore the task may never be
/// scheduled at all, and that has to degrade quietly into "the app only samples
/// while it is on screen" rather than breaking the recording.
@MainActor
final class BackgroundSampler {
    static let shared = BackgroundSampler()
    static let taskID = "com.qcj.chargedign.sample"

    private var registered = false
    private(set) var lastScheduled: Date?
    private(set) var lastRan: Date?

    private init() {}

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskID,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundSampler.shared.run(refresh)
            }
        }
        if !registered {
            NSLog("[ChargeDiag] background refresh could not be registered")
        }
    }

    func schedule() {
        guard registered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        // The floor iOS allows. Actual delivery is decided by the system and is
        // commonly much later, especially on a phone left face down all night.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            lastScheduled = Date()
        } catch {
            NSLog("[ChargeDiag] could not schedule background refresh: \(error.localizedDescription)")
        }
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
    }

    private func run(_ task: BGAppRefreshTask) {
        // Queue the next one first: if this handler is cut short, the chain must
        // not die with it.
        schedule()

        lastRan = Date()
        task.expirationHandler = {
            Task { @MainActor in
                Diagnosis.shared.backgroundTick()
            }
        }
        Diagnosis.shared.backgroundTick()
        task.setTaskCompleted(success: true)
    }
}

/// Registration has to happen before the first scene is created, or the system
/// refuses the task identifier outright.
final class ChargeDiagDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSampler.shared.register()
        return true
    }
}
