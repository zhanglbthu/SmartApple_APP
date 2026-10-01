import ARKit
import CoreLocation
import CoreMotion
import NearbyInteraction
import UIKit
import WatchConnectivity

@MainActor
final class SensorRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var eventCount = 0
    @Published private(set) var currentFilename: String?
    @Published private(set) var lastError: String?
    @Published private(set) var uwbStatus = "未启动"
    @Published private(set) var headphoneStatus = "未启动"
    @Published private(set) var audioStatus = "未启动"

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let headphoneMotion = CMHeadphoneMotionManager()
    private let location = CLLocationManager()
    private let sink = EventSink()
    private let audioCapture = AudioCapture()
    private var headphoneActivityManager: AnyObject?
    private var nearbySession: NISession?
    private var nearbyPeerTokenData: Data?
    private var nearbyRetryTimer: Timer?
    private var nearbyRestartTimer: Timer?
    private var nearbyHandshakeAttempt = 0
    private var nearbyHasRanged = false
    private var arSession: ARSession?
    private var lastBodyFrameTime: TimeInterval = 0
    private var sessionID = ""
    private var sessionFolderName = ""
    private var sessionStartDate: Date?
    private var synchronizedAudioStartUnixS: TimeInterval = 0
    private var sessionUDPEnabled = false
    private var sequences: [String: UInt64] = [:]
    private var batteryTimer: Timer?
    private var headphoneRetryTimer: Timer?
    private var headphoneLastSampleTime: TimeInterval?
    private var headphoneHasReceivedSample = false
    private var motionQueue: OperationQueue?
    private var rawMotionRetryTimer: Timer?
    private var rawMotionRetryCount = 0
    private var rawAccelerometerSamples = 0
    private var rawGyroscopeSamples = 0
    private var rawMagnetometerSamples = 0
    private var demoTimer: Timer?
    private var demoSample = 0
    private var proximityObserver: NSObjectProtocol?
    private var orientationObserver: NSObjectProtocol?

    override init() {
        super.init()
        location.delegate = self
        location.activityType = .fitness
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.distanceFilter = kCLDistanceFilterNone
        location.headingFilter = kCLHeadingFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        headphoneMotion.delegate = self
        UIDevice.current.isBatteryMonitoringEnabled = true
        activateWatchSession()
    }

    func start(host: String, port: UInt16, enableBodyTracking: Bool = false,
               enableUDP: Bool = false) {
        guard !isRecording else { return }
        lastError = nil
        sessionID = UUID().uuidString
        let startDate = Date()
        sessionStartDate = startDate
        sessionFolderName = Self.makeSessionFolderName(date: startDate, sessionID: sessionID)
        synchronizedAudioStartUnixS = startDate.timeIntervalSince1970 + 1.5
        sessionUDPEnabled = enableUDP
        sequences.removeAll(keepingCapacity: true)
        do {
            try sink.open(sessionID: sessionID, sessionFolderName: sessionFolderName,
                          host: host, port: port, enableUDP: enableUDP)
        } catch {
            lastError = "无法创建采集文件：\(error.localizedDescription)"
            return
        }
        currentFilename = sessionFolderName
        writeSessionManifest(endDate: nil)
        eventCount = 0
        isRecording = true
#if targetEnvironment(simulator)
        startSimulationFeed()
#else
        startPhoneAudio(scheduledUnixTime: synchronizedAudioStartUnixS)
        startPhoneMotion()
        // Report capabilities after the first start attempt. The raw motion
        // services also perform bounded delayed retries and emit diagnostics.
        emitCapabilities(bodyTrackingRequested: enableBodyTracking)
        startAltitude()
        startPedometer()
        startMotionActivity()
        startLocation()
        startHeadphoneServices()
        startHeadphoneActivity()
        startDeviceState()
        startNearbyInteraction()
        if enableBodyTracking { startBodyTracking() }
#endif
        sendWatchCommand("start", sessionID: sessionID)
    }

    func stop() {
        guard isRecording else { return }
        audioCapture.stop()
        audioStatus = "已停止"
        // Stop producing new samples before the slower event-file drain and
        // close work. UI and remote control can acknowledge the stopped state
        // without waiting for the whole file to finalize.
        isRecording = false
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
        headphoneMotion.stopDeviceMotionUpdates()
        headphoneMotion.stopConnectionStatusUpdates()
        headphoneRetryTimer?.invalidate()
        headphoneRetryTimer = nil
        headphoneLastSampleTime = nil
        headphoneHasReceivedSample = false
        headphoneStatus = "已停止"
        if #available(iOS 18.0, *), let manager = headphoneActivityManager as? CMHeadphoneActivityManager {
            manager.stopActivityUpdates()
            manager.stopStatusUpdates()
        }
        headphoneActivityManager = nil
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
        arSession?.pause()
        arSession = nil
        stopDeviceState()
        batteryTimer?.invalidate()
        batteryTimer = nil
        demoTimer?.invalidate()
        demoTimer = nil
        sendWatchCommand("stop", sessionID: sessionID)
        let controlKey = "iphone/recording_end"
        let controlSequence = sequences[controlKey, default: 0]
        sequences[controlKey] = controlSequence + 1
        let endEvent = SensorEvent(
            sessionID: sessionID,
            source: "iphone",
            sensor: "recording_end",
            sequenceNumber: controlSequence,
            values: ["completed": 1]
        )
        eventCount += 1
        // Persist one authoritative marker and repeat it only on UDP. The
        // receiver de-duplicates by sessionID and treats this explicit marker,
        // never a silent network timeout, as permission to save the sequence.
        sink.close(finalEvent: endEvent, udpRepetitions: 5)
        writeSessionManifest(endDate: Date())
    }

    private func startPhoneAudio(scheduledUnixTime: TimeInterval) {
        do {
            guard let directory = sink.sessionDirectoryURL else {
                throw NSError(domain: "SensorRead.Storage", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "当前采集目录尚未创建"])
            }
            audioCapture.start(
                sessionID: sessionID,
                source: "iphone",
                directory: directory,
                scheduledUnixTime: scheduledUnixTime
            ) { [weak self] sensor, timestamp, values in
                self?.emit(source: "iphone", sensor: sensor, timestamp: timestamp, values: values)
            } onStatus: { [weak self] status in
                self?.audioStatus = status
            } onError: { [weak self] message in
                self?.lastError = message + "；其他传感器仍会继续采集。"
            }
        } catch {
            audioStatus = "无法创建音频目录"
            lastError = "无法创建音频文件：\(error.localizedDescription)"
        }
    }

    private func startFromWatchControl() {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "receiverIP") ?? "192.168.1.100"
        let portValue = (defaults.object(forKey: "receiverPort") as? NSNumber)?.intValue ?? 9000
        let port = UInt16(clamping: portValue)
        let enableBodyTracking = defaults.bool(forKey: "enableBodyTracking")
        start(host: host, port: port, enableBodyTracking: enableBodyTracking,
              enableUDP: defaults.bool(forKey: "enableUDP"))
    }

    private func emitWatchControlEvent(command: String, timestamp: TimeInterval?,
                                       monotonic: TimeInterval?, wasRecording: Bool,
                                       accepted: Bool) {
        emit(source: "apple_watch", sensor: "control_event", timestamp: timestamp,
             monotonic: monotonic, values: [
                "action_start": command == "start" ? 1 : 0,
                "action_stop": command == "stop" ? 1 : 0,
                "accepted": accepted ? 1 : 0,
                "phone_was_recording": wasRecording ? 1 : 0
             ])
    }

    private func emit(source: String, sensor: String, timestamp: TimeInterval? = nil,
                      monotonic: TimeInterval? = nil, values: [String: Double]) {
        guard isRecording else { return }
        let finiteValues = values.filter { $0.value.isFinite }
        guard !finiteValues.isEmpty else { return }
        let key = "\(source)/\(sensor)"
        let sequence = sequences[key, default: 0]
        sequences[key] = sequence + 1
        let monotonicTime = monotonic ?? ProcessInfo.processInfo.systemUptime
        let wallTime = timestamp ?? (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime + monotonicTime)
        let event = SensorEvent(sessionID: sessionID, source: source, sensor: sensor,
                                timestamp: wallTime, monotonic: monotonicTime,
                                sequenceNumber: sequence, values: finiteValues)
        sink.write(event)
        eventCount += 1
    }

    private func emitCapabilities(bodyTrackingRequested: Bool) {
        var values: [String: Double] = [
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
            "heading": CLLocationManager.headingAvailable() ? 1 : 0,
            "headphone_motion": headphoneMotion.isDeviceMotionAvailable ? 1 : 0,
            "body_tracking_supported": ARBodyTrackingConfiguration.isSupported ? 1 : 0,
            "body_tracking_requested": bodyTrackingRequested ? 1 : 0,
            "microphone_audio": 1,
            "uwb_precise_distance": NISession.deviceCapabilities.supportsPreciseDistanceMeasurement ? 1 : 0,
            "uwb_direction": NISession.deviceCapabilities.supportsDirectionMeasurement ? 1 : 0
        ]
        if #available(iOS 18.0, *) {
            let manager = CMHeadphoneActivityManager()
            values["headphone_activity"] = manager.isActivityAvailable ? 1 : 0
            values["headphone_status"] = manager.isStatusAvailable ? 1 : 0
        }
        emit(source: "iphone", sensor: "capabilities", values: values)
    }

    private func startPhoneMotion() {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        motionQueue = queue
        rawMotionRetryTimer?.invalidate()
        rawMotionRetryCount = 0
        rawAccelerometerSamples = 0
        rawGyroscopeSamples = 0
        rawMagnetometerSamples = 0
        motion.accelerometerUpdateInterval = 1.0 / 100.0
        motion.gyroUpdateInterval = 1.0 / 100.0
        motion.magnetometerUpdateInterval = 1.0 / 50.0
        motion.deviceMotionUpdateInterval = 1.0 / 100.0

        startAvailablePhoneMotionServices(on: queue)
        emitRawMotionStatus()

        // A transient startup state can report a raw service as unavailable
        // for the first run-loop turn. Retry briefly so one session does not
        // lose its standalone gyro/magnetometer stream unnecessarily.
        rawMotionRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.rawMotionRetryCount += 1
                self.startAvailablePhoneMotionServices(on: queue)
                self.emitRawMotionStatus()
                if self.rawMotionRetryCount >= 8 ||
                    (self.rawGyroscopeSamples > 0 && self.rawMagnetometerSamples > 0) {
                    self.rawMotionRetryTimer?.invalidate()
                    self.rawMotionRetryTimer = nil
                }
            }
        }
    }

    private func startAvailablePhoneMotionServices(on queue: OperationQueue) {
        if motion.isAccelerometerAvailable, !motion.isAccelerometerActive {
            motion.startAccelerometerUpdates(to: queue) { [weak self] sample, _ in
                guard let sample else { return }
                Task { @MainActor in
                    self?.rawAccelerometerSamples += 1
                    self?.emit(source: "iphone", sensor: "accelerometer",
                               monotonic: sample.timestamp, values: [
                        "x_g": sample.acceleration.x, "y_g": sample.acceleration.y,
                        "z_g": sample.acceleration.z])
                }
            }
        }
        if motion.isGyroAvailable, !motion.isGyroActive {
            motion.startGyroUpdates(to: queue) { [weak self] sample, _ in
                guard let sample else { return }
                Task { @MainActor in
                    self?.rawGyroscopeSamples += 1
                    self?.emit(source: "iphone", sensor: "gyroscope",
                               monotonic: sample.timestamp, values: [
                        "x_rad_s": sample.rotationRate.x, "y_rad_s": sample.rotationRate.y,
                        "z_rad_s": sample.rotationRate.z])
                }
            }
        }
        if motion.isMagnetometerAvailable, !motion.isMagnetometerActive {
            motion.startMagnetometerUpdates(to: queue) { [weak self] sample, _ in
                guard let sample else { return }
                Task { @MainActor in
                    self?.rawMagnetometerSamples += 1
                    self?.emit(source: "iphone", sensor: "magnetometer",
                               monotonic: sample.timestamp, values: [
                        "x_uT": sample.magneticField.x, "y_uT": sample.magneticField.y,
                        "z_uT": sample.magneticField.z])
                }
            }
        }
        if motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.emit(source: "iphone", sensor: "device_motion",
                    monotonic: data.timestamp, values: Self.deviceMotionValues(data)) }
            }
        }
    }

    private func emitRawMotionStatus() {
        emit(source: "iphone", sensor: "raw_motion_status", values: [
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
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] sample, _ in
                guard let sample else { return }
                self?.emit(source: "iphone", sensor: "barometer", monotonic: sample.timestamp, values: [
                    "relative_altitude_m": sample.relativeAltitude.doubleValue,
                    "pressure_kPa": sample.pressure.doubleValue
                ])
            }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] sample, _ in
                guard let sample else { return }
                self?.emit(source: "iphone", sensor: "absolute_altitude", monotonic: sample.timestamp, values: [
                    "altitude_m": sample.altitude,
                    "accuracy_m": sample.accuracy,
                    "precision_m": sample.precision
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
            Task { @MainActor in self?.emit(source: "iphone", sensor: "pedometer",
                                             timestamp: data.endDate.timeIntervalSince1970, values: values) }
        }
    }

    private func startMotionActivity() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        activityManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            self?.emitActivity(activity, source: "iphone", sensor: "motion_activity")
        }
    }

    private func emitActivity(_ activity: CMMotionActivity, source: String, sensor: String) {
        emit(source: source, sensor: sensor, timestamp: activity.startDate.timeIntervalSince1970, values: [
            "stationary": activity.stationary ? 1 : 0,
            "walking": activity.walking ? 1 : 0,
            "running": activity.running ? 1 : 0,
            "automotive": activity.automotive ? 1 : 0,
            "cycling": activity.cycling ? 1 : 0,
            "unknown": activity.unknown ? 1 : 0,
            "confidence": Double(activity.confidence.rawValue)
        ])
    }

    private func startLocation() {
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            location.requestAlwaysAuthorization()
            location.startUpdatingLocation()
        case .authorizedAlways:
            location.startUpdatingLocation()
        default:
            lastError = "未获得定位权限；其他传感器仍会继续采集。"
        }
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
    }

    private func startHeadphoneServices() {
        headphoneLastSampleTime = nil
        headphoneHasReceivedSample = false
        headphoneMotion.startConnectionStatusUpdates()
        startHeadphoneMotion(forceRestart: true, diagnosticEvent: 10)
        headphoneRetryTimer?.invalidate()
        headphoneRetryTimer = .scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHeadphoneMotionHealth() }
        }
    }

    private func startHeadphoneMotion(forceRestart: Bool = false, diagnosticEvent: Double = 60) {
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted {
            headphoneStatus = authorization == .denied ? "运动权限被拒绝" : "运动权限受限制"
            emitHeadphoneDiagnostic(event: 70)
            return
        }
        guard headphoneMotion.isDeviceMotionAvailable else {
            headphoneStatus = "等待兼容的 AirPods 连接"
            emitHeadphoneDiagnostic(event: 20)
            return
        }
        if forceRestart, headphoneMotion.isDeviceMotionActive {
            headphoneMotion.stopDeviceMotionUpdates()
        } else if headphoneMotion.isDeviceMotionActive {
            return
        }
        headphoneStatus = authorization == .notDetermined ? "等待运动权限" : "已连接，等待数据"
        emitHeadphoneDiagnostic(event: diagnosticEvent)
        headphoneMotion.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            if let error {
                self?.headphoneStatus = "读取错误"
                self?.lastError = "AirPods 运动数据不可用：\(error.localizedDescription)"
                self?.emitHeadphoneDiagnostic(event: 50, errorCode: Double((error as NSError).code))
            }
            guard let data else { return }
            self?.headphoneLastSampleTime = ProcessInfo.processInfo.systemUptime
            if self?.headphoneHasReceivedSample == false {
                self?.headphoneHasReceivedSample = true
                self?.headphoneStatus = "正在采集"
                self?.emitHeadphoneDiagnostic(event: 40)
            }
            self?.emit(source: "airpods", sensor: "head_motion", monotonic: data.timestamp,
                       values: Self.deviceMotionValues(data))
        }
    }

    private func checkHeadphoneMotionHealth() {
        guard isRecording else { return }
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        guard authorization != .denied, authorization != .restricted else {
            headphoneStatus = authorization == .denied ? "运动权限被拒绝" : "运动权限受限制"
            return
        }
        guard headphoneMotion.isDeviceMotionAvailable else {
            headphoneStatus = "等待兼容的 AirPods 连接"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isStale = headphoneLastSampleTime.map { now - $0 > 3.0 } ?? true
        if !headphoneMotion.isDeviceMotionActive || isStale {
            headphoneStatus = headphoneHasReceivedSample ? "数据中断，正在重连" : "尚无数据，正在重试"
            startHeadphoneMotion(forceRestart: true, diagnosticEvent: 60)
        }
    }

    private func emitHeadphoneDiagnostic(event: Double, errorCode: Double? = nil) {
        var values: [String: Double] = [
            "event": event,
            "authorization": Double(CMHeadphoneMotionManager.authorizationStatus().rawValue),
            "motion_available": headphoneMotion.isDeviceMotionAvailable ? 1 : 0,
            "motion_active": headphoneMotion.isDeviceMotionActive ? 1 : 0,
            "connection_monitor_active": headphoneMotion.isConnectionStatusActive ? 1 : 0
        ]
        values["error_code"] = errorCode
        emit(source: "airpods", sensor: "headphone_diagnostic", values: values)
    }

    private func startHeadphoneActivity() {
        guard #available(iOS 18.0, *) else { return }
        let manager = CMHeadphoneActivityManager()
        headphoneActivityManager = manager
        if manager.isActivityAvailable {
            manager.startActivityUpdates(to: .main) { [weak self] activity, _ in
                guard let activity else { return }
                self?.emitActivity(activity, source: "airpods", sensor: "headphone_activity")
            }
        }
        if manager.isStatusAvailable {
            manager.startStatusUpdates(to: .main) { [weak self] status, _ in
                self?.emit(source: "airpods", sensor: "headphone_status", values: [
                    "status": Double(status.rawValue)
                ])
            }
        }
    }

    private func startDeviceState() {
        emitBattery()
        batteryTimer = .scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitBattery() }
        }
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emitProximity() }
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.emitOrientation() }
        }
        emitProximity()
        emitOrientation()
    }

    private func emitBattery() {
        emit(source: "iphone", sensor: "battery", values: [
            "level": Double(UIDevice.current.batteryLevel),
            "state": Double(UIDevice.current.batteryState.rawValue)
        ])
    }

    private func emitProximity() {
        emit(source: "iphone", sensor: "proximity", values: [
            "is_near": UIDevice.current.proximityState ? 1 : 0,
            "monitoring_enabled": UIDevice.current.isProximityMonitoringEnabled ? 1 : 0
        ])
    }

    private func emitOrientation() {
        emit(source: "iphone", sensor: "device_orientation", values: [
            "orientation": Double(UIDevice.current.orientation.rawValue)
        ])
    }

    private func stopDeviceState() {
        if let proximityObserver { NotificationCenter.default.removeObserver(proximityObserver) }
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        proximityObserver = nil
        orientationObserver = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func startNearbyInteraction() {
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            uwbStatus = "此 iPhone 不支持 UWB 精确测距"
            emit(source: "iphone", sensor: "uwb_status", values: ["stage": 1])
            return
        }
        let session = NISession()
        session.delegate = self
        session.delegateQueue = .main
        nearbySession = session
        nearbyPeerTokenData = nil
        nearbyHandshakeAttempt = 0
        nearbyHasRanged = false
        uwbStatus = "等待 Apple Watch"
        emit(source: "iphone", sensor: "uwb_status", values: ["stage": 10])
        nearbyRetryTimer?.invalidate()
        nearbyRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendNearbyHandshake() }
        }
        sendNearbyHandshake()
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
                self.emit(source: "iphone", sensor: "uwb_status", values: [
                    "stage": 91, "reason": reasonCode
                ])
                self.startNearbyInteraction()
            }
        }
    }

    private func runNearbyInteraction(peerTokenData: Data, force: Bool = false) {
        guard force || peerTokenData != nearbyPeerTokenData else { return }
        guard let session = nearbySession,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self,
                                                                  from: peerTokenData) else {
            uwbStatus = "手表 UWB 令牌无效"
            emit(source: "iphone", sensor: "uwb_status", values: ["stage": 31])
            return
        }
        nearbyPeerTokenData = peerTokenData
        uwbStatus = "已收到手表令牌，正在测距"
        emit(source: "iphone", sensor: "uwb_status", values: ["stage": 30])
        let configuration = NINearbyPeerConfiguration(peerToken: token)
        // Keep standard ranging on iOS 26. Extended distance measurement can
        // stall phone-watch sessions when both peers use second-generation UWB.
        session.run(configuration)
        emit(source: "iphone", sensor: "uwb_status", values: ["stage": 40])
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
        var message: [String: Any] = [
            "command": "uwb",
            "sessionID": sessionID,
            "sessionFolderName": sessionFolderName,
            "audioStartUnixS": synchronizedAudioStartUnixS,
            "nearbyToken": data,
            "uwbHandshake": true
        ]
        message["handshakeAttempt"] = nearbyHandshakeAttempt
        emit(source: "iphone", sensor: "uwb_status", values: [
            "stage": 20, "attempt": Double(nearbyHandshakeAttempt),
            "watch_reachable": WCSession.default.isReachable ? 1 : 0
        ])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { failedMessage in
                Task { @MainActor [weak self] in
                    self?.emit(source: "iphone", sensor: "uwb_status", values: [
                        "stage": 21,
                        "error_code": Double((failedMessage as NSError).code)
                    ])
                }
            }
        }
    }

    private func startBodyTracking() {
        guard ARBodyTrackingConfiguration.isSupported else {
            lastError = "此设备不支持 ARKit 三维人体骨架。"
            return
        }
        let session = ARSession()
        session.delegate = self
        let configuration = ARBodyTrackingConfiguration()
        configuration.worldAlignment = .gravity
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        arSession = session
    }

#if targetEnvironment(simulator)
    private func startSimulationFeed() {
        demoSample = 0
        demoTimer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.demoSample += 1
                let t = Double(self.demoSample) * 0.05
                self.emit(source: "iphone_simulator", sensor: "accelerometer", values: [
                    "x_g": sin(t) * 0.12, "y_g": cos(t * 0.7) * 0.08,
                    "z_g": 1.0 + sin(t * 1.3) * 0.03
                ])
                self.emit(source: "iphone_simulator", sensor: "gyroscope", values: [
                    "x_rad_s": cos(t) * 0.25, "y_rad_s": sin(t * 0.6) * 0.18,
                    "z_rad_s": cos(t * 0.4) * 0.12
                ])
                self.emit(source: "iphone_simulator", sensor: "device_motion", values: [
                    "attitude_roll": sin(t * 0.4) * 0.2,
                    "attitude_pitch": cos(t * 0.3) * 0.15,
                    "attitude_yaw": sin(t * 0.2) * 0.35,
                    "gravity_x": 0, "gravity_y": 0, "gravity_z": -1,
                    "user_accel_x_g": sin(t) * 0.12, "user_accel_y_g": cos(t) * 0.08,
                    "user_accel_z_g": sin(t * 1.3) * 0.03
                ])
                if self.demoSample.isMultiple(of: 2) {
                    self.emit(source: "airpods_simulator", sensor: "head_motion", values: [
                        "attitude_roll": sin(t * 0.4) * 0.2,
                        "attitude_pitch": cos(t * 0.3) * 0.15,
                        "attitude_yaw": sin(t * 0.2) * 0.35
                    ])
                }
            }
        }
    }
#endif

    private func activateWatchSession() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func sendWatchCommand(_ command: String, sessionID: String) {
        guard WCSession.default.activationState == .activated else { return }
        var message: [String: Any] = [
            "command": command,
            "issuedAt": Date().timeIntervalSince1970,
            "sessionID": sessionID,
            "sessionFolderName": sessionFolderName
        ]
        if command == "start" {
            message["audioStartUnixS"] = synchronizedAudioStartUnixS
        }
        if command == "start", let token = nearbySession?.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            message["nearbyToken"] = data
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                if command == "stop" { WCSession.default.transferUserInfo(message) }
            }
        } else if command == "stop" {
            WCSession.default.transferUserInfo(message)
        }
    }

    static func recordings() -> [URL] {
        guard let directory = try? EventSink.recordingsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return [] }
        let supportedExtensions = Set(["ndjson", "wav", "json"])
        return files.filter {
            let isDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory || supportedExtensions.contains($0.pathExtension.lowercased())
        }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
    }

    private static func makeSessionFolderName(date: Date, sessionID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(formatter.string(from: date))_\(sessionID.prefix(8))"
    }

    private func writeSessionManifest(endDate: Date?) {
        guard let directory = sink.sessionDirectoryURL, let startDate = sessionStartDate else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var manifest: [String: Any] = [
            "schemaVersion": 1,
            "collectionMode": "independent_local",
            "watchLiveStreamEnabled": false,
            "udpEnabled": sessionUDPEnabled,
            "sessionID": sessionID,
            "sessionFolderName": sessionFolderName,
            "startedAtISO8601": iso.string(from: startDate),
            "startedAtUnixNs": String(UInt64(startDate.timeIntervalSince1970 * 1_000_000_000)),
            "audioScheduledStartUnixNs": String(UInt64(synchronizedAudioStartUnixS * 1_000_000_000)),
            "timeZone": TimeZone.current.identifier,
            "expectedFiles": [
                "iphone-events-\(sessionID).ndjson",
                "iphone-audio-\(sessionID).wav",
                "apple_watch-events-\(sessionID).ndjson",
                "apple_watch-audio-\(sessionID).wav"
            ],
            "state": endDate == nil ? "recording" : "stopped"
        ]
        if let endDate {
            manifest["endedAtISO8601"] = iso.string(from: endDate)
            manifest["endedAtUnixNs"] = String(UInt64(endDate.timeIntervalSince1970 * 1_000_000_000))
            manifest["durationSeconds"] = endDate.timeIntervalSince(startDate)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: manifest,
                                                       options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("session-info.json"), options: .atomic)
    }
}

extension SensorRecorder: CLLocationManagerDelegate {
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
        values["simulated_by_software"] = location.sourceInformation?.isSimulatedBySoftware == true ? 1 : 0
        values["produced_by_accessory"] = location.sourceInformation?.isProducedByAccessory == true ? 1 : 0
        Task { @MainActor in
            emit(source: "iphone", sensor: "location", timestamp: location.timestamp.timeIntervalSince1970,
                 values: values)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        Task { @MainActor in
            emit(source: "iphone", sensor: "heading", timestamp: heading.timestamp.timeIntervalSince1970, values: [
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in lastError = "定位错误：\(error.localizedDescription)" }
    }
}

extension SensorRecorder: CMHeadphoneMotionManagerDelegate {
    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            guard isRecording else { return }
            headphoneStatus = "已连接，正在启动"
            emitHeadphoneDiagnostic(event: 30)
            startHeadphoneMotion(forceRestart: true, diagnosticEvent: 31)
        }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in
            headphoneMotion.stopDeviceMotionUpdates()
            headphoneLastSampleTime = nil
            headphoneHasReceivedSample = false
            headphoneStatus = "已断开，等待重连"
            emitHeadphoneDiagnostic(event: 80)
        }
    }
}

extension SensorRecorder: NISessionDelegate {
    nonisolated func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        var values: [String: Double] = [:]
        if let distance = object.distance { values["distance_m"] = Double(distance) }
        if let direction = object.direction {
            values["direction_x"] = Double(direction.x)
            values["direction_y"] = Double(direction.y)
            values["direction_z"] = Double(direction.z)
        }
        Task { @MainActor in
            if !nearbyHasRanged {
                nearbyHasRanged = true
                nearbyRetryTimer?.invalidate()
                nearbyRetryTimer = nil
                uwbStatus = "UWB 测距中"
                emit(source: "iphone", sensor: "uwb_status", values: ["stage": 50])
            }
            emit(source: "iphone", sensor: "uwb_ranging", values: values)
        }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        Task { @MainActor in
            if isRecording, session === nearbySession {
                let nsError = error as NSError
                uwbStatus = "UWB 会话失效，正在重连"
                emit(source: "iphone", sensor: "uwb_status", values: [
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
            emit(source: "iphone", sensor: "uwb_status", values: ["stage": 60])
        }
    }

    nonisolated func sessionSuspensionEnded(_ session: NISession) {
        Task { @MainActor in
            guard isRecording, session === nearbySession else { return }
            uwbStatus = "UWB 正在恢复"
            emit(source: "iphone", sensor: "uwb_status", values: ["stage": 70])
            if let nearbyPeerTokenData { runNearbyInteraction(peerTokenData: nearbyPeerTokenData, force: true) }
            sendNearbyHandshake()
        }
    }

    nonisolated func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                             reason: NINearbyObject.RemovalReason) {
        Task { @MainActor in
            nearbyHasRanged = false
            uwbStatus = "UWB 目标丢失，正在重连"
            emit(source: "iphone", sensor: "uwb_status", values: [
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

extension SensorRecorder: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let body = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            guard isRecording, now - lastBodyFrameTime >= 1.0 / 30.0 else { return }
            lastBodyFrameTime = now
            var values: [String: Double] = [
                "root_x_m": Double(body.transform.columns.3.x),
                "root_y_m": Double(body.transform.columns.3.y),
                "root_z_m": Double(body.transform.columns.3.z),
                "is_tracked": body.isTracked ? 1 : 0
            ]
            let names = ARSkeletonDefinition.defaultBody3D.jointNames
            for (index, transform) in body.skeleton.jointModelTransforms.enumerated() where index < names.count {
                let name = names[index].replacingOccurrences(of: "/", with: "_")
                values["\(name)_x_m"] = Double(transform.columns.3.x)
                values["\(name)_y_m"] = Double(transform.columns.3.y)
                values["\(name)_z_m"] = Double(transform.columns.3.z)
            }
            emit(source: "iphone", sensor: "body_skeleton", monotonic: now, values: values)
        }
    }
}

extension SensorRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            guard isRecording else { return }
            sendWatchCommand("start", sessionID: sessionID)
            if nearbySession == nil {
                restartNearbyInteraction(after: 0.1, reasonCode: 3)
            } else if !nearbyHasRanged {
                if nearbyRetryTimer == nil {
                    nearbyRetryTimer = .scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.sendNearbyHandshake() }
                    }
                }
                sendNearbyHandshake()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveWatchMessage(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = message["controlRequest"] as? String else {
            receiveWatchMessage(message)
            replyHandler(["accepted": true, "isRecording": false])
            return
        }
        let requestedSessionID = message["sessionID"] as? String
        let requestID = message["controlRequestID"] as? String
        let controlTimestamp = message["controlTimestamp"] as? TimeInterval
        let controlMonotonic = message["controlMonotonic"] as? TimeInterval
        Task { @MainActor in
            let wasRecording = isRecording
            var accepted = true
            switch command {
            case "start":
                guard let controlTimestamp,
                      abs(Date().timeIntervalSince1970 - controlTimestamp) < 30 else {
                    replyHandler(["accepted": false, "error": "开始请求已过期，请重新点击"])
                    return
                }
                // Retrying a completed request must not create another recording.
                var handled = UserDefaults.standard.dictionary(forKey: "sensorread.startRequests.v2") as? [String: String] ?? [:]
                if let requestID, let previous = handled[requestID],
                   !isRecording || previous != sessionID {
                    replyHandler(["accepted": false, "error": "该开始请求已执行并结束，请重新点击"])
                    return
                }
                if !isRecording { startFromWatchControl() }
                else { sendWatchCommand("start", sessionID: sessionID) }
                accepted = isRecording
                if accepted, let requestID {
                    if handled.count >= 100 { handled.removeAll() }
                    handled[requestID] = sessionID
                    UserDefaults.standard.set(handled, forKey: "sensorread.startRequests.v2")
                }
                if accepted {
                    emitWatchControlEvent(command: command, timestamp: controlTimestamp,
                                          monotonic: controlMonotonic, wasRecording: wasRecording,
                                          accepted: true)
                }
            case "stop":
                guard requestedSessionID == sessionID else {
                    replyHandler(["accepted": true, "isRecording": false,
                                  "sessionID": requestedSessionID ?? ""])
                    return
                }
                if isRecording {
                    emitWatchControlEvent(command: command, timestamp: controlTimestamp,
                                          monotonic: controlMonotonic, wasRecording: wasRecording,
                                          accepted: true)
                    // Schedule the potentially longer shutdown after sending
                    // the reply. Watch can update its UI immediately, while
                    // the iPhone drains and closes files on the next actor turn.
                    Task { @MainActor [weak self] in self?.stop() }
                } else if let requestedSessionID {
                    sendWatchCommand("stop", sessionID: requestedSessionID)
                }
            case "status":
                if isRecording { sendWatchCommand("start", sessionID: sessionID) }
            default:
                replyHandler(["accepted": false, "error": "未知控制命令"])
                return
            }
            let replyIsRecording = command == "stop" ? false : isRecording
            var reply: [String: Any] = ["accepted": accepted,
                                        "isRecording": replyIsRecording]
            if !sessionID.isEmpty {
                reply["sessionID"] = sessionID
                reply["sessionFolderName"] = sessionFolderName
                reply["audioStartUnixS"] = synchronizedAudioStartUnixS
            }
            if let lastError, !isRecording, command == "start" { reply["error"] = lastError }
            replyHandler(reply)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["controlRequest"] != nil {
            receiveQueuedWatchControl(userInfo)
        } else {
            receiveWatchMessage(userInfo)
        }
    }

    /// Handles the reliable background copy of a Watch control request. Stop
    /// is intentionally idempotent because the immediate request may have
    /// succeeded even when its reply was lost.
    nonisolated private func receiveQueuedWatchControl(_ message: [String: Any]) {
        guard let command = message["controlRequest"] as? String else { return }
        let requestedSessionID = message["sessionID"] as? String
        let controlTimestamp = message["controlTimestamp"] as? TimeInterval
        let controlMonotonic = message["controlMonotonic"] as? TimeInterval
        Task { @MainActor in
            guard command == "stop" else { return }
            if isRecording, requestedSessionID == sessionID {
                emitWatchControlEvent(command: command, timestamp: controlTimestamp,
                                      monotonic: controlMonotonic, wasRecording: true,
                                      accepted: true)
                stop()
            } else if let requestedSessionID {
                sendWatchCommand("stop", sessionID: requestedSessionID)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata
        do {
            // WCSession owns file.fileURL and may remove it as soon as this
            // delegate callback returns. Copy synchronously before hopping to
            // another actor or queue.
            let receipt = try Self.persistWatchFile(from: file.fileURL, metadata: metadata)
            var acknowledgement: [String: Any] = [
                "watchFileReceived": receipt.filename,
                "sessionFolderName": receipt.folderName
            ]
            if let sessionID = metadata?["sessionID"] as? String {
                acknowledgement["sessionID"] = sessionID
            }
            if session.isReachable {
                session.sendMessage(acknowledgement, replyHandler: nil) { _ in
                    session.transferUserInfo(acknowledgement)
                }
            } else {
                session.transferUserInfo(acknowledgement)
            }
        } catch {
            Task { @MainActor in
                lastError = "接收手表文件失败：\(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func persistWatchFile(
        from temporaryURL: URL, metadata: [String: Any]?
    ) throws -> (filename: String, folderName: String) {
        let directory: URL
        let folderName: String
        if let proposedFolder = metadata?["sessionFolderName"] as? String {
            folderName = URL(fileURLWithPath: proposedFolder).lastPathComponent
            directory = try EventSink.sessionDirectory(named: folderName)
        } else {
            // Backward compatibility for files sent by an older Watch app.
            folderName = ""
            directory = try EventSink.recordingsDirectory()
        }
        let proposedName = (metadata?["filename"] as? String) ?? temporaryURL.lastPathComponent
        let safeName = URL(fileURLWithPath: proposedName).lastPathComponent
        let destination = directory.appendingPathComponent(safeName)
        let sourceSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if let expected = metadata?["fileSizeBytes"] as? Int, sourceSize != expected {
            throw NSError(domain: "SensorRead.Transfer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "手表文件大小校验失败"])
        }
        let staged = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: temporaryURL, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
        let receipt: [String: Any] = [
            "filename": safeName, "sizeBytes": sourceSize,
            "receivedAtISO8601": ISO8601DateFormatter().string(from: Date()),
            "sizeChecked": metadata?["fileSizeBytes"] != nil
        ]
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try receiptData.write(to: directory.appendingPathComponent(safeName + ".receipt.json"), options: .atomic)
        return (safeName, folderName)
    }

    nonisolated private func receiveWatchMessage(_ message: [String: Any]) {
        if let token = message["nearbyToken"] as? Data,
           let receivedSessionID = message["sessionID"] as? String {
            Task { @MainActor in
                guard isRecording, receivedSessionID == sessionID else { return }
                runNearbyInteraction(peerTokenData: token)
            }
        }
        // Watch sensor records arrive only as finalized files, never as a live stream.
    }
}
