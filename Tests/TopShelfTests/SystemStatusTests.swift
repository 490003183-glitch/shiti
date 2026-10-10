import XCTest
import Darwin
import SwiftUI
@testable import TopShelf

final class SystemStatusTests: XCTestCase {
    @MainActor
    func testStatusReadoutKeepsItsSizeWhenLiveValuesChange() {
        let samples = [
            SystemStatusSnapshot(),
            SystemStatusSnapshot(cpu: 9, gpu: 9, ane: 9, temperature: 9,
                                 rate: .init(download: 9, upload: 9),
                                 powerInput: .init(connected: true, watts: 9.9, volts: 9.9), connection: .vpn),
            SystemStatusSnapshot(cpu: 100, gpu: 100, ane: 100, temperature: 124,
                                 rate: .init(download: 1023.99 * 1024 * 1024, upload: 1023.99 * 1024),
                                 powerInput: .init(connected: true, watts: 1000, volts: 60), connection: .connecting),
            SystemStatusSnapshot(thermal: "温况过热", rate: .init(download: 1024 * 1024, upload: 1024),
                                 powerInput: .init(connected: false), connection: .proxy)
        ]
        for width in [220.0, 280, 340, 400, 460, 520, 600, 800] {
            let sizes = samples.map { sample in
                NSHostingView(rootView: SystemStatusReadout(status: sample).frame(width: width)).fittingSize
            }
            for size in sizes.dropFirst() {
                XCTAssertEqual(size.width, sizes[0].width, accuracy: 0.5)
                XCTAssertEqual(size.height, sizes[0].height, accuracy: 0.5, "Readings changed row count at width \(width)")
            }
        }
    }

    func testPowerInputUsesMeasuredMilliunitsEvenWhenBatteryIsNotCharging() {
        let result = PowerInputReader.decode([
            "ExternalConnected": true, "IsCharging": false,
            "Voltage": 11057, "Amperage": -200,
            "AdapterDetails": ["Watts": 140, "AdapterVoltage": 28000],
            "PowerTelemetryData": ["SystemPowerIn": 13559, "SystemVoltageIn": 4665]
        ])
        XCTAssertEqual(result.watts, 13.559)
        XCTAssertEqual(result.volts, 4.665)
        XCTAssertEqual(result.title, "输入 13.6 W · 4.7 V")
    }

    func testPowerInputClearsDisconnectedTelemetryAndNeverSubstitutesRatedPower() {
        let telemetry = ["SystemPowerIn": 42000, "SystemVoltageIn": 20000]
        let disconnected = PowerInputReader.decode(["ExternalConnected": false, "PowerTelemetryData": telemetry])
        XCTAssertEqual(disconnected.title, "未接电源")
        XCTAssertNil(disconnected.watts)
        XCTAssertNil(disconnected.volts)
        let unsupported = PowerInputReader.decode([
            "ExternalConnected": true, "Voltage": 12000, "Amperage": 3000,
            "AdapterDetails": ["Watts": 96, "AdapterVoltage": 20000]
        ])
        XCTAssertEqual(unsupported.title, "输入 — W · — V")
        XCTAssertEqual(PowerInputReader.decode([:]), PowerInputSnapshot())
        XCTAssertNil(PowerInputReader.decode(["PowerTelemetryData": telemetry]).watts)
    }

    func testPowerInputRejectsInvalidTelemetryButKeepsRealZeroPowerAndPartialReadings() {
        for invalid in [NSNumber(value: true), NSNumber(value: -1), NSNumber(value: UInt64.max), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
            let result = PowerInputReader.decode([
                "ExternalConnected": true,
                "PowerTelemetryData": ["SystemPowerIn": invalid, "SystemVoltageIn": invalid]
            ])
            XCTAssertNil(result.watts)
            XCTAssertNil(result.volts)
        }
        let zero = PowerInputReader.decode(["ExternalConnected": true, "PowerTelemetryData": ["SystemPowerIn": 0, "SystemVoltageIn": 0]])
        XCTAssertEqual(zero.watts, 0)
        XCTAssertNil(zero.volts)
        let partial = PowerInputReader.decode(["ExternalConnected": true, "PowerTelemetryData": ["SystemVoltageIn": 20050]])
        XCTAssertNil(partial.watts)
        XCTAssertEqual(partial.volts, 20.05)
    }

    func testCPUIntervalNormalizedAcrossAllCoresAndRollover() {
        var cpu = CPULoadTracker()
        XCTAssertNil(cpu.update(.init(user: 100, system: 100, idle: 100, nice: 0), at: 1))
        XCTAssertEqual(cpu.update(.init(user: 120, system: 110, idle: 170, nice: 0), at: 3), 30)
        XCTAssertNil(cpu.update(.init(user: 120, system: 110, idle: 170, nice: 0), at: 5))
        cpu.reset()
        XCTAssertNil(cpu.update(.init(user: UInt32.max - 9, system: 0, idle: 0, nice: 0), at: 6))
        XCTAssertEqual(cpu.update(.init(user: 10, system: 0, idle: 80, nice: 0), at: 8), 20)
        XCTAssertNil(cpu.update(.init(user: 20, system: 0, idle: 90, nice: 0), at: 40))
        XCTAssertNil(cpu.update(nil, at: 42))
        XCTAssertNil(cpu.update(.init(user: 30, system: 0, idle: 100, nice: 0), at: 44))
    }

    func testANEDoesNotSubstitutePowerResidencyOrMissingSamplesForUtilization() {
        XCTAssertEqual(ANEHistogram.percentage([("0%", 50), ("50%", 30), ("100%", 20)]), 35)
        XCTAssertEqual(ANEHistogram.percentage([("0%", 100), ("100%", 0)]), 0)
        XCTAssertNil(ANEHistogram.percentage([("0%", 0), ("100%", 0)]))
        XCTAssertNil(ANEHistogram.percentage([("VMIN", 50), ("VMAX", 50)]))
        XCTAssertNil(ANEHistogram.percentage([("ACT", 100)]))
        XCTAssertNil(ANEHistogram.percentage([("101%", 100)]))
        XCTAssertNil(ANEHistogram.percentage([("50%", -1)]))
        XCTAssertNil(ANEHistogram.percentage([]))
    }

    func testGPURejectsInvalidDriverValues() {
        XCTAssertEqual(GPULoadReader.percentage(NSNumber(value: 0)), 0)
        XCTAssertEqual(GPULoadReader.percentage(NSNumber(value: 42)), 42)
        for value in [NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 101), NSNumber(value: Double.nan)] {
            XCTAssertNil(GPULoadReader.percentage(value))
        }
        XCTAssertNil(GPULoadReader.percentage(nil))
        XCTAssertEqual(SystemStatusSnapshot.percent(nil), "—")
        XCTAssertEqual(SystemStatusSnapshot.percent(0), "0%")
    }

    func testShortAddressRecordsDoNotHideSubsequentInterfaces() {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = 7
        var data = Data([8, 0, 5, UInt8(RTM_NEWADDR), 0, 0, 0, 0])
        data.append(Data(bytes: &header, count: MemoryLayout<if_msghdr2>.size))
        data.append(contentsOf: [2, 0, 5, 0]) // invalid length safely stops parsing
        let result = LocalNetworkStatus.interfaceRecords(in: data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.ifm_index, 7)
    }

    func testRateUsesElapsedTimeAndDoesNotDoubleCountOrSpikeOnInterfaceChanges() {
        var tracker = NetworkRateTracker()
        XCTAssertNil(tracker.update(["en0": .init(received: 100, sent: 100)], at: 10))
        XCTAssertEqual(tracker.update(["en0": .init(received: 1124, sent: 612)], at: 12), .init(download: 512, upload: 256))
        XCTAssertEqual(tracker.update(["en0": .init(received: 10, sent: 10), "en1": .init(received: 1_000_000, sent: 1_000_000)], at: 14), .init(download: 0, upload: 0))
        XCTAssertEqual(tracker.update(["en1": .init(received: 1_002_000, sent: 1_001_000)], at: 16), .init(download: 1000, upload: 500))
        XCTAssertNil(tracker.update([:], at: 40))
        XCTAssertNil(tracker.update(nil, at: 41))
        XCTAssertNil(tracker.update([:], at: 42))
        tracker.reset()
        XCTAssertNil(tracker.update([:], at: 43))
    }

    func testVPNDoesNotTreatTunnelOrProxyAsConfirmedConnection() {
        XCTAssertEqual(ConnectionIndicator.classify(connected: false, connecting: false, proxy: false, tunnel: true, readable: true), .tunnel)
        XCTAssertEqual(ConnectionIndicator.classify(connected: false, connecting: false, proxy: true, tunnel: true, readable: true), .proxy)
        XCTAssertEqual(ConnectionIndicator.classify(connected: true, connecting: false, proxy: true, tunnel: true, readable: true), .vpn)
        XCTAssertEqual(ConnectionIndicator.classify(connected: false, connecting: true, proxy: false, tunnel: false, readable: true), .connecting)
        XCTAssertEqual(ConnectionIndicator.classify(connected: false, connecting: false, proxy: false, tunnel: false, readable: true), .notDetected)
        XCTAssertEqual(ConnectionIndicator.classify(connected: false, connecting: false, proxy: false, tunnel: false, readable: false), .unavailable)
    }

    func testTemperatureParsesBothFormatsAndRejectsInvalidValues() {
        XCTAssertEqual(CPUTemperatureReader.decode(Data([42, 128]), type: CPUTemperatureReader.code("sp78")), 42.5)
        var bits = Float(51.25).bitPattern.littleEndian
        XCTAssertEqual(CPUTemperatureReader.decode(Data(bytes: &bits, count: 4), type: CPUTemperatureReader.code("flt ")), 51.25)
        for number in [Float.nan, Float.infinity, -1, 0, 200] {
            var bits = number.bitPattern.littleEndian
            XCTAssertNil(CPUTemperatureReader.decode(Data(bytes: &bits, count: 4), type: CPUTemperatureReader.code("flt ")))
        }
        XCTAssertNil(CPUTemperatureReader.decode(Data([255, 0]), type: CPUTemperatureReader.code("sp78")))
        XCTAssertNil(CPUTemperatureReader.decode(Data([0]), type: CPUTemperatureReader.code("flt ")))
    }

    func testUnknownSpeedAndUnitConversions() {
        XCTAssertEqual(SystemStatusSnapshot.speed(nil), "—")
        XCTAssertEqual(SystemStatusSnapshot.speed(.nan), "—")
        XCTAssertEqual(SystemStatusSnapshot.speed(0), "0 B/s")
        XCTAssertEqual(SystemStatusSnapshot.speed(1536), "1.5 KB/s")
        XCTAssertEqual(SystemStatusSnapshot.speed(2 * 1024 * 1024), "2.0 MB/s")
    }

    @MainActor
    func testPollingStopsWhenHiddenOrAsleepAndResumesOnlyWhenVisible() {
        let monitor = SystemStatusMonitor()
        XCTAssertFalse(monitor.isSampling)
        monitor.setVisible(true)
        XCTAssertTrue(monitor.isSampling)
        monitor.setSleeping(true)
        XCTAssertFalse(monitor.isSampling)
        monitor.setVisible(false)
        monitor.setSleeping(false)
        XCTAssertFalse(monitor.isSampling)
        monitor.setVisible(true)
        XCTAssertTrue(monitor.isSampling)
        monitor.setVisible(false)
        XCTAssertFalse(monitor.isSampling)
        XCTAssertNil(monitor.snapshot.rate)
        XCTAssertNil(monitor.snapshot.cpu)
        XCTAssertNil(monitor.snapshot.gpu)
        XCTAssertNil(monitor.snapshot.ane)
        XCTAssertEqual(monitor.snapshot.powerInput, PowerInputSnapshot())
    }
}
