import AVFAudio
import Foundation

@MainActor
final class AudioCapture: NSObject, AVAudioRecorderDelegate {
    typealias EventHandler = (_ sensor: String, _ timestamp: TimeInterval, _ values: [String: Double]) -> Void

    static let sampleRate = 16_000.0
    static let channels = 1
    static let bitsPerSample = 16

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var requestID = UUID()
    private var startUnixTime: TimeInterval = 0
    private var eventHandler: EventHandler?
    private var errorHandler: ((String) -> Void)?
    private(set) var fileURL: URL?
    private(set) var status = "未启动"

    func start(sessionID: String, source: String, directory: URL,
               scheduledUnixTime: TimeInterval,
               onEvent: @escaping EventHandler,
               onStatus: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) {
        stop(emitEvent: false)
        let currentRequestID = UUID()
        requestID = currentRequestID
        eventHandler = onEvent
        errorHandler = onError
        setStatus("等待麦克风权限", callback: onStatus)

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self, self.requestID == currentRequestID else { return }
                guard granted else {
                    self.setStatus("麦克风权限被拒绝", callback: onStatus)
                    self.reportError("未获得麦克风权限")
                    self.emit("audio_error", timestamp: Date().timeIntervalSince1970,
                              values: ["error_code": 1])
                    return
                }
                self.beginRecording(sessionID: sessionID, source: source, directory: directory,
                                    scheduledUnixTime: scheduledUnixTime, onStatus: onStatus)
            }
        }
    }

    @discardableResult
    func stop(emitEvent: Bool = true) -> URL? {
        requestID = UUID()
        meterTimer?.invalidate()
        meterTimer = nil
        guard let recorder else {
            eventHandler = nil
            errorHandler = nil
            return fileURL
        }
        let duration = max(0, recorder.currentTime)
        let sampleCount = floor(duration * Self.sampleRate)
        recorder.stop()
        self.recorder = nil
        let size = fileURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        if emitEvent {
            emit("audio_stop", timestamp: startUnixTime + duration, values: [
                "sample_rate_hz": Self.sampleRate,
                "duration_s": duration,
                "sample_count": sampleCount,
                "file_size_bytes": Double(size)
            ])
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        status = "已停止"
        eventHandler = nil
        errorHandler = nil
        return fileURL
    }

    private func beginRecording(sessionID: String, source: String, directory: URL,
                                scheduledUnixTime: TimeInterval,
                                onStatus: @escaping (String) -> Void) {
        var setupStage = "创建录音目录"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(source)-audio-\(sessionID).wav")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            let session = AVAudioSession.sharedInstance()
            setupStage = "配置音频会话"
            try session.setCategory(.record, mode: .measurement)
#if os(iOS)
            // These are hardware preferences, not requirements for the WAV
            // encoder. Some iPhone input routes reject a 16 kHz hardware rate
            // or a forced channel count with OSStatus -50. AVAudioRecorder will
            // still resample the active input to the 16 kHz mono format below.
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
            try? session.setPreferredSampleRate(Self.sampleRate)
#endif
            setupStage = "激活音频会话"
            try session.setActive(true)

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: Self.channels,
                AVLinearPCMBitDepthKey: Self.bitsPerSample,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            setupStage = "创建 WAV 录音器"
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            setupStage = "准备 WAV 录音器"
            guard recorder.prepareToRecord() else {
                throw NSError(domain: "SensorRead.Audio", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "无法准备音频文件"])
            }

            let now = Date().timeIntervalSince1970
            let delay = max(0, scheduledUnixTime - now)
            let intendedStart = delay > 0 ? scheduledUnixTime : now
            setupStage = "启动 WAV 录音器"
            let started = delay > 0
                ? recorder.record(atTime: recorder.deviceCurrentTime + delay)
                : recorder.record()
            guard started else {
                throw NSError(domain: "SensorRead.Audio", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "系统拒绝启动录音"])
            }

            self.recorder = recorder
            fileURL = url
            startUnixTime = intendedStart
            setStatus(delay > 0 ? "等待同步开始" : "正在录音", callback: onStatus)
            emit("audio_start", timestamp: intendedStart, values: [
                "sample_rate_hz": Self.sampleRate,
                "channels": Double(Self.channels),
                "bits_per_sample": Double(Self.bitsPerSample),
                "scheduled_start_unix_s": scheduledUnixTime,
                "actual_start_unix_s": intendedStart,
                "schedule_lateness_ms": max(0, now - scheduledUnixTime) * 1_000
            ])

            meterTimer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.emitMeter(onStatus: onStatus) }
            }
        } catch {
            setStatus("录音启动失败", callback: onStatus)
            let nsError = error as NSError
            reportError("录音启动失败（\(setupStage)）：\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]")
            emit("audio_error", timestamp: Date().timeIntervalSince1970,
                 values: ["error_code": Double(nsError.code)])
        }
    }

    private func emitMeter(onStatus: (String) -> Void) {
        guard let recorder else { return }
        guard recorder.isRecording else { return }
        if status != "正在录音" { setStatus("正在录音", callback: onStatus) }
        recorder.updateMeters()
        let average = max(-160, Double(recorder.averagePower(forChannel: 0)))
        let peak = max(-160, Double(recorder.peakPower(forChannel: 0)))
        let elapsed = recorder.currentTime
        emit("audio_level", timestamp: startUnixTime + elapsed, values: [
            "rms_dbfs": average,
            "peak_dbfs": peak,
            "linear_rms": pow(10, average / 20),
            "elapsed_s": elapsed,
            "sample_count": floor(elapsed * Self.sampleRate),
            "sample_rate_hz": Self.sampleRate
        ])
    }

    private func emit(_ sensor: String, timestamp: TimeInterval, values: [String: Double]) {
        eventHandler?(sensor, timestamp, values)
    }

    private func setStatus(_ value: String, callback: (String) -> Void) {
        status = value
        callback(value)
    }

    private func reportError(_ message: String) {
        errorHandler?(message)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            reportError("录音编码错误：\(error?.localizedDescription ?? "未知错误")")
            emit("audio_error", timestamp: Date().timeIntervalSince1970,
                 values: ["error_code": Double((error as NSError?)?.code ?? -1)])
        }
    }
}
