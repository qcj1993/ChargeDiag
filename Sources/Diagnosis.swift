import Foundation
import SwiftUI

/// The answer, in one card.
struct Verdict {
    enum Level {
        case good, warn, bad, unknown

        var tint: Color {
            switch self {
            case .good: return Color(red: 0.20, green: 0.78, blue: 0.45)
            case .warn: return Color(red: 0.98, green: 0.68, blue: 0.19)
            case .bad: return Color(red: 0.95, green: 0.34, blue: 0.30)
            case .unknown: return Color(red: 0.60, green: 0.62, blue: 0.68)
            }
        }
    }

    let level: Level
    let headline: String
    let detail: String
}

@MainActor
final class Diagnosis: ObservableObject {
    static let shared = Diagnosis()

    // Live numbers.
    @Published var inputVolts: Double = 0
    @Published var inputAmps: Double = 0
    @Published var cellVolts: Double = 0
    @Published var cellAmps: Double = 0
    @Published var batteryTemp: Double?
    @Published var percent: Int = 0
    @Published var charging = false

    // Session state.
    @Published var running = false
    @Published var elapsed: TimeInterval = 0
    @Published var rows = 0
    @Published var peakInput: Double = 0
    @Published var peakInputBelow50: Double = 0
    @Published var verdict: Verdict?
    @Published var sensorError: String?
    @Published var logURL: URL?
    @Published var sessions: [SessionSummary] = []
    @Published var showingShares = false
    /// Points for the curve: the live session, or a past one the person picked.
    @Published var chart: [LogRow] = []
    @Published var chartLabel = "本次记录"
    /// Set when the log was picked up from a previous run rather than started now.
    @Published var resumedFrom: Date?

    private var sensors: PowerSensors?
    private var powerSources: PowerSources?
    private var timer: Timer?
    private var startedAt: Date?

    /// Nominal pack energy. iPhone 15 Pro is 12.7 Wh (3274 mAh x 3.87 V).
    var packWh: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "packWh") as? Double
            return (stored ?? 12.7).clampedToPackRange
        }
        set { UserDefaults.standard.set(newValue, forKey: "packWh") }
    }

    private init() {
        powerSources = PowerSources()
        sensors = PowerSensors()
        if sensors == nil {
            sensorError = "无法打开 IOKit HID 接口"
        } else if sensors?.serviceCount == 0 {
            sensorError = "没有发现电源传感器（可能被沙盒拒绝）"
        }
        // A run that never got to stop: charge overnight, app suspended, phone
        // now on the lock screen. Settle it before showing anything.
        if let settled = ChargeLog.shared.settleOrphanedSession(packWh: packWh) {
            verdict = Self.verdict(for: settled)
        }
        sessions = ChargeLog.shared.summaries()
        if let latest = sessions.first {
            loadChart(for: latest)
        }
    }

    var inputWatts: Double { inputVolts * inputAmps }
    var cellWatts: Double { cellVolts * cellAmps }
    var overheadWatts: Double { max(0, inputWatts - cellWatts) }

    var packWhText: String { String(format: "%.1f Wh", packWh) }

    // MARK: - Control

    func start() {
        guard !running else { return }
        running = true
        verdict = nil
        elapsed = 0
        rows = 0
        peakInput = 0
        peakInputBelow50 = 0
        chart = []
        chartLabel = "本次记录"
        resumedFrom = nil
        startedAt = Date()
        sensors?.rescan()
        logURL = ChargeLog.shared.begin(packWh: packWh)
        BackgroundSampler.shared.schedule()
        // Hold the process open before the screen can sleep on us. The scene hook
        // went in at launch; the audio session starts and stops with the recording.
        BackgroundKeeper.shared.start()
        backgroundAudio = BackgroundKeeper.shared.audioRunning
        sceneHookInstalled = SceneKeeper.shared.installed
        tick()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        ChargeLog.shared.close(packWh: packWh)
        BackgroundSampler.shared.cancel()
        BackgroundKeeper.shared.stop()
        backgroundAudio = false
        sessions = ChargeLog.shared.summaries()
        if let latest = sessions.first {
            verdict = Self.verdict(for: latest)
            loadChart(for: latest)
        }
    }

    /// The screen went away. The process freezes next, so make the log durable
    /// and leave the session open for whoever picks it up -- this app on resume,
    /// or the next launch if iOS reclaims the memory. Closing here would end the
    /// night's record a few seconds after it started.
    func sceneWillResignActive() {
        BackgroundSampler.shared.schedule()
        guard running else { return }
        sample()
        ChargeLog.shared.flush()
    }

    /// Back in the foreground. Timers do not run while suspended, so restart the
    /// one that stopped and take a reading: its elapsed time spans the whole gap,
    /// which is exactly what makes an overnight charge readable afterwards.
    func sceneDidBecomeActive() {
        BackgroundKeeper.shared.verify()
        backgroundAudio = BackgroundKeeper.shared.audioRunning
        guard running else {
            refreshSessions()
            return
        }
        sample()
        ChargeLog.shared.flush()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Called by the background refresh task. Appends one row to the open session
    /// so the night is punctuated rather than blank.
    func backgroundTick() {
        guard running, ChargeLog.shared.isRecording else { return }
        sample()
        ChargeLog.shared.flush()
    }

    /// Whether the silent audio session is currently holding the process open.
    /// Shown in the UI, because "the app is recording" and "the app will still be
    /// recording in an hour" are different promises.
    @Published var backgroundAudio = false

    /// Whether the scene hook installed, and how many background transitions it has
    /// swallowed. The count is the honest half: installed but zero blocked proves
    /// only that the method was found, not that the system ever asked to suspend us.
    @Published var sceneHookInstalled = false
    @Published var blockedTransitions = 0

    var keepScreenOn: Bool {
        get { BackgroundKeeper.shared.keepScreenOn }
        set {
            objectWillChange.send()
            BackgroundKeeper.shared.keepScreenOn = newValue
            backgroundAudio = BackgroundKeeper.shared.audioRunning
        }
    }

    func refreshSessions() {
        sessions = ChargeLog.shared.summaries()
        loadChart(for: sessions.first)
    }

    // MARK: - Sampling

    private func tick() {
        guard running, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        blockedTransitions = SceneKeeper.shared.blocked
        sample()
    }

    private func sample() {
        // A wake-up can arrive before `start()` has run, when the phone was
        // plugged in with the app closed. Reopen the session it left behind.
        if startedAt == nil, running == false, ChargeLog.shared.hasOpenSession {
            guard ChargeLog.shared.reopen(packWh: packWh) else { return }
            running = true
            startedAt = ChargeLog.shared.openSessionStartedAt
            resumedFrom = startedAt
        }
        guard let startedAt else { return }

        let readings = sensors?.read() ?? []
        var vIn: Double?
        var iIn: Double?
        var iCell: Double?
        var rail: Double?
        var pack: Double?
        var temp: Double?

        for reading in readings {
            switch reading.key {
            case "VQ0u": vIn = reading.value
            case "IQ0u": iIn = reading.value
            case "IQ0B": iCell = reading.value
            case "VQ0l": rail = reading.value
            case "VP0u": pack = reading.value
            default: break
            }
            if reading.name.contains("gas gauge"), reading.name.contains("battery"),
               reading.value > -40, reading.value < 150 {
                temp = reading.value
            }
        }

        if let vIn { inputVolts = vIn }
        if let iIn { inputAmps = iIn }
        if let iCell { cellAmps = iCell }
        batteryTemp = temp
        cellVolts = pack ?? rail ?? cellVolts

        if let snapshot = powerSources?.read() {
            percent = snapshot.percent
            charging = snapshot.charging
        }

        let elapsedNow = Date().timeIntervalSince(startedAt)
        elapsed = max(elapsed, elapsedNow)
        let row = LogRow(elapsed: elapsedNow,
                         at: Date(),
                         percent: percent,
                         inputV: inputVolts,
                         inputA: inputAmps,
                         cellV: cellVolts,
                         cellA: cellAmps,
                         temp: temp,
                         charging: charging)
        ChargeLog.shared.append(row)

        rows += 1
        peakInput = max(peakInput, row.inputW)
        if row.percent < 50 {
            peakInputBelow50 = max(peakInputBelow50, row.inputW)
        }

        // Keep the curve bounded without losing its shape: past the cap, drop
        // every other point. Elapsed time is absolute, so the line stays correct
        // and only its resolution halves.
        if chart.count >= 1200 {
            var thinned: [LogRow] = []
            thinned.reserveCapacity(chart.count / 2 + 1)
            for (index, point) in chart.enumerated() where index % 2 == 0 {
                thinned.append(point)
            }
            chart = thinned
        }
        chart.append(row)
    }

    /// Show a finished session's curve.
    func loadChart(for summary: SessionSummary?) {
        guard let summary else { return }
        chart = ChargeLog.shared.rows(summary.id)
        chartLabel = summary.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Verdicts

    private static func verdict(for summary: SessionSummary) -> Verdict {
        let span = summary.startedAt.formatted(date: .abbreviated, time: .shortened)
        let peak = summary.sawBelow50 ? summary.peakInputWBelow50 : summary.peakInputW

        // A charge that finished early and then sat full is not slow. Say so
        // before any rate is judged, or a perfectly healthy overnight charge
        // reads as a failure.
        if let fullAt = summary.fullAt,
           let chargingSeconds = summary.chargingSeconds,
           chargingSeconds > 0 {
            let idleMinutes = summary.endedAt.timeIntervalSince(fullAt) / 60
            if idleMinutes > 20, summary.lastPercent >= 100 {
                return Verdict(
                    level: .good,
                    headline: "早就在 " + fullAt.formatted(date: .omitted, time: .shortened) + " 充满了",
                    detail: "\(span) 到现在跨度 \(duration(summary.seconds))，但只有前 \(duration(chargingSeconds)) 在充电，之后一直满电待机。峰值 \(String(format: "%.1f", peak)) W，实际充电速率 \(rateText(summary))。这台机器充电正常。")
            }
        }

        guard peak > 0.1 else {
            return Verdict(level: .unknown,
                           headline: "没有采到有效数据",
                           detail: "\(span) 这次记录里没有充电功率读数，日志已保留，可导出查看。")
        }

        // The rate the level rose at is the figure that answers "was this slow".
        // It is immune to the app being frozen, because it comes from two levels
        // the system reported either side of the night.
        if let rate = summary.levelWatts {
            if rate >= 12 {
                return Verdict(level: .good,
                               headline: "充电正常：\(String(format: "%.1f", rate)) W",
                               detail: "\(span) 起，按电量上升速率换算是 \(String(format: "%.1f", rate)) W（\(rateText(summary))），峰值 \(String(format: "%.1f", peak)) W。链路没有限制。")
            }
            if rate >= 6 {
                return Verdict(level: .warn,
                               headline: "偏慢：\(String(format: "%.1f", rate)) W",
                               detail: "\(span) 起，按电量上升速率换算只有 \(String(format: "%.1f", rate)) W（\(rateText(summary))），峰值 \(String(format: "%.1f", peak)) W。前端能协商，但大部分时间没吃满。")
            }
            return Verdict(level: .bad,
                           headline: "明显限流：\(String(format: "%.1f", rate)) W",
                           detail: "\(span) 起，按电量上升速率换算只有 \(String(format: "%.1f", rate)) W（\(rateText(summary))），虽然峰值到过 \(String(format: "%.1f", peak)) W。功率只在开头短暂出现，随后被压住。")
        }

        // No usable rate: fall back to the peak, and say that is what it is.
        if peak >= 18 {
            return Verdict(level: .good,
                           headline: "快充正常：峰值 \(String(format: "%.1f", peak)) W",
                           detail: "\(span) 起，\(summary.sawBelow50 ? "50% 以下" : "过程中")最高 \(String(format: "%.1f", peak)) W。这次没采到足够的连续数据来算平均速率，建议再记录一次并保持 App 打开几分钟。")
        }
        if peak >= 12 {
            return Verdict(level: .warn,
                           headline: "偏慢：峰值 \(String(format: "%.1f", peak)) W",
                           detail: "\(span) 起，最高只有 \(String(format: "%.1f", peak)) W，低于该电量应有的 18–27 W。")
        }
        return Verdict(level: .bad,
                       headline: "明显限流：峰值 \(String(format: "%.1f", peak)) W",
                       detail: "\(span) 起，最高只有 \(String(format: "%.1f", peak)) W。前端握手正常却取不上功率，问题在手机内部到电池这一段。")
    }

    private static func rateText(_ summary: SessionSummary) -> String {
        guard let perHour = summary.percentPerHour else { return "速率未知" }
        return String(format: "每小时 %.0f%%", perHour)
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
        }
        return "\(max(1, total / 60)) 分"
    }

    /// Whether the reported cell voltage is consistent with the reported level.
    func voltageMismatch() -> String? {
        guard cellVolts > 0.5, percent > 5, percent < 95, charging, cellAmps > 0.2 else { return nil }
        let expected = 3.30 + Double(percent) / 100.0 * 1.05
        guard abs(cellVolts - expected) > 0.30 else { return nil }
        return "\(percent)% 时电池侧电压 " + String(format: "%.2f", cellVolts)
            + " V，正常应约 " + String(format: "%.2f", expected)
            + " V。这项读数不可信（换过电池后常见），结论以电量与输入功率为准。"
    }

    func shareItems() -> [Any] {
        var items: [Any] = []
        for summary in sessions.prefix(3) {
            let url = ChargeLog.shared.csvURLFor(summary.id)
            if FileManager.default.fileExists(atPath: url.path) {
                items.append(url)
            }
        }
        if items.isEmpty, let url = logURL, FileManager.default.fileExists(atPath: url.path) {
            items.append(url)
        }
        return items
    }
}

private extension Double {
    /// A pack energy outside this range is a typo, not a battery.
    var clampedToPackRange: Double {
        (5.0...30.0).contains(self) ? self : 12.7
    }
}
