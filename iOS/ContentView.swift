import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: SensorRecorder
    @AppStorage("receiverIP") private var receiverIP = "192.168.1.100"
    @AppStorage("receiverPort") private var receiverPort = 9000
    @AppStorage("enableUDP") private var enableUDP = false
    @AppStorage("enableBodyTracking") private var enableBodyTracking = false

    var body: some View {
        NavigationStack {
            Form {
#if targetEnvironment(simulator)
                Section {
                    Label("模拟器演示模式：使用合成传感器数据", systemImage: "testtube.2")
                        .foregroundStyle(.orange)
                }
#endif
                Section("采集状态") {
                    LabeledContent("状态", value: recorder.isRecording ? "采集中" : "已停止")
                    LabeledContent("事件数", value: recorder.eventCount.formatted())
                    LabeledContent("UWB", value: recorder.uwbStatus)
                    LabeledContent("AirPods", value: recorder.headphoneStatus)
                    LabeledContent("iPhone 音频", value: recorder.audioStatus)
                    LabeledContent("当前会话", value: recorder.currentFilename ?? "—")
                    if let error = recorder.lastError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                    Button(recorder.isRecording ? "结束采集" : "开始采集") {
                        recorder.isRecording ? recorder.stop() :
                            recorder.start(host: receiverIP, port: UInt16(clamping: receiverPort),
                                           enableBodyTracking: enableBodyTracking, enableUDP: enableUDP)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRecording ? .red : .blue)
                }

                Section("PC 实时 UDP 接收端") {
                    Toggle("启用 UDP 实时传输", isOn: $enableUDP)
                        .disabled(recorder.isRecording)
                    TextField("IP 地址", text: $receiverIP)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("端口", value: $receiverPort, format: .number)
                        .keyboardType(.numberPad)
                    Text("默认仅本地保存。开启后仅发送手机和 AirPods 的事件（包括手机侧 UWB）。手表独立保存，结束后传回文件。修改将在下一次采集生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("可选前台视觉捕捉") {
                    Toggle("ARKit 三维人体骨架（后置相机）", isOn: $enableBodyTracking)
                        .disabled(recorder.isRecording)
                    Text("开启后以最高约 30 Hz 输出人体关节三维坐标。需要相机对准完整人体，且不能在息屏后台持续运行；会显著增加耗电与网络带宽。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("数据来源") {
                    Label("iPhone：完整 IMU/姿态、麦克风音频、步态、活动、气压/海拔、GPS/航向、UWB、设备状态、可选人体骨架", systemImage: "iphone")
                    Label("AirPods：完整头部姿态/运动，以及兼容型号的活动和佩戴状态", systemImage: "airpodspro")
                    Label("Apple Watch：完整 IMU/姿态、麦克风音频、步态、活动、气压/海拔、GPS/航向、心率/运动指标、UWB、电池", systemImage: "applewatch")
                }

                Section("已保存数据") {
                    NavigationLink("浏览和分享文件") { RecordingsView() }
                }

                Section("后台提示") {
                    Text("手表端使用运动会话支持息屏采集。iPhone 端启用后台定位；只有授予“始终允许”且确有定位采集需求时，系统才可能持续唤醒应用。用户强制退出、系统回收或设备重启后，iOS 不保证自动继续。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sensor Read")
        }
    }
}

private struct RecordingsView: View {
    @State private var items: [URL] = []

    var body: some View {
        List(items, id: \.self) { item in
            if isDirectory(item) {
                NavigationLink {
                    SessionFilesView(directory: item)
                } label: {
                    Label(item.lastPathComponent, systemImage: "folder.fill")
                }
            } else {
                ShareLink(item: item) { RecordingFileLabel(file: item) }
            }
        }
        .navigationTitle("采集会话")
        .onAppear {
            items = SensorRecorder.recordings()
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct SessionFilesView: View {
    let directory: URL
    @State private var files: [URL] = []

    var body: some View {
        List(files, id: \.self) { file in
            ShareLink(item: file) { RecordingFileLabel(file: file) }
        }
        .navigationTitle(directory.lastPathComponent)
        .toolbar {
            ShareLink(item: directory) { Image(systemName: "square.and.arrow.up") }
        }
        .onAppear {
            files = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []).sorted {
                    $0.lastPathComponent < $1.lastPathComponent
                }
        }
    }
}

private struct RecordingFileLabel: View {
    let file: URL

    var body: some View {
        VStack(alignment: .leading) {
            Text(file.lastPathComponent)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
