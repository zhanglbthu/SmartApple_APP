import Foundation

struct SensorEvent: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let source: String
    let sensor: String
    let sequenceNumber: UInt64
    let timestampUnixNs: UInt64
    let timestampMonotonicS: Double
    let values: [String: Double]

    init(sessionID: String, source: String, sensor: String,
         timestamp: TimeInterval = Date().timeIntervalSince1970,
         monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime,
         sequenceNumber: UInt64 = 0,
         values: [String: Double]) {
        schemaVersion = 2
        self.sessionID = sessionID
        self.source = source
        self.sensor = sensor
        self.sequenceNumber = sequenceNumber
        timestampUnixNs = UInt64(max(0, timestamp) * 1_000_000_000)
        timestampMonotonicS = monotonic
        self.values = values
    }
}
