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
        if let settled = ChargeLog.shared.settleOrphanedSession() {
            verdict = Self.verdict(for: settled)
        }
        sessions = ChargeLog.shared.summaries()
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
        startedAt = Date()
        sensors?.rescan()
        logURL = ChargeLog.shared.begin(packWh: packWh)
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
        ChargeLog.shared.close()
        sessions = ChargeLog.shared.summaries()
        if let latest = sessions.first {
            verdict = Self.verdict(for: latest)
        }
    }

    /// The screen went away. The process freezes next, so make the log durable
    /// and leave the session open for whoever picks it up -- this app on resume,
    /// or the next launch if iOS reclaims the memory. Closing here would end the
    /// night's record a few seconds after it started.
    func sceneWillResignActive() {
        guard running else { return }
        sample()
        ChargeLog.shared.flush()
    }

    /// Back in the foreground. Timers do not run while suspended, so restart the
    /// one that stopped and take a reading: its elapsed time spans the whole gap,
    /// which is exactly what makes an overnight charge readable afterwards.
    func sceneDidBecomeActive() {
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

    func refreshSessions() {
        sessions = ChargeLog.shared.summaries()
    }

    // MARK: - Sampling

    private func tick() {
        guard running, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        sample()
    }

    private func sample() {
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

        let row = LogRow(elapsed: Date().timeIntervalSince(startedAt),
                         at: Date(),
                         percent: percent,
                         inputV: inputVolts,
                         inputA: inputAmps,
                         cellV: cellVolts,
                         cellA: cellAmps,
                         temp: temp)
        ChargeLog.shared.append(row)

        rows += 1
        peakInput = max(peakInput, row.inputW)
        if row.percent < 50 {
            peakInputBelow50 = max(peakInputBelow50, row.inputW)
        }
    }

    // MARK: - Verdicts

    private static func verdict(for summary: SessionSummary) -> Verdict {
        let peak = summary.sawBelow50 ? summary.peakInputWBelow50 : summary.peakInputW
        let span = summary.startedAt.formatted(date: .abbreviated, time: .shortened)
        let window = summary.sawBelow50 ? "50% 以下" : "整个充电过程"

        guard peak > 0.1 else {
            return Verdict(level: .unknown,
                           headline: "没有采到有效数据",
                           detail: "\(span) 这次记录里没有充电功率读数，日志已保留，可导出查看。")
        }

        if peak >= 18 {
            return Verdict(level: .good,
                           headline: "快充正常：峰值 \(String(format: "%.1f", peak)) W",
                           detail: "\(span) 起，\(window)最高取到 \(String(format: "%.1f", peak)) W。这个功率对 iPhone 15 Pro 是正常的快充水平，充电链路没有限制。")
        }
        if peak >= 12 {
            return Verdict(level: .warn,
                           headline: "偏慢：峰值 \(String(format: "%.1f", peak)) W",
                           detail: "\(span) 起，\(window)最高 \(String(format: "%.1f", peak)) W，低于该电量应有的 18–27 W，但不至于停摆。可能来自温度、线材或充电策略。")
        }
        return Verdict(level: .bad,
                       headline: "明显限流：峰值 \(String(format: "%.1f", peak)) W",
                       detail: "\(span) 起，\(window)最高只有 \(String(format: "%.1f", peak)) W。前端握手正常却取不上功率，问题在手机内部到电池这一段。")
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
        let top = sessions.prefix(3)
        for summary in top {
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
