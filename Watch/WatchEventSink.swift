import Foundation

final class WatchEventSink {
    private let queue = DispatchQueue(label: "sensorread.watch.file")
    private let encoder = JSONEncoder()
    private var file: FileHandle?
    private(set) var fileURL: URL?
    private(set) var sessionDirectoryURL: URL?

    func open(sessionID: String, sessionFolderName: String) throws {
        let directory = try Self.sessionDirectory(named: sessionFolderName)
        let url = directory.appendingPathComponent("apple_watch-events-\(sessionID).ndjson")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        fileURL = url
        sessionDirectoryURL = directory
    }

    func write(_ event: SensorEvent) {
        queue.async { [weak self] in
            guard let self, var data = try? encoder.encode(event) else { return }
            data.append(0x0A)
            try? file?.write(contentsOf: data)
        }
    }

    @discardableResult
    func close() -> URL? {
        queue.sync {
            try? file?.synchronize()
            try? file?.close()
            file = nil
        }
        return fileURL
    }

    static func recordingsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func sessionDirectory(named folderName: String) throws -> URL {
        let root = try recordingsDirectory()
        let safeName = URL(fileURLWithPath: folderName).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
            throw NSError(domain: "SensorRead.Storage", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "采集目录名称无效"])
        }
        let directory = root.appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
