import Foundation
import SwiftUI

/// One reading of everything the phone will admit to, at one moment.
struct Sample {
    let seconds: TimeInterval
    let percent: Int
    let inputVolts: Double
    let inputAmps: Double
    let cellVolts: Double
    let cellAmps: Double
    let batteryTemp: Double?

    var inputWatts: Double { inputVolts * inputAmps }
    var cellWatts: Double { cellVolts * cellAmps }
}

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
    @Published var samples: [Sample] = []
    @Published var verdict: Verdict?
    @Published var sensorError: String?
    @Published var railVolts: Double = 0
    @Published var packVolts: Double = 0

    /// Nominal pack energy. iPhone 15 Pro is 12.7 Wh (3274 mAh x 3.87 V).
    ///
    /// Read straight from defaults rather than through `@AppStorage`, which only
    /// publishes changes when used inside a View.
    var packWh: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "packWh") as? Double
            return (stored ?? 12.7).clampedToPackRange
        }
        set { UserDefaults.standard.set(newValue, forKey: "packWh") }
    }

    private var sensors: PowerSensors?
    private var powerSources: PowerSources?
    private var timer: Timer?
    private var startedAt: Date?
    private var lastLevelSample: (TimeInterval, Int)?

    private init() {
        sensors = PowerSensors()
        powerSources = PowerSources()
        if sensors == nil {
            sensorError = "无法打开 IOKit HID 接口"
        } else if sensors?.serviceCount == 0 {
            sensorError = "没有发现电源传感器（可能被沙盒拒绝）"
        }
    }

    var inputWatts: Double { inputVolts * inputAmps }
    var cellWatts: Double { cellVolts * cellAmps }
    /// Everything the charger sends that does not reach the cell: screen, radio,
    /// SoC and the charge IC's own losses.
    var overheadWatts: Double { max(0, inputWatts - cellWatts) }

    func start() {
        guard !running else { return }
        running = true
        samples = []
        verdict = nil
        elapsed = 0
        startedAt = Date()
        lastLevelSample = nil
        sensors?.rescan()
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        // A verdict from whatever was collected is better than nothing.
        evaluate()
    }

    private func tick() {
        guard running, let startedAt else { return }
        let now = Date()
        let t = now.timeIntervalSince(startedAt)
        elapsed = t

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
        if let rail { railVolts = rail }
        if let pack { packVolts = pack }
        batteryTemp = temp

        // Prefer the pack voltage; fall back to the charger's battery rail.
        cellVolts = pack ?? rail ?? 0

        let snapshot = powerSources?.read()
        if let snapshot {
            percent = snapshot.percent
            charging = snapshot.charging
        }

        let sample = Sample(seconds: t,
                            percent: percent,
                            inputVolts: inputVolts,
                            inputAmps: inputAmps,
                            cellVolts: cellVolts,
                            cellAmps: cellAmps,
                            batteryTemp: temp)
        samples.append(sample)
        if samples.count > 3600 { samples.removeFirst() }

        // Level rises in whole percent and needs a wide span to mean anything.
        if let last = lastLevelSample {
            if abs(percent - last.1) >= 3, t - last.0 >= 120 {
                evaluate()
                lastLevelSample = (t, percent)
            }
        } else {
            lastLevelSample = (t, percent)
        }
    }

    /// Watts implied by the rise in charge level, independent of every sensor
    /// that might be lying.
    private func levelWatts() -> (watts: Double, rise: Int, span: TimeInterval)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let rise = last.percent - first.percent
        let span = last.seconds - first.seconds
        guard rise >= 3, span >= 120 else { return nil }
        let wattHours = Double(rise) / 100.0 * packWh
        return (wattHours / span * 3600.0, rise, span)
    }

    private func evaluate() {
        guard !samples.isEmpty else { return }

        if !charging, inputAmps < 0.05 {
            verdict = Verdict(level: .unknown,
                              headline: "没有在充电",
                              detail: "插上充电器再测。检测器只判断充电状态下的功率。")
            return
        }

        let level = levelWatts()
        let measured = samples.suffix(30).map(\.cellWatts).reduce(0, +) / Double(max(1, min(30, samples.count)))

        // A level-derived figure and the cell sensors should agree within about
        // 30 percent: the level is costed at nominal voltage while the sensors
        // use the real one, and a worn pack holds less than its rating.
        if let level, level.watts > 1, measured > 1 {
            let ratio = level.watts / measured
            if ratio >= 1.6 {
                verdict = Verdict(
                    level: .warn,
                    headline: "传感器读数偏低",
                    detail: String(format: "按电量上升算，实际约有 %.1f W 进入电池；传感器只报 %.1f W。以电量推算为准。", level.watts, measured))
                return
            }
            if ratio >= 0.7, ratio <= 1.3 {
                verdict = chargingVerdict(input: inputWatts, percent: percent, trusted: level.watts)
                return
            }
        }

        // Not enough movement yet: judge on the instantaneous input against what
        // this charge level can normally draw.
        verdict = chargingVerdict(input: inputWatts, percent: percent, trusted: nil)
    }

    private func chargingVerdict(input: Double, percent: Int, trusted: Double?) -> Verdict {
        let expected: ClosedRange<Double>
        switch percent {
        case ..<25: expected = 15...27
        case 25..<50: expected = 17...27
        case 50..<80: expected = 9...16
        default: expected = 3...9
        }

        let shown = trusted ?? input
        let basis = trusted == nil ? "输入功率" : "按电量上升推算的入芯功率"
        let number = String(format: "%.1f W", shown)

        if expected.contains(shown) {
            return Verdict(level: .good,
                           headline: "正常",
                           detail: String(format: "%@ %@，在 %d%% 电量的正常区间（%.0f–%.0f W）。", basis, number, percent, expected.lowerBound, expected.upperBound))
        }
        if shown < expected.lowerBound {
            let severe = shown < expected.lowerBound * 0.55
            return Verdict(level: severe ? .bad : .warn,
                           headline: severe ? "明显限流" : "偏慢",
                           detail: String(format: "%@ %@，低于 %d%% 电量应有的 %.0f–%.0f W。", basis, number, percent, expected.lowerBound, expected.upperBound))
        }
        return Verdict(level: .good,
                       headline: "快于预期",
                       detail: String(format: "%@ %@，高于该电量的常见区间。", basis, number))
    }

    /// Whether the reported cell voltage is consistent with the reported level.
    /// A pack at 50 percent sits near 3.9 V; 3.3 V there means the gauge is not
    /// describing this battery.
    func voltageMismatch() -> String? {
        guard cellVolts > 0.5, percent > 5, percent < 95, charging, cellAmps > 0.2 else { return nil }
        // Resting cell voltage against state of charge: about 3.30 V empty and
        // 4.35 V full for a lithium-ion phone pack.
        let expected = 3.30 + Double(percent) / 100.0 * 1.05
        let delta = abs(cellVolts - expected)
        guard delta > 0.30 else { return nil }
        return String(format: "%d%% 时电池侧电压 %.2f V，正常应约 %.2f V。这项读数不可信（换过电池后常见），结论已改为按电量上升计算。",
                      percent, cellVolts, expected)
    }
}

private extension Double {
    /// A pack energy outside this range is a typo, not a battery.
    var clampedToPackRange: Double {
        (5.0...30.0).contains(self) ? self : 12.7
    }
}
