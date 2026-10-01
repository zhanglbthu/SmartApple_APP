import SwiftUI

@main
struct SensorReadWatchApp: App {
    @StateObject private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 6) {
                    Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(recorder.isRecording ? .green : .secondary)
                    Text(recorder.isRecording ? "全系统采集中" : "全系统已停止")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(recorder.controlStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(recorder.eventCount) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(recorder.uwbStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("音频：\(recorder.audioStatus)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let error = recorder.lastError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                    Button {
                        recorder.requestSystemToggle()
                    } label: {
                        Text(recorder.isRecording ? "结束全部采集" : "开始全部采集")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(recorder.isRecording ? Color.red : Color.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.isControlPending)
                    .opacity(recorder.isControlPending ? 0.6 : 1)
                    if recorder.isControlPending && recorder.isRecording {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}
