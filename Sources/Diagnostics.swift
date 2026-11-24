import Foundation
import ObjectiveC.runtime

/// One read-only finding, shown in the app so a screenshot is enough to work out
/// which keep-alive channel this device actually offers.
struct Probe {
    let title: String
    let value: String
    let ok: Bool
}

/// Nothing here changes state. Every check is a lookup or a permission test, so it
/// is safe to run on every launch and cheap enough to run while recording.
enum Diagnostics {
    static let sceneClientClass = "FBSWorkspaceScenesClient"
    static let sceneMethodSelector =
        "sceneID:updateWithSettingsDiff:transitionContext:completion:"

    /// Where the system's own battery history lives. `powerd` writes current,
    /// voltage and temperature every twenty seconds whether or not any app is
    /// running, so if one of these is readable the whole background question
    /// disappears -- the log can be reconstructed after the fact.
    static let powerlogCandidates = [
        "/var/run/powerlog",
        "/var/run/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQLDB",
        "/var/run/powerlog/Library/BatteryLife",
        "/var/wireless/Library/Logs/PowerLog",
    ]

    static func run() -> [Probe] {
        var probes: [Probe] = []

        if let cls = NSClassFromString(sceneClientClass) {
            probes.append(Probe(title: "类 \(sceneClientClass)", value: "已找到", ok: true))

            let selector = NSSelectorFromString(sceneMethodSelector)
            if let method = class_getInstanceMethod(cls, selector) {
                probes.append(Probe(title: "目标方法", value: "已找到", ok: true))
                if let encoding = method_getTypeEncoding(method) {
                    probes.append(Probe(title: "类型编码", value: String(cString: encoding), ok: true))
                } else {
                    probes.append(Probe(title: "类型编码", value: "无", ok: false))
                }
            } else {
                probes.append(Probe(title: "目标方法", value: "未找到", ok: false))
            }
        } else {
            probes.append(Probe(title: "类 \(sceneClientClass)", value: "未找到", ok: false))
        }

        // If the name has changed, this says what it changed to.
        let sceneClasses = classNames(containing: "ScenesClient")
        probes.append(Probe(
            title: "含 ScenesClient 的类",
            value: sceneClasses.isEmpty ? "无" : sceneClasses.prefix(3).joined(separator: ", "),
            ok: !sceneClasses.isEmpty
        ))

        // Collapsed into one line: all four are refused under TrollStore's sandbox on
        // iOS 17, so listing each one separately only crowds the panel. If a future
        // iOS leaves one open, the path that worked is named here.
        let readablePowerlog = powerlogCandidates.filter {
            FileManager.default.isReadableFile(atPath: $0)
        }
        probes.append(Probe(
            title: "powerlog 电池历史",
            value: readablePowerlog.first ?? "不可读（沙盒限制）",
            ok: !readablePowerlog.isEmpty
        ))

        // The flag this app depends on. Shown raw, because on a replaced battery the
        // documented keys are not necessarily the ones present, or they are present
        // and wrong.
        if let snapshot = PowerSources()?.read() {
            let keys = ["Is Charging", "ExternalConnected", "State", "Power Source State",
                        "Battery Status", "Current Capacity", "Max Capacity"]
            let shown = keys.compactMap { key -> String? in
                guard let value = snapshot.raw[key] else { return nil }
                if let flag = value as? Bool { return "\(key)=\(flag ? 1 : 0)" }
                return "\(key)=\(value)"
            }
            probes.append(Probe(
                title: "电源上报原始值",
                value: shown.isEmpty ? "无" : shown.joined(separator: "  "),
                ok: snapshot.charging || snapshot.externalPower
            ))
        }

        return probes
    }

    /// Walks the loaded class list. A hook that cannot find its target is usually a
    /// renamed target, and the rename is only visible by looking.
    private static func classNames(containing needle: String) -> [String] {
        let count = objc_getClassList(nil, 0)
        guard count > 0 else { return [] }

        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let actual = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), count)

        var matches: [String] = []
        for index in 0..<Int(actual) {
            let name = String(cString: class_getName(buffer[index]))
            if name.contains(needle) {
                matches.append(name)
            }
        }
        return matches.sorted()
    }
}
