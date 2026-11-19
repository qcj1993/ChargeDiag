import Foundation

/// Battery level and charging flag from powerd, via IOKit.
///
/// Unlike the vendor rails, this path survives the sandbox on a real iPhone:
/// it is what every battery widget uses. The percentage is reported by the gas
/// gauge, so it is trustworthy even when other battery-derived values are not.
final class PowerSources {
    struct Snapshot {
        let percent: Int
        let charging: Bool
        let full: Bool
        /// Nominal pack energy in watt-hours, from the OS when it reports it.
        let maxCapacity: Int?
    }

    private typealias CopyInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias DescribeFn = @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?

    private let copyInfo: CopyInfoFn
    private let copyList: CopyListFn
    private let describe: DescribeFn

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let info = sym("IOPSCopyPowerSourcesInfo", CopyInfoFn.self),
              let list = sym("IOPSCopyPowerSourcesList", CopyListFn.self),
              let desc = sym("IOPSGetPowerSourceDescription", DescribeFn.self)
        else { return nil }
        copyInfo = info
        copyList = list
        describe = desc
    }

    func read() -> Snapshot? {
        guard let blob = copyInfo()?.takeRetainedValue(),
              let sources = copyList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = describe(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let current = description["Current Capacity"] as? Int
            let max = description["Max Capacity"] as? Int
            let charging = description["Is Charging"] as? Bool ?? false
            let state = description["State"] as? String

            var percent = 0
            if let current, let max, max > 0 {
                percent = Int((Double(current) / Double(max) * 100).rounded())
            } else if let capacity = description["BatteryCurrentCapacity"] as? Int {
                percent = capacity
            }

            return Snapshot(percent: percent,
                            charging: charging || state == "Charging",
                            full: state == "Full" || percent >= 100,
                            maxCapacity: max)
        }
        return nil
    }
}
