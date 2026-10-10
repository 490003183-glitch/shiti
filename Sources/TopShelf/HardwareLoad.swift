import Foundation
import IOKit
import Darwin

struct PowerInputSnapshot: Equatable {
    var connected: Bool?
    var watts: Double?
    var volts: Double?

    var title: String {
        if connected == false { return "未接电源" }
        let power = watts.map { String(format: "%.1f", $0) } ?? "—"
        let voltage = volts.map { String(format: "%.1f", $0) } ?? "—"
        return "输入 \(power) W · \(voltage) V"
    }
}

/// Read actual DC input telemetry, never adapter capacity or battery-side voltage.
/// Each read releases its registry service; no connection survives panel dismissal.
enum PowerInputReader {
    static func decode(_ properties: [String: Any]) -> PowerInputSnapshot {
        guard let connected = properties["ExternalConnected"] as? Bool else { return .init() }
        guard connected else { return .init(connected: false) }
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        // AppleSmartBattery reports these in mW / mV. Reject booleans,
        // unsigned negative sentinels and implausible values instead of displaying them.
        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let number = telemetry[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue / 1000
            return value.isFinite && range.contains(value) ? value : nil
        }
        return .init(connected: true,
                     watts: number("SystemPowerIn", range: 0...1000),
                     volts: number("SystemVoltageIn", range: 0.001...60))
    }

    static func read() -> PowerInputSnapshot {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .init() }
        defer { IOObjectRelease(service) }
        var properties: [String: Any] = [:]
        for key in ["PowerTelemetryData", "ExternalConnected"] {
            properties[key] = IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
        }
        return decode(properties)
    }
}

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    static func read() -> Self? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Self(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}

struct CPULoadTracker {
    private var previous: CPUTicks?
    private var timestamp: TimeInterval?
    mutating func reset() { previous = nil; timestamp = nil }
    mutating func update(_ ticks: CPUTicks?, at time: TimeInterval) -> Double? {
        guard let ticks else { reset(); return nil }
        defer { previous = ticks; timestamp = time }
        guard let previous, let timestamp, time > timestamp, time - timestamp < 15 else { return nil }
        // Kernel counters are unsigned 32-bit values; subtraction must allow rollover.
        let busy = Double(ticks.user &- previous.user) + Double(ticks.system &- previous.system) + Double(ticks.nice &- previous.nice)
        let total = busy + Double(ticks.idle &- previous.idle)
        return total > 0 ? busy / total * 100 : nil
    }
}

/// Read only the driver's existing utilization property. No GPU workload or counters are enabled.
final class GPULoadReader {
    private var services: [io_service_t] = []
    private var attempted = false
    func close() {
        services.forEach { IOObjectRelease($0) }
        services.removeAll(); attempted = false
    }
    deinit { close() }
    static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && (0...100).contains(value) ? value : nil
    }
    func read() -> Double? {
        if !attempted {
            attempted = true
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                services.append(service)
            }
        }
        return services.compactMap { service -> Double? in
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
            return Self.percentage(stats["Device Utilization %"])
        }.max()
    }
}

/// Average of driver-reported compute-utilization buckets, not power-state residency.
enum ANEHistogram {
    static func percentage(_ states: [(name: String, residency: Int64)]) -> Double? {
        guard !states.isEmpty else { return nil }
        var weighted = 0.0
        var total = 0.0
        for state in states {
            let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasSuffix("%"), let bucket = Double(name.dropLast()),
                  bucket.isFinite, (0...100).contains(bucket), state.residency >= 0 else { return nil }
            weighted += bucket * Double(state.residency)
            total += Double(state.residency)
        }
        return total > 0 ? weighted / total : nil
    }
}

/// Optional private IOReport ABI. Subscribe only to ANE compute histograms while visible.
/// Unsupported machines/builds show unavailable; never substitute voltage, power or interrupts.
final class ANELoadReader {
#if !APP_STORE
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias Samples = @convention(c) (CFTypeRef, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias Residency = @convention(c) (CFDictionary, Int32) -> Int64
    private var library: UnsafeMutableRawPointer?
    private var subscription: CFTypeRef?
    private var channels: CFDictionary?
    private var previous: CFDictionary?
    private var timestamp: TimeInterval?
    private var samples: Samples?
    private var delta: Delta?
    private var stateCount: Count?
    private var stateName: StateName?
    private var residency: Residency?
    private var attempted = false

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
    private func prepare() {
        guard !attempted else { return }
        attempted = true
        library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL)
        guard let copy = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
              let subscribe = symbol("IOReportCreateSubscription", as: Subscribe.self),
              let name = symbol("IOReportChannelGetChannelName", as: Name.self) else { return }
        samples = symbol("IOReportCreateSamples", as: Samples.self)
        delta = symbol("IOReportCreateSamplesDelta", as: Delta.self)
        stateCount = symbol("IOReportStateGetCount", as: Count.self)
        stateName = symbol("IOReportStateGetNameForIndex", as: StateName.self)
        residency = symbol("IOReportStateGetResidency", as: Residency.self)
        guard samples != nil, delta != nil, stateCount != nil, stateName != nil, residency != nil,
              let available = copy("PMP" as CFString, "Fast-Die CE" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let list = (available as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return }
        let selected = list.filter { channel in
            guard let label = name(channel)?.takeUnretainedValue() as String? else { return false }
            // Require the exact ANE + numeric instance pattern, excluding bandwidth channels.
            return label.hasPrefix("ANE") && !label.dropFirst(3).isEmpty && label.dropFirst(3).allSatisfy(\.isNumber)
        }
        guard !selected.isEmpty, let request = CFDictionaryCreateMutableCopy(nil, 0, available) else { return }
        let key = "IOReportChannels" as CFString
        let value = selected as CFArray
        CFDictionarySetValue(request, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value).toOpaque())
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = subscribe(nil, request, &subscribed, 0, nil)?.takeRetainedValue()
        let actual = subscribed?.takeRetainedValue()
        if subscription != nil { channels = actual ?? request }
    }
#endif

    func close() {
#if !APP_STORE
        previous = nil; timestamp = nil; channels = nil; subscription = nil
        samples = nil; delta = nil; stateCount = nil; stateName = nil; residency = nil
        if let library { dlclose(library) }
        library = nil; attempted = false
#endif
    }
    deinit { close() }

    func read(at time: TimeInterval) -> Double? {
#if APP_STORE
        return nil
#else
        prepare()
        guard let subscription, let channels, let samples, let delta, let stateCount, let stateName, let residency,
              let current = samples(subscription, channels, nil)?.takeRetainedValue() else {
            previous = nil; timestamp = nil
            return nil
        }
        defer { previous = current; timestamp = time }
        guard let previous, let timestamp, time > timestamp, time - timestamp < 15,
              let difference = delta(previous, current, nil)?.takeRetainedValue(),
              let list = (difference as NSDictionary)["IOReportChannels"] as? [CFDictionary], !list.isEmpty else { return nil }
        var percentages: [Double] = []
        for channel in list {
            let count = stateCount(channel)
            guard (1...128).contains(count) else { return nil }
            var states: [(String, Int64)] = []
            for index in 0..<count {
                guard let name = stateName(channel, index)?.takeUnretainedValue() as String? else { return nil }
                states.append((name, residency(channel, index)))
            }
            guard let value = ANEHistogram.percentage(states) else { return nil }
            percentages.append(value)
        }
        return percentages.reduce(0, +) / Double(percentages.count)
#endif
    }
}
