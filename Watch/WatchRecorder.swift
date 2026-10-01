import CoreLocation
import CoreMotion
import HealthKit
import NearbyInteraction
import WatchConnectivity
import WatchKit

@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var eventCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var uwbStatus = "未启动"
    @Published private(set) var phoneReachable = false
    @Published private(set) var isControlPending = false
    @Published private(set) var controlStatus = "正在连接 iPhone"
    @Published private(set) var audioStatus = "未启动"

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let location = CLLocationManager()
    private let healthStore = HKHealthStore()
    private let audioCapture = AudioCapture()
    private let localEventSink = WatchEventSink()
    private var nearbySession: NISession?
    private var nearbyPeerTokenData: Data?
    private var nearbyRetryTimer: Timer?
    private var nearbyRestartTimer: Timer?
    private var nearbyHandshakeAttempt = 0
    private var nearbyHasRanged = false
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var sessionID = ""
    private var sessionFolderName = ""
    private var sequences: [String: UInt64] = [:]
    private var pendingEvents: [SensorEvent] = []
    private var flushTimer: Timer?
    private var batteryTimer: Timer?
    private var motionQueue: OperationQueue?
    private var rawMotionRetryTimer: Timer?
    private var rawMotionRetryCount = 0
    private var rawAccelerometerSamples = 0
    private var rawGyroscopeSamples = 0
    private var rawMagnetometerSamples = 0
    private var demoTimer: Timer?
    private var demoSample = 0
    private var pendingStartControlMessage: [String: Any]?
    private var controlRetryTimer: Timer?
    private var controlRetryAttempt = 0
    private var hasTransientConnectivityError = false
    private let pendingFileTransfersKey = "sensorread.pendingWatchFileTransfers.v1"
    private let didRegisterRecoveryFilesKey = "sensorread.didRegisterRecoveryFiles.v1"

    override init() {
        super.init()
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.headingFilter = kCLHeadingFilterNone
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        registerLatestSessionForRecoveryIfNeeded()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func start(sessionID: String, sessionFolderName: String? = nil,
               peerTokenData: Data? = nil,
               audioStartUnixS: TimeInterval? = nil) {
        guard !isRecording else { return }
        clearPendingStartControlRetry()
        self.sessionID = sessionID
        self.sessionFolderName = sessionFolderName ?? "session-\(sessionID.prefix(8))"
        sequences.removeAll(keepingCapacity: true)
        pendingEvents.removeAll(keepingCapacity: true)
        eventCount = 0
        lastError = nil
        do {
            try localEventSink.open(sessionID: sessionID,
                                    sessionFolderName: self.sessionFolderName)
        } catch {
            lastError = "无法创建手表本地事件文件：\(error.localizedDescription)"
        }
        isRecording = true
#if targetEnvironment(simulator)
        startSimulationFeed()
#else
        startWatchAudio(scheduledUnixTime: audioStartUnixS ?? Date().timeIntervalSince1970 + 0.2)
        requestHealthAndStartWorkout()
        startMotion()
        // Report availability after the first start attempt. A Watch can
        // expose device motion before its independent raw services become
        // ready, so startMotion() also performs delayed availability checks.
        emitCapabilities()
        startAltitude()
        startPedometer()
        startMotionActivity()
        startLocation()
        startBattery()
        startNearbyInteraction(peerTokenData: peerTokenData)
#endif
        flushTimer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    func stop() {
        guard isRecording else { return }
        clearPendingStartControlRetry()
        let audioURL = audioCapture.stop()
        audioStatus = "已停止"
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        motion.stopMagnetometerUpdates()
        motion.stopDeviceMotionUpdates()
        rawMotionRetryTimer?.invalidate()
        rawMotionRetryTimer = nil
        motionQueue = nil
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        nearbySession?.invalidate()
        nearbySession = nil
        nearbyPeerTokenData = nil
        nearbyRetryTimer?.invalidate()
        nearbyRetryTimer = nil
        nearbyRestartTimer?.invalidate()
        nearbyRestartTimer = nil
        nearbyHasRanged = false
        uwbStatus = "已停止"
        flushTimer?.invalidate()
        flushTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        demoTimer?.invalidate()
        demoTimer = nil
        send(sensor: "recording_end", values: ["completed": 1])
        // Mark sampling as stopped before the potentially slower flush,
        // close, and file-transfer work below. The UI and control reply can
        // respond immediately while files finish in the background.
        isRecording = false
        flush()
        workoutSession?.end()
        workoutSession = nil
        workoutBuilder = nil
        let eventURL = localEventSink.close()
        transferRecordingFile(eventURL, kind: "watch_events")
        transferRecordingFile(audioURL, kind: "watch_audio")
    }

    private func startWatchAudio(scheduledUnixTime: TimeInterval) {
        do {
            guard let directory = localEventSink.sessionDirectoryURL else {
                throw NSError(domain: "SensorRead.Storage", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "当前采集目录尚未创建"])
            }
            audioCapture.start(
                sessionID: sessionID,
                source: "apple_watch",
                directory: directory,
                scheduledUnixTime: scheduledUnixTime
            ) { [weak self] sensor, timestamp, values in
                self?.send(sensor: sensor, timestamp: timestamp, values: values)
            } onStatus: { [weak self] status in
                self?.audioStatus = status
            } onError: { [weak self] message in
                self?.lastError = message + "；其他传感器仍会继续采集。"
            }
        } catch {
            audioStatus = "无法创建音频目录"
            lastError = "无法创建手表音频文件：\(error.localizedDescription)"
        }
    }

    private func transferRecordingFile(_ url: URL?, kind: String) {
        guard let url, FileManager.default.fileExists(atPath: url.path), WCSession.isSupported() else { return }
        registerPendingTransfer(url)
        retryPendingFileTransfers()
    }

    private func registerPendingTransfer(_ url: URL) {
        let identifier = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        var pending = Set(UserDefaults.standard.stringArray(forKey: pendingFileTransfersKey) ?? [])
        pending.insert(identifier)
        UserDefaults.standard.set(Array(pending).sorted(), forKey: pendingFileTransfersKey)
    }

    private func acknowledgeTransferredFile(filename: String, folderName: String) {
        let identifier = "\(folderName)/\(filename)"
        var pending = Set(UserDefaults.standard.stringArray(forKey: pendingFileTransfersKey) ?? [])
        pending.remove(identifier)
        UserDefaults.standard.set(Array(pending).sorted(), forKey: pendingFileTransfersKey)
    }

    private func retryPendingFileTransfers() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let root = try? WatchEventSink.recordingsDirectory() else { return }
        let outstanding = Set(WCSession.default.outstandingFileTransfers.compactMap { transfer -> String? in
            guard let folder = transfer.file.metadata?["sessionFolderName"] as? String,
                  let filename = transfer.file.metadata?["filename"] as? String else { return nil }
            return "\(folder)/\(filename)"
        })
        let pending = UserDefaults.standard.stringArray(forKey: pendingFileTransfersKey) ?? []
        for identifier in pending where !outstanding.contains(identifier) {
            let components = identifier.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            let folder = components[0]
            let filename = components[1]
            let url = root.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let kind = filename.hasPrefix("apple_watch-audio-") ? "watch_audio" : "watch_events"
            let sessionID = filename
                .replacingOccurrences(of: "apple_watch-audio-", with: "")
                .replacingOccurrences(of: "apple_watch-events-", with: "")
                .replacingOccurrences(of: ".wav", with: "")
                .replacingOccurrences(of: ".ndjson", with: "")
            WCSession.default.transferFile(url, metadata: [
                "sessionID": sessionID,
                "sessionFolderName": folder,
                "kind": kind,
                "filename": filename
            ])
        }
    }

    /// One-time recovery for the newest session created before acknowledged
    /// transfers were introduced. This recovers files that the iPhone failed
    /// to copy because its WCSession temporary URL had already expired.
    private func registerLatestSessionForRecoveryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRegisterRecoveryFilesKey),
              let root = try? WatchEventSink.recordingsDirectory(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else { return }
        defaults.set(true, forKey: didRegisterRecoveryFilesKey)
        let latestDirectory = items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.max {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        guard let latestDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: latestDirectory,
                                                                        includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "wav" || file.pathExtension == "ndjson" {
            registerPendingTransfer(file)
        }
    }

    func requestSystemToggle() {
        guard !isControlPending else { return }
        let watchSession = WCSession.default
        phoneReachable = watchSession.isReachable
        let command = isRecording ? "stop" : "start"
        var message: [String: Any] = [
            "controlRequest": command,
            "controlRequestID": UUID().uuidString,
            "controlTimestamp": Date().timeIntervalSince1970,
            "controlMonotonic": ProcessInfo.processInfo.systemUptime
        ]
        if !sessionID.isEmpty { message["sessionID"] = sessionID }

        if command == "stop" {
            clearPendingStartControlRetry()
            // Stop the Watch side immediately. The iPhone still receives the
            // request below and stops its sensors independently.
            isControlPending = true
            controlStatus = "手表已停止，正在通知 iPhone…"
            if isRecording { stop() }
        }

        guard watchSession.activationState == .activated, watchSession.isReachable else {
            if command == "stop" {
                queueReliableStop(message, using: watchSession)
                return
            }
            queueStartControlRetry(message, resetAttempts: true)
            watchSession.activate()
            return
        }

        isControlPending = true
        controlStatus = command == "start" ? "正在启动全系统…" : "正在停止全系统…"
        watchSession.sendMessage(message) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isControlPending = false
                let accepted = reply["accepted"] as? Bool ?? false
                if accepted {
                    self.clearPendingStartControlRetry()
                    self.hasTransientConnectivityError = false
                    self.lastError = nil
                    self.reconcilePhoneState(from: reply)
                } else {
                    self.controlStatus = "iPhone 未执行命令"
                    self.lastError = reply["error"] as? String ?? "全系统控制失败"
                }
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if command == "stop" {
                    self.queueReliableStop(message, using: WCSession.default,
                                           immediateError: error)
                } else {
                    self.queueStartControlRetry(message, resetAttempts: true,
                                                immediateError: error)
                }
            }
        }
    }

    private func queueStartControlRetry(_ message: [String: Any], resetAttempts: Bool,
                                        immediateError: Error? = nil) {
        pendingStartControlMessage = message
        if resetAttempts { controlRetryAttempt = 0 }
        isControlPending = false
        phoneReachable = WCSession.default.isReachable
        controlStatus = "iPhone 暂不可达，正在自动重试"
        if let immediateError {
            hasTransientConnectivityError = true
            lastError = "即时连接中断，正在自动重试：\(immediateError.localizedDescription)"
        }
        if controlRetryTimer == nil {
            controlRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.retryPendingStartControl() }
            }
        }
        retryPendingStartControl()
    }

    private func retryPendingStartControl() {
        guard let message = pendingStartControlMessage, !isRecording, !isControlPending else {
            if isRecording { clearPendingStartControlRetry() }
            return
        }
        guard controlRetryAttempt < 15 else {
            controlRetryTimer?.invalidate()
            controlRetryTimer = nil
            controlStatus = "等待 iPhone 连接，可再次点击开始"
            hasTransientConnectivityError = true
            lastError = "自动重试暂未连接到 iPhone"
            return
        }
        let watchSession = WCSession.default
        guard watchSession.activationState == .activated, watchSession.isReachable else {
            watchSession.activate()
            return
        }
        controlRetryAttempt += 1
        isControlPending = true
        phoneReachable = true
        controlStatus = "正在重新发送开始命令…"
        watchSession.sendMessage(message) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.isControlPending = false
                if reply["accepted"] as? Bool == true {
                    self.clearPendingStartControlRetry()
                    self.hasTransientConnectivityError = false
                    self.lastError = nil
                    self.reconcilePhoneState(from: reply)
                } else {
                    self.controlStatus = "iPhone 未执行命令"
                    self.lastError = reply["error"] as? String ?? "全系统控制失败"
                }
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isControlPending = false
                self.phoneReachable = WCSession.default.isReachable
                self.controlStatus = "连接波动，继续自动重试"
                self.hasTransientConnectivityError = true
                self.lastError = "即时发送失败（第 \(self.controlRetryAttempt) 次）：\(error.localizedDescription)"
            }
        }
    }

    private func clearPendingStartControlRetry() {
        pendingStartControlMessage = nil
        controlRetryTimer?.invalidate()
        controlRetryTimer = nil
        controlRetryAttempt = 0
    }

    /// A stop request must never depend solely on the transient immediate
    /// messaging route. Stop the Watch now and enqueue the same command for
    /// guaranteed background delivery to the iPhone.
    private func queueReliableStop(_ message: [String: Any], using watchSession: WCSession,
                                   immediateError: Error? = nil) {
        watchSession.transferUserInfo(message)
        if isRecording { stop() }
        isControlPending = false
        phoneReachable = watchSession.isReachable
        controlStatus = "手表已停止，等待 iPhone 确认"
        if let immediateError {
            lastError = "即时连接中断，停止命令已排队：\(immediateError.localizedDescription)"
        } else {
            lastError = "iPhone 暂不可达；停止命令已排队，手表已停止"
        }
    }

    private func requestSystemStatus() {
        let watchSession = WCSession.default
        phoneReachable = watchSession.isReachable
        guard watchSession.activationState == .activated, watchSession.isReachable else {
            controlStatus = "等待 iPhone 连接"
            return
        }
        watchSession.sendMessage(["controlRequest": "status"]) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                self.reconcilePhoneState(from: reply)
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in
                self?.phoneReachable = WCSession.default.isReachable
                self?.controlStatus = "等待 iPhone 连接"
            }
        }
    }

    /// Treat the iPhone reply as the authoritative system state. The phone also
    /// sends a separate start/stop command, but that message may be delayed by
    /// WatchConnectivity. Reconciling here makes a Watch button press take
    /// effect locally as soon as the phone acknowledges it.
    private func reconcilePhoneState(from reply: [String: Any]) {
        let active = reply["isRecording"] as? Bool ?? false
        if active {
            guard let phoneSessionID = reply["sessionID"] as? String else {
                controlStatus = "iPhone 已启动，等待会话信息"
                return
            }
            let audioStartUnixS = reply["audioStartUnixS"] as? TimeInterval
            let folderName = reply["sessionFolderName"] as? String
            if !isRecording {
                start(sessionID: phoneSessionID, sessionFolderName: folderName,
                      audioStartUnixS: audioStartUnixS)
            } else if sessionID != phoneSessionID {
                stop()
                start(sessionID: phoneSessionID, sessionFolderName: folderName,
                      audioStartUnixS: audioStartUnixS)
            }
            controlStatus = "全系统采集中"
        } else {
            if isRecording { stop() }
            controlStatus = "已连接，可以开始"
        }
    }

    private func send(sensor: String, timestamp: TimeInterval? = nil,
                      monotonic: TimeInterval? = nil, values: [String: Double]) {
        guard isRecording else { return }
        let finiteValues = values.filter { $0.value.isFinite }
        guard !finiteValues.isEmpty else { return }
        let sequence = sequences[sensor, default: 0]
        sequences[sensor] = sequence + 1
        let monotonicTime = monotonic ?? ProcessInfo.processInfo.systemUptime
        let wallTime = timestamp ?? (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + monotonicTime)
        let event = SensorEvent(sessionID: sessionID, source: "apple_watch", sensor: sensor,
                                timestamp: wallTime, monotonic: monotonicTime,
                                sequenceNumber: sequence, values: finiteValues)
        pendingEvents.append(event)
        localEventSink.write(event)
        eventCount += 1
    }

    private func emitCapabilities() {
        send(sensor: "capabilities", values: [
            "accelerometer": motion.isAccelerometerAvailable ? 1 : 0,
            "gyroscope": motion.isGyroAvailable ? 1 : 0,
            "magnetometer": motion.isMagnetometerAvailable ? 1 : 0,
            "device_motion": motion.isDeviceMotionAvailable ? 1 : 0,
            "relative_altitude": CMAltimeter.isRelativeAltitudeAvailable() ? 1 : 0,
            "absolute_altitude": CMAltimeter.isAbsoluteAltitudeAvailable() ? 1 : 0,
            "pedometer": CMPedometer.isStepCountingAvailable() ? 1 : 0,
            "pedometer_distance": CMPedometer.isDistanceAvailable() ? 1 : 0,
            "pedometer_cadence": CMPedometer.isCadenceAvailable() ? 1 : 0,
            "pedometer_pace": CMPedometer.isPaceAvailable() ? 1 : 0,
            "floor_counting": CMPedometer.isFloorCountingAvailable() ? 1 : 0,
            "motion_activity": CMMotionActivityManager.isActivityAvailable() ? 1 : 0,
            "microphone_audio": 1,
            "heading": CLLocationManager.headingAvailable() ? 1 : 0,
            "health_data": HKHealthStore.isHealthDataAvailable() ? 1 : 0,
            "uwb_precise_distance": NISession.deviceCapabilities.supportsPreciseDistanceMeasurement ? 1 : 0
        ])
    }

    private func startMotion() {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        motionQueue = queue
        rawMotionRetryTimer?.invalidate()
        rawMotionRetryCount = 0
        rawAccelerometerSamples = 0
        rawGyroscopeSamples = 0
        rawMagnetometerSamples = 0
        motion.accelerometerUpdateInterval = 1.0 / 50.0
        motion.gyroUpdateInterval = 1.0 / 50.0
        motion.magnetometerUpdateInterval = 1.0 / 25.0
        motion.deviceMotionUpdateInterval = 1.0 / 50.0
        startAvailableMotionServices(on: queue)
        emitRawMotionStatus()

        // Some watchOS builds report the raw services as unavailable during
        // the first run-loop turn even though device motion is already live.
        // Retry for a short bounded period so a transient startup state does
        // not discard an entire session's raw gyro/magnetometer stream.
        rawMotionRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.rawMotionRetryCount += 1
                self.startAvailableMotionServices(on: queue)
                self.emitRawMotionStatus()
                if self.rawMotionRetryCount >= 8 ||
                    (self.rawGyroscopeSamples > 0 && self.rawMagnetometerSamples > 0) {
                    self.rawMotionRetryTimer?.invalidate()
                    self.rawMotionRetryTimer = nil
                }
            }
        }
    }

    private func startAvailableMotionServices(on queue: OperationQueue) {
        if motion.isAccelerometerAvailable {
            if !motion.isAccelerometerActive {
                motion.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        self?.rawAccelerometerSamples += 1
                        self?.send(sensor: "accelerometer", monotonic: data.timestamp, values: [
                            "x_g": data.acceleration.x, "y_g": data.acceleration.y, "z_g": data.acceleration.z])
                    }
                }
            }
        }
        if motion.isGyroAvailable {
            if !motion.isGyroActive {
                motion.startGyroUpdates(to: queue) { [weak self] data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        self?.rawGyroscopeSamples += 1
                        self?.send(sensor: "gyroscope", monotonic: data.timestamp, values: [
                            "x_rad_s": data.rotationRate.x, "y_rad_s": data.rotationRate.y,
                            "z_rad_s": data.rotationRate.z])
                    }
                }
            }
        }
        if motion.isMagnetometerAvailable {
            if !motion.isMagnetometerActive {
                motion.startMagnetometerUpdates(to: queue) { [weak self] data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        self?.rawMagnetometerSamples += 1
                        self?.send(sensor: "magnetometer", monotonic: data.timestamp, values: [
                            "x_uT": data.magneticField.x, "y_uT": data.magneticField.y,
                            "z_uT": data.magneticField.z])
                    }
                }
            }
        }
        if motion.isDeviceMotionAvailable {
            if !motion.isDeviceMotionActive {
                motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] data, _ in
                    guard let data else { return }
                    Task { @MainActor in self?.send(sensor: "device_motion", monotonic: data.timestamp,
                                                     values: Self.deviceMotionValues(data)) }
                }
            }
        }
    }

    private func emitRawMotionStatus() {
        send(sensor: "raw_motion_status", values: [
            "accelerometer_available": motion.isAccelerometerAvailable ? 1 : 0,
            "gyroscope_available": motion.isGyroAvailable ? 1 : 0,
            "magnetometer_available": motion.isMagnetometerAvailable ? 1 : 0,
            "device_motion_available": motion.isDeviceMotionAvailable ? 1 : 0,
            "accelerometer_active": motion.isAccelerometerActive ? 1 : 0,
            "gyroscope_active": motion.isGyroActive ? 1 : 0,
            "magnetometer_active": motion.isMagnetometerActive ? 1 : 0,
            "device_motion_active": motion.isDeviceMotionActive ? 1 : 0,
            "accelerometer_samples": Double(rawAccelerometerSamples),
            "gyroscope_samples": Double(rawGyroscopeSamples),
            "magnetometer_samples": Double(rawMagnetometerSamples),
            "retry_count": Double(rawMotionRetryCount)
        ])
    }

    private static func deviceMotionValues(_ data: CMDeviceMotion) -> [String: Double] {
        let attitude = data.attitude
        let quaternion = attitude.quaternion
        let matrix = attitude.rotationMatrix
        return [
            "attitude_roll": attitude.roll, "attitude_pitch": attitude.pitch, "attitude_yaw": attitude.yaw,
            "quaternion_x": quaternion.x, "quaternion_y": quaternion.y,
            "quaternion_z": quaternion.z, "quaternion_w": quaternion.w,
            "rotation_m11": matrix.m11, "rotation_m12": matrix.m12, "rotation_m13": matrix.m13,
            "rotation_m21": matrix.m21, "rotation_m22": matrix.m22, "rotation_m23": matrix.m23,
            "rotation_m31": matrix.m31, "rotation_m32": matrix.m32, "rotation_m33": matrix.m33,
            "gravity_x": data.gravity.x, "gravity_y": data.gravity.y, "gravity_z": data.gravity.z,
            "user_accel_x_g": data.userAcceleration.x, "user_accel_y_g": data.userAcceleration.y,
            "user_accel_z_g": data.userAcceleration.z,
            "rotation_x_rad_s": data.rotationRate.x, "rotation_y_rad_s": data.rotationRate.y,
            "rotation_z_rad_s": data.rotationRate.z,
            "magnetic_x_uT": data.magneticField.field.x, "magnetic_y_uT": data.magneticField.field.y,
            "magnetic_z_uT": data.magneticField.field.z,
            "magnetic_accuracy": Double(data.magneticField.accuracy.rawValue),
            "heading_deg": data.heading,
            "sensor_location": Double(data.sensorLocation.rawValue)
        ]
    }

    private func startAltitude() {
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                self?.send(sensor: "barometer", monotonic: data.timestamp, values: [
                    "relative_altitude_m": data.relativeAltitude.doubleValue,
                    "pressure_kPa": data.pressure.doubleValue
                ])
            }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                self?.send(sensor: "absolute_altitude", monotonic: data.timestamp, values: [
                    "altitude_m": data.altitude, "accuracy_m": data.accuracy,
                    "precision_m": data.precision
                ])
            }
        }
    }

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            if let error {
                Task { @MainActor in self?.lastError = "计步器错误：\(error.localizedDescription)" }
                return
            }
            guard let data else { return }
            var values: [String: Double] = ["steps": data.numberOfSteps.doubleValue]
            values["distance_m"] = data.distance?.doubleValue
            values["average_active_pace_s_m"] = data.averageActivePace?.doubleValue
            values["current_pace_s_m"] = data.currentPace?.doubleValue
            values["cadence_steps_s"] = data.currentCadence?.doubleValue
            values["floors_ascended"] = data.floorsAscended?.doubleValue
            values["floors_descended"] = data.floorsDescended?.doubleValue
            Task { @MainActor in self?.send(sensor: "pedometer",
                                             timestamp: data.endDate.timeIntervalSince1970, values: values) }
        }
    }

    private func startMotionActivity() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            self?.send(sensor: "motion_activity", timestamp: activity.startDate.timeIntervalSince1970, values: [
                "stationary": activity.stationary ? 1 : 0,
                "walking": activity.walking ? 1 : 0,
                "running": activity.running ? 1 : 0,
                "automotive": activity.automotive ? 1 : 0,
                "cycling": activity.cycling ? 1 : 0,
                "unknown": activity.unknown ? 1 : 0,
                "confidence": Double(activity.confidence.rawValue)
            ])
        }
    }

    private func startLocation() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: location.startUpdatingLocation()
        default: break
        }
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
    }

    private func startBattery() {
        emitBattery()
        batteryTimer = .scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitBattery() }
        }
    }

    private func emitBattery() {
        send(sensor: "battery", values: [
            "level": Double(WKInterfaceDevice.current().batteryLevel),
            "state": Double(WKInterfaceDevice.current().batteryState.rawValue)
        ])
    }

    private func requestHealthAndStartWorkout() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let identifiers: [HKQuantityTypeIdentifier] = [
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .stepCount,
            .walkingSpeed, .walkingStepLength, .walkingAsymmetryPercentage,
            .walkingDoubleSupportPercentage, .stairAscentSpeed, .stairDescentSpeed,
            .runningSpeed, .runningPower, .runningVerticalOscillation,
            .runningGroundContactTime, .runningStrideLength
        ]
        let readTypes = Set(identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: readTypes) { [weak self] granted, error in
            Task { @MainActor in
                if let error { self?.lastError = "健康权限错误：\(error.localizedDescription)" }
                if granted { self?.startWorkout() }
            }
        }
    }

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            session.delegate = self
            builder.delegate = self
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            workoutSession = session
            workoutBuilder = builder
            let start = Date()
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in }
        } catch {
            lastError = "无法启动手表运动会话：\(error.localizedDescription)"
        }
    }

    private func startNearbyInteraction(peerTokenData: Data?) {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            uwbStatus = "此手表不支持 UWB 精确测距"
            send(sensor: "uwb_status", values: ["stage": 1])
            return
        }
        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        nearbySession = session
        nearbyPeerTokenData = nil
        nearbyHandshakeAttempt = 0
        nearbyHasRanged = false
        uwbStatus = "等待 iPhone"
        send(sensor: "uwb_status", values: ["stage": 10])
        nearbyRetryTimer?.invalidate()
        nearbyRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendNearbyHandshake() }
        }
        sendNearbyHandshake()
        if let peerTokenData { runNearbyInteraction(peerTokenData: peerTokenData) }
    }

    private func restartNearbyInteraction(after delay: TimeInterval = 0.8,
                                          reasonCode: Double) {
        guard isRecording else { return }
        nearbyRestartTimer?.invalidate()
        nearbyRestartTimer = .scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.nearbyRetryTimer?.invalidate()
                self.nearbyRetryTimer = nil
                self.nearbySession?.delegate = nil
                self.nearbySession?.invalidate()
                self.nearbySession = nil
                self.nearbyPeerTokenData = nil
                self.nearbyHasRanged = false
                self.nearbyHandshakeAttempt = 0
                self.uwbStatus = "UWB 正在自动重连"
                self.send(sensor: "uwb_status", values: [
                    "stage": 91, "reason": reasonCode
                ])
                self.startNearbyInteraction(peerTokenData: nil)
            }
        }
    }

    private func runNearbyInteraction(peerTokenData: Data, force: Bool = false) {
        if !force, peerTokenData == nearbyPeerTokenData {
            // The phone retries its start token until it receives ours. Reply again,
            // but do not restart an already-running Nearby Interaction session.
            sendNearbyHandshake()
            return
        }
        guard let session = nearbySession,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self,
                                                                  from: peerTokenData) else {
            uwbStatus = "iPhone UWB 令牌无效"
            send(sensor: "uwb_status", values: ["stage": 31])
            return
        }
        nearbyPeerTokenData = peerTokenData
        uwbStatus = "已收到 iPhone 令牌，正在测距"
        send(sensor: "uwb_status", values: ["stage": 30])
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        // Standard ranging avoids an iOS/watchOS 26 extended-ranging failure
        // affecting phone-watch pairs with second-generation UWB chips.
        session.run(configuration)
        send(sensor: "uwb_status", values: ["stage": 40])
        sendNearbyHandshake()
    }

    private func sendNearbyHandshake() {
        guard isRecording, !nearbyHasRanged,
              let token = nearbySession?.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(
                withRootObject: token, requiringSecureCoding: true) else { return }
        if nearbyHandshakeAttempt >= 15, WCSession.default.isReachable {
            restartNearbyInteraction(reasonCode: 2)
            return
        }
        nearbyHandshakeAttempt += 1
        let message: [String: Any] = [
            "nearbyToken": data,
            "sessionID": sessionID,
            "uwbHandshake": true,
            "handshakeAttempt": nearbyHandshakeAttempt
        ]
        send(sensor: "uwb_status", values: [
            "stage": 20, "attempt": Double(nearbyHandshakeAttempt),
            "phone_reachable": WCSession.default.isReachable ? 1 : 0
        ])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { failedMessage in
                WCSession.default.transferUserInfo(message)
                Task { @MainActor [weak self] in
                    self?.send(sensor: "uwb_status", values: [
                        "stage": 21,
                        "error_code": Double((failedMessage as NSError).code)
                    ])
                }
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

#if targetEnvironment(simulator)
    private func startSimulationFeed() {
        demoSample = 0
        demoTimer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.demoSample += 1
                let t = Double(self.demoSample) * 0.05
                self.send(sensor: "accelerometer", values: [
                    "x_g": sin(t * 1.1) * 0.18, "y_g": cos(t * 0.8) * 0.12,
                    "z_g": 1.0 + sin(t * 1.7) * 0.04
                ])
                self.send(sensor: "gyroscope", values: [
                    "x_rad_s": cos(t) * 0.3, "y_rad_s": sin(t * 0.7) * 0.2,
                    "z_rad_s": cos(t * 0.4) * 0.15
                ])
                if self.demoSample.isMultiple(of: 20) {
                    self.send(sensor: "heart_rate", values: ["bpm": 72 + sin(t * 0.2) * 8])
                }
            }
        }
    }
#endif

    private func flush() {
        while !pendingEvents.isEmpty {
            let count = min(25, pendingEvents.count)
            let batch = Array(pendingEvents.prefix(count))
            pendingEvents.removeFirst(count)
            guard let data = try? JSONEncoder().encode(batch) else { continue }
            let message: [String: Any] = ["events": data]
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                    WCSession.default.transferUserInfo(message)
                }
            } else {
                WCSession.default.transferUserInfo(message)
            }
        }
    }
}

extension WatchRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        var values: [String: Double] = [
            "latitude_deg": location.coordinate.latitude,
            "longitude_deg": location.coordinate.longitude,
            "altitude_m": location.altitude,
            "ellipsoidal_altitude_m": location.ellipsoidalAltitude,
            "horizontal_accuracy_m": location.horizontalAccuracy,
            "vertical_accuracy_m": location.verticalAccuracy,
            "speed_m_s": location.speed,
            "speed_accuracy_m_s": location.speedAccuracy,
            "course_deg": location.course,
            "course_accuracy_deg": location.courseAccuracy
        ]
        values["floor"] = location.floor.map { Double($0.level) }
        Task { @MainActor in
            send(sensor: "location", timestamp: location.timestamp.timeIntervalSince1970, values: values)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        Task { @MainActor in
            send(sensor: "heading", timestamp: heading.timestamp.timeIntervalSince1970, values: [
                "magnetic_heading_deg": heading.magneticHeading,
                "true_heading_deg": heading.trueHeading,
                "heading_accuracy_deg": heading.headingAccuracy,
                "raw_x_uT": heading.x, "raw_y_uT": heading.y, "raw_z_uT": heading.z
            ])
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if isRecording, manager.authorizationStatus == .authorizedAlways ||
                manager.authorizationStatus == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }
}

extension WatchRecorder: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first, let distance = object.distance else { return }
        Task { @MainActor in
            if !nearbyHasRanged {
                nearbyHasRanged = true
                nearbyRetryTimer?.invalidate()
                nearbyRetryTimer = nil
                uwbStatus = "UWB 测距中"
                send(sensor: "uwb_status", values: ["stage": 50])
            }
            send(sensor: "uwb_ranging", values: ["distance_m": Double(distance)])
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor in
            if isRecording, session === nearbySession {
                let nsError = error as NSError
                uwbStatus = "UWB 会话失效，正在重连"
                send(sensor: "uwb_status", values: [
                    "stage": 90, "error_code": Double(nsError.code)
                ])
                nearbySession = nil
                nearbyPeerTokenData = nil
                nearbyHasRanged = false
                restartNearbyInteraction(reasonCode: Double(nsError.code))
            }
        }
    }

    nonisolated func sessionWasSuspended(_ session: NISession) {
        Task { @MainActor in
            uwbStatus = "UWB 已暂停"
            send(sensor: "uwb_status", values: ["stage": 60])
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            guard isRecording, session === nearbySession else { return }
            uwbStatus = "UWB 正在恢复"
            send(sensor: "uwb_status", values: ["stage": 70])
            if let nearbyPeerTokenData { runNearbyInteraction(peerTokenData: nearbyPeerTokenData, force: true) }
            sendNearbyHandshake()
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                             reason: NINearbyObject.RemovalReason) {
        Task { @MainActor in
            nearbyHasRanged = false
            uwbStatus = "UWB 目标丢失，正在重连"
            send(sensor: "uwb_status", values: [
                "stage": 80, "reason": Double(reason.rawValue)
            ])
            if nearbyRetryTimer == nil {
                nearbyRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sendNearbyHandshake() }
                }
            }
            sendNearbyHandshake()
        }
    }
}

extension WatchRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            phoneReachable = session.isReachable
            if let error {
                controlStatus = "iPhone 连接失败"
                hasTransientConnectivityError = true
                lastError = error.localizedDescription
            } else {
                retryPendingFileTransfers()
                if let pendingStartControlMessage, controlRetryTimer == nil {
                    queueStartControlRetry(pendingStartControlMessage, resetAttempts: true)
                } else {
                    retryPendingStartControl()
                }
                requestSystemStatus()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            phoneReachable = session.isReachable
            if session.isReachable {
                if hasTransientConnectivityError {
                    hasTransientConnectivityError = false
                    lastError = nil
                }
                retryPendingFileTransfers()
                if let pendingStartControlMessage, controlRetryTimer == nil {
                    queueStartControlRetry(pendingStartControlMessage, resetAttempts: true)
                } else {
                    retryPendingStartControl()
                }
                requestSystemStatus()
                if isRecording, nearbySession == nil {
                    restartNearbyInteraction(after: 0.1, reasonCode: 3)
                } else if isRecording, !nearbyHasRanged {
                    if nearbyRetryTimer == nil {
                        nearbyRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                            Task { @MainActor in self?.sendNearbyHandshake() }
                        }
                    }
                    sendNearbyHandshake()
                }
            }
            else { controlStatus = "等待 iPhone 连接" }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receivePhoneMessage(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receivePhoneMessage(userInfo)
    }

    nonisolated private func receivePhoneMessage(_ message: [String: Any]) {
        if let filename = message["watchFileReceived"] as? String {
            let folderName = message["sessionFolderName"] as? String ?? ""
            Task { @MainActor in
                acknowledgeTransferredFile(filename: filename, folderName: folderName)
            }
            return
        }
        guard let receivedSessionID = message["sessionID"] as? String else { return }
        let token = message["nearbyToken"] as? Data
        let command = message["command"] as? String
        let audioStartUnixS = message["audioStartUnixS"] as? TimeInterval
        let folderName = message["sessionFolderName"] as? String
        Task { @MainActor in
            if command == "stop" {
                if !isRecording || receivedSessionID == sessionID { stop() }
                isControlPending = false
                controlStatus = "全系统已停止"
                return
            }
            if command == "start", !isRecording {
                start(sessionID: receivedSessionID, sessionFolderName: folderName,
                      peerTokenData: token,
                      audioStartUnixS: audioStartUnixS)
                isControlPending = false
                controlStatus = "全系统采集中"
                return
            }
            guard isRecording, receivedSessionID == sessionID else { return }
            if let token { runNearbyInteraction(peerTokenData: token) }
        }
    }
}

extension WatchRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in lastError = "运动会话错误：\(error.localizedDescription)" }
    }
}

extension WatchRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                   didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for sampleType in collectedTypes {
            guard let type = sampleType as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: type) else { continue }
            let identifier = type.identifier
            let mapping: (sensor: String, field: String, unit: HKUnit, cumulative: Bool)?
            switch identifier {
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                mapping = ("heart_rate", "bpm", HKUnit.count().unitDivided(by: .minute()), false)
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
                mapping = ("active_energy", "kilocalories", .kilocalorie(), true)
            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                mapping = ("workout_distance", "distance_m", .meter(), true)
            case HKQuantityTypeIdentifier.stepCount.rawValue:
                mapping = ("workout_steps", "steps", .count(), true)
            case HKQuantityTypeIdentifier.walkingSpeed.rawValue:
                mapping = ("walking_speed", "speed_m_s", .meter().unitDivided(by: .second()), false)
            case HKQuantityTypeIdentifier.walkingStepLength.rawValue:
                mapping = ("walking_step_length", "length_m", .meter(), false)
            case HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue:
                mapping = ("walking_asymmetry", "percent", .percent(), false)
            case HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue:
                mapping = ("walking_double_support", "percent", .percent(), false)
            case HKQuantityTypeIdentifier.stairAscentSpeed.rawValue:
                mapping = ("stair_ascent_speed", "speed_m_s", .meter().unitDivided(by: .second()), false)
            case HKQuantityTypeIdentifier.stairDescentSpeed.rawValue:
                mapping = ("stair_descent_speed", "speed_m_s", .meter().unitDivided(by: .second()), false)
            case HKQuantityTypeIdentifier.runningSpeed.rawValue:
                mapping = ("running_speed", "speed_m_s", .meter().unitDivided(by: .second()), false)
            case HKQuantityTypeIdentifier.runningPower.rawValue:
                mapping = ("running_power", "watts", .watt(), false)
            case HKQuantityTypeIdentifier.runningVerticalOscillation.rawValue:
                mapping = ("running_vertical_oscillation", "distance_m", .meter(), false)
            case HKQuantityTypeIdentifier.runningGroundContactTime.rawValue:
                mapping = ("running_ground_contact", "duration_s", .second(), false)
            case HKQuantityTypeIdentifier.runningStrideLength.rawValue:
                mapping = ("running_stride_length", "length_m", .meter(), false)
            default:
                mapping = nil
            }
            guard let mapping else { continue }
            let quantity = mapping.cumulative ? statistics.sumQuantity() : statistics.mostRecentQuantity()
            guard let quantity else { continue }
            let value = quantity.doubleValue(for: mapping.unit)
            Task { @MainActor in send(sensor: mapping.sensor, values: [mapping.field: value]) }
        }
    }
}
