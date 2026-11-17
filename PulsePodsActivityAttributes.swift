import ActivityKit
import Foundation

struct PulsePodsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var heartRateBPM: Int?
        var isConnected: Bool
    }

    let startedAt: Date
}
