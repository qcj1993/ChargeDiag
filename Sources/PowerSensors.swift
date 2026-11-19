// SPDX-License-Identifier: Apache-2.0
//
// Private HID power-sensor reader.
//
// Approach and identifiers follow MiniWatts by ResistanceTo (Apache-2.0):
// https://github.com/ResistanceTo/MiniWatts
//
// iOS exposes Apple's vendor power rails through the private
// IOHIDEventSystemClient API on usage page 0xff08:
//   usage 2 = current (A), usage 3 = voltage (V)
// and temperatures on page 0xff00, usage 5 (degrees Celsius).
//
// A sandboxed process may create exactly one client. Every additional client in
// the same process returns NaN for every service, so this is created once and
// reused for the life of the app.
import Foundation

final class PowerSensors {
    struct Reading {
        let name: String
        let key: String
        let value: Double
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let powerEventType: Int64 = 25
    private static let temperatureEventType: Int64 = 15
    private static let powerUsagePage = 0xff08
    private static let vendorUsagePage = 0xff00

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let key: String
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let matching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let servicesFn = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let propertyFn = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let eventFn = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let floatFn = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let created = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }

        client = created
        setMatching = matching
        copyServices = servicesFn
        copyProperty = propertyFn
        copyEvent = eventFn
        getFloat = floatFn
        rescan()
    }

    var serviceCount: Int { services.count }

    func rescan() {
        var found: [Service] = []
        found += discover(matching: ["PrimaryUsagePage": Self.powerUsagePage],
                          eventType: Self.powerEventType)
        found += discover(matching: ["PrimaryUsagePage": Self.vendorUsagePage, "PrimaryUsage": 5],
                          eventType: Self.temperatureEventType)
        services = found
    }

    func read() -> [Reading] {
        var out: [Reading] = []
        for service in services {
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else {
                continue
            }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { continue }
            out.append(Reading(name: service.name, key: service.key, value: value))
        }
        return out
    }

    static func smcKey(_ location: UInt32) -> String {
        let bytes = withUnsafeBytes(of: location.bigEndian) { Array($0) }
        guard location != 0, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func discover(matching: [String: Any]?, eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary?)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            func number(_ key: String) -> Int {
                (copyProperty(ref, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let location = (copyProperty(ref, "LocationID" as CFString)?
                .takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            return Service(ref: ref,
                           name: name,
                           key: Self.smcKey(location),
                           usage: number("PrimaryUsage"),
                           eventType: eventType)
        }
    }
}
