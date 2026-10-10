import AppKit
import SwiftUI
import SystemConfiguration
import IOKit
import Darwin

struct InterfaceBytes: Equatable {
    let received: UInt64
    let sent: UInt64
}

struct NetworkRate: Equatable {
    let download: Double
    let upload: Double
}

struct NetworkRateTracker {
    private var previous: [String: InterfaceBytes]?
    private var timestamp: TimeInterval?

    mutating func reset() { previous = nil; timestamp = nil }
    mutating func update(_ current: [String: InterfaceBytes]?, at time: TimeInterval) -> NetworkRate? {
        guard let current else { reset(); return nil }
        defer { previous = current; timestamp = time }
        guard let previous, let timestamp, time > timestamp, time - timestamp < 15 else { return nil }
        var received: Double = 0
        var sent: Double = 0
        for (name, value) in current {
            guard let old = previous[name], value.received >= old.received, value.sent >= old.sent else { continue }
            received += Double(value.received - old.received)
            sent += Double(value.sent - old.sent)
        }
        return NetworkRate(download: received / (time - timestamp), upload: sent / (time - timestamp))
    }
}

enum ConnectionIndicator: Equatable {
    case vpn, connecting, proxy, tunnel, notDetected, unavailable
    static func classify(connected: Bool, connecting: Bool, proxy: Bool, tunnel: Bool, readable: Bool) -> Self {
        if connected { return .vpn }
        if connecting { return .connecting }
        if proxy { return .proxy }
        if tunnel { return .tunnel }
        return readable ? .notDetected : .unavailable
    }
    var title: String {
        switch self {
        case .vpn: return "VPN 已连"
        case .connecting: return "VPN 连接中"
        case .proxy: return "代理已开"
        case .tunnel: return "隧道"
        case .notDetected: return "VPN 未检出"
        case .unavailable: return "VPN 未知"
        }
    }
    var help: String {
        switch self {
        case .vpn: return "系统报告 VPN 已连接；分流规则仍由 VPN 应用决定。"
        case .connecting: return "系统 VPN 正在连接或断开。"
        case .proxy: return "系统 HTTP、HTTPS、SOCKS 或自动代理已启用；不代表 VPN 已连接或代理服务器可用。"
        case .tunnel: return "检测到活动隧道接口；系统服务也会创建隧道，不能据此确认 VPN。"
        case .notDetected: return "未检测到系统 VPN、系统代理或活动隧道；无法识别仅在应用内部工作的代理。"
        case .unavailable: return "无法读取系统连接状态。"
        }
    }
    var symbol: String { self == .proxy ? "network" : "shield.lefthalf.filled" }
}

struct SystemStatusSnapshot: Equatable {
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var temperature: Double?
    var thermal = "温况未知"
    var rate: NetworkRate?
    var powerInput = PowerInputSnapshot()
    var connection: ConnectionIndicator = .unavailable

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func speed(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 1024 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB/s", bytes / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bytes / (1024 * 1024)) }
        return String(format: "%.1f GB/s", bytes / (1024 * 1024 * 1024))
    }
}

/// Read interface totals only. No packet inspection, external requests or subprocesses.
enum LocalNetworkStatus {
    static func interfaces() -> (physical: [String: InterfaceBytes], tunnel: Bool)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, 6, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        var counters: [String: InterfaceBytes] = [:]
        var tunnel = false
        for info in interfaceRecords(in: data.prefix(size)) {
            guard info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_LOOPBACK == 0 else { continue }
            var nameBytes = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard if_indextoname(UInt32(info.ifm_index), &nameBytes) != nil else { continue }
            let name = String(cString: nameBytes)
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { tunnel = true }
            // en* includes Wi-Fi and Ethernet/USB NICs; exclude bridge, AWDL,
            // loopback and tunnel counters to avoid counting packets twice.
            if name.hasPrefix("en"), !name.dropFirst(2).isEmpty, name.dropFirst(2).allSatisfy(\.isNumber) {
                counters["\(name):\(info.ifm_index)"] = InterfaceBytes(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
            }
        }
        return (counters, tunnel)
    }

    static func interfaceRecords(in data: Data) -> [if_msghdr2] {
        data.withUnsafeBytes { buffer in
            var records: [if_msghdr2] = []
            var offset = 0
            // Route messages share only this four-byte prefix. Address records
            // may be shorter than an interface header and must still be skipped.
            while offset + 4 <= data.count {
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= data.count else { break }
                if buffer[offset + 3] == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    records.append(buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self))
                }
                offset += length
            }
            return records
        }
    }

    static func connection(tunnel: Bool) -> ConnectionIndicator {
        var connected = false
        var connecting = false
        var readable = false
        if let preferences = SCPreferencesCreate(nil, "TopShelf status" as CFString, nil),
           let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] {
            readable = true
            for service in services {
                guard let interface = SCNetworkServiceGetInterface(service),
                      let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                      ["VPN", "IPSec", "PPP"].contains(type),
                      let id = SCNetworkServiceGetServiceID(service),
                      let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil) else { continue }
                let status = SCNetworkConnectionGetStatus(connection)
                connected = connected || status == .connected
                connecting = connecting || status == .connecting || status == .disconnecting
            }
        }
        let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any]
        let proxy = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
            .contains { (proxies?[$0] as? NSNumber)?.boolValue == true }
        return .classify(connected: connected, connecting: connecting, proxy: proxy, tunnel: tunnel, readable: readable)
    }
}

/// Read-only AppleSMC client. No write command, fan control or privileged helper.
/// The protocol is not a public temperature API; disable it in App Store builds.
final class CPUTemperatureReader {
    private var connection: io_connect_t = 0
    private var attempted = false
    private var sensors: [(key: UInt32, type: UInt32, size: UInt32)] = []
    static func code(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0; attempted = false; sensors.removeAll()
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func command(key: UInt32, operation: UInt8, size: UInt32 = 0) -> Data? {
        guard connection != 0 else { return nil }
        // SMC user-client request ABI: 80 bytes, keyInfo at 28, command at 42,
        // and the read-only 32-byte value payload at 48.
        var input = Data(count: 80)
        input.withUnsafeMutableBytes {
            $0.storeBytes(of: key, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
            $0[42] = operation
        }
        var output = Data(count: 80)
        var outputSize = 80
        let result = input.withUnsafeBytes { request in
            output.withUnsafeMutableBytes { response in
                IOConnectCallStructMethod(connection, 2, request.baseAddress, 80, response.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else { return nil }
        return output
    }

    static func decode(_ payload: Data, type: UInt32) -> Double? {
        let value: Double
        if type == code("flt "), payload.count >= 4 {
            let bits = payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            value = Double(Float(bitPattern: bits))
        } else if type == code("sp78"), payload.count >= 2 {
            value = Double(Int16(bitPattern: (UInt16(payload[0]) << 8) | UInt16(payload[1]))) / 256
        } else { return nil }
        return value.isFinite && value > 0 && value < 125 ? value : nil
    }

    func read() -> Double? {
#if APP_STORE
        return nil
#else
        if !attempted {
            attempted = true
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return nil }
            // A bounded set of CPU sensor keys across Intel / Apple Silicon.
            // Unsupported keys are discarded once; only discovered sensors are sampled.
            let keys = ["TC0P", "TC0D", "TC0E", "TC0F", "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp09", "Tp0D", "Tp0H", "Tp0L",
                        "Tp0P", "Tp0T", "Tp0b", "Tp01", "Tp05", "Te05", "Te0L", "Te01", "Te02"]
            for name in keys {
                let key = Self.code(name)
                guard let info = command(key: key, operation: 9) else { continue }
                let size = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
                let type = info.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self) }
                if (size == 4 && type == Self.code("flt ")) || (size == 2 && type == Self.code("sp78")) {
                    sensors.append((key, type, size))
                }
            }
        }
        return sensors.compactMap { sensor -> Double? in
            guard let response = command(key: sensor.key, operation: 5, size: sensor.size) else { return nil }
            return Self.decode(response.subdata(in: 48..<(48 + Int(sensor.size))), type: sensor.type)
        }.max()
#endif
    }
}

// Mutable state is confined to SystemStatusMonitor's serial utility queue.
private final class StatusSampler: @unchecked Sendable {
    let temperature = CPUTemperatureReader()
    let gpu = GPULoadReader()
    let ane = ANELoadReader()
    var cpu = CPULoadTracker()
    var network = NetworkRateTracker()
    var snapshot = SystemStatusSnapshot()
    var tick = 0
    func reset() {
        network.reset(); temperature.close(); cpu.reset(); gpu.close(); ane.close()
        tick = 0; snapshot = SystemStatusSnapshot()
    }
    func sample() -> SystemStatusSnapshot {
        let time = ProcessInfo.processInfo.systemUptime
        snapshot.cpu = cpu.update(CPUTicks.read(), at: time)
        snapshot.gpu = gpu.read()
        snapshot.ane = ane.read(at: time)
        snapshot.powerInput = PowerInputReader.read()
        let interfaces = LocalNetworkStatus.interfaces()
        snapshot.rate = network.update(interfaces?.physical, at: time)
        if tick % 3 == 0 {
            snapshot.temperature = temperature.read()
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: snapshot.thermal = "温况正常"
            case .fair: snapshot.thermal = "温况偏热"
            case .serious: snapshot.thermal = "温况较热"
            case .critical: snapshot.thermal = "温况过热"
            @unknown default: snapshot.thermal = "温况未知"
            }
            snapshot.connection = LocalNetworkStatus.connection(tunnel: interfaces?.tunnel ?? false)
        }
        tick += 1
        return snapshot
    }
}

@MainActor
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemStatusSnapshot()
    private let queue = DispatchQueue(label: "local.topshelf.status", qos: .utility)
    private let sampler = StatusSampler()
    private var timer: Timer?
    private var generation = 0
    private var visible = false
    private var sleeping = false
    private var sampling = false
    var isSampling: Bool { timer != nil }

    func setVisible(_ value: Bool) { visible = value; updateActivity() }
    func setSleeping(_ value: Bool) { sleeping = value; updateActivity() }
    private func updateActivity() {
        let active = visible && !sleeping
        guard active != (timer != nil) else { return }
        generation += 1
        timer?.invalidate(); timer = nil; sampling = false
        snapshot = SystemStatusSnapshot()
        queue.async { [sampler] in sampler.reset() }
        guard active else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func sample() {
        guard !sampling else { return }
        sampling = true
        let version = generation
        queue.async { [sampler, weak self] in
            let result = sampler.sample()
            Task { @MainActor [weak self] in
                guard let self, version == self.generation, self.visible, !self.sleeping else { return }
                self.sampling = false
                if self.snapshot != result { self.snapshot = result }
            }
        }
    }
    deinit { timer?.invalidate() }
}

struct SystemStatusStrip: View {
    @ObservedObject var monitor: SystemStatusMonitor
    var body: some View { SystemStatusReadout(status: monitor.snapshot) }
}

struct SystemStatusReadout: View {
    let status: SystemStatusSnapshot
    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(compact: false)
            content(compact: true)
            VStack(alignment: .leading, spacing: 4) {
                loads(compact: true)
                HStack(spacing: 8) {
                    environment(compact: true)
                    powerInput
                }
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                loads(compact: true)
                environment(compact: true)
                powerInput
            }.fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
    private func content(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            loads(compact: compact)
            environment(compact: compact)
            powerInput
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var powerInput: some View {
        reservedText(status.powerInput.title, sample: "输入 1000.0 W · 60.0 V", alignment: .leading)
            .help("充电口实际输入功率与输入电压，包含电脑运行及电池充电所需功率；不是充电器额定功率，也不是电池净充入功率。未接电源时不保留旧读数，— 表示系统未提供可用数据。")
    }
    // Only these fixed samples participate in layout. Live readings are overlays,
    // so ViewThatFits changes rows only when the available panel width changes.
    private func reservedText(_ value: String, sample: String, alignment: Alignment = .trailing) -> some View {
        Text(sample).hidden().fixedSize()
            .overlay(alignment: alignment) { Text(value).lineLimit(1).minimumScaleFactor(0.8) }
    }
    private func loads(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            load("CPU", value: status.cpu, symbol: "cpu", compact: compact)
                .help("全机 CPU 占用率：所有核心在最近采样间隔内的忙碌时间占比，范围 0–100%，不是拾屉自身的占用。刚展开时等待第二次采样。")
            load("GPU", value: status.gpu, symbol: "square.stack.3d.up", compact: compact)
                .help("GPU 驱动报告的设备占用率；多 GPU 时显示最高值。— 表示驱动未提供可用数据。")
            load("ANE", value: status.ane, symbol: "brain", compact: compact, approximate: true)
                .help("神经引擎：按系统计算负载档位及各档停留时间加权，≈ 表示近似值；不是功耗或通电时间。— 表示正在采样或本机系统未提供可用计数器。")
        }
    }
    private func load(_ title: String, value: Double?, symbol: String, compact: Bool, approximate: Bool = false) -> some View {
        HStack(spacing: 3) {
            if !compact { Image(systemName: symbol) }
            Text(title)
            reservedText((approximate && value != nil ? "≈" : "") + SystemStatusSnapshot.percent(value),
                         sample: approximate ? "≈100%" : "100%")
        }
    }
    private func environment(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            Label {
                reservedText(status.temperature.map { String(format: compact ? "%.0f°" : "%.0f°C", $0) } ?? (compact ? status.thermal.replacingOccurrences(of: "温况", with: "") : status.thermal),
                             sample: compact ? "125°" : "温况过热")
            } icon: { Image(systemName: "thermometer.medium") }
                .help("CPU 已识别传感器中的最高读数，非机身表面温度。温度读取不支持或不可用时，改显示系统温况等级。")
            HStack(spacing: 5) {
                Label {
                    reservedText(speed(status.rate?.download, compact: compact), sample: compact ? "1024.0M" : "1024.0 MB/s")
                } icon: { Image(systemName: "arrow.down") }
                Label {
                    reservedText(speed(status.rate?.upload, compact: compact), sample: compact ? "1024.0M" : "1024.0 MB/s")
                } icon: { Image(systemName: "arrow.up") }
            }.help("下载 / 上传：本机 Wi-Fi、以太网等 en 接口的总流量，包含局域网和所有应用；单位 KB/s、MB/s 按 1024 换算。不是网络带宽测速。")
            Group {
                if compact { Image(systemName: status.connection.symbol).frame(width: 14, height: 14) }
                else {
                    Label {
                        reservedText(status.connection.title, sample: "VPN 未检出", alignment: .leading)
                    } icon: { Image(systemName: status.connection.symbol).frame(width: 14, height: 14) }
                }
            }
            .foregroundStyle(status.connection == .vpn ? Color.green : (status.connection == .proxy || status.connection == .tunnel ? Color.orange : Color.secondary))
            .help(status.connection.title + "：" + status.connection.help)
            .accessibilityLabel(status.connection.title)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func speed(_ value: Double?, compact: Bool) -> String {
        let label = SystemStatusSnapshot.speed(value)
        return compact ? label.replacingOccurrences(of: " B/s", with: "B").replacingOccurrences(of: " KB/s", with: "K").replacingOccurrences(of: " MB/s", with: "M").replacingOccurrences(of: " GB/s", with: "G") : label
    }
}
