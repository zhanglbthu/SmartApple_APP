import Foundation
import Network

final class EventSink {
    private let queue = DispatchQueue(label: "sensorread.sink")
    private let networkQueue = DispatchQueue(label: "sensorread.network")
    private let encoder = JSONEncoder()
    private var file: FileHandle?
    private var connection: NWConnection?
    private(set) var fileURL: URL?
    private(set) var sessionDirectoryURL: URL?

    func open(sessionID: String, sessionFolderName: String, host: String, port: UInt16) throws {
        let directory = try Self.sessionDirectory(named: sessionFolderName)
        let url = directory.appendingPathComponent("iphone-events-\(sessionID).ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
        fileURL = url
        sessionDirectoryURL = directory

        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.start(queue: networkQueue)
        self.connection = connection
    }

    func write(_ event: SensorEvent) {
        queue.async { [weak self] in
            guard let self, var data = try? encoder.encode(event) else { return }
            data.append(0x0A)
            try? file?.write(contentsOf: data)
            connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func close(finalEvent: SensorEvent? = nil, udpRepetitions: Int = 1) {
        queue.sync {
            if let finalEvent, var data = try? encoder.encode(finalEvent) {
                data.append(0x0A)
                try? file?.write(contentsOf: data)
                if let connection {
                    let sends = max(1, udpRepetitions)
                    let group = DispatchGroup()
                    for _ in 0..<sends {
                        group.enter()
                        connection.send(content: data, completion: .contentProcessed { _ in
                            group.leave()
                        })
                    }
                    _ = group.wait(timeout: .now() + .milliseconds(500))
                }
            }
            try? file?.synchronize()
            try? file?.close()
            file = nil
            connection?.cancel()
            connection = nil
        }
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
