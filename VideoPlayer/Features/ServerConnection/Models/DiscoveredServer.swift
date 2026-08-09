import Foundation

struct DiscoveredServer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let service: NetService
    var address: String?
}
