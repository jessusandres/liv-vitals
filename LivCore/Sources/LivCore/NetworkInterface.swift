import Darwin
import Foundation
import os
import SystemConfiguration

public enum NetworkInterfaceKind: Sendable, Equatable {
    case wifi, ethernet, vpn, other
}

/// The interface that carries the default route, and its IPv4 address. Reads local state only; no network request.
public struct NetworkInterfaceInfo: Sendable, Equatable {
    public var kind: NetworkInterfaceKind
    public var bsdName: String
    public var ipv4: String?

    public init(kind: NetworkInterfaceKind, bsdName: String, ipv4: String?) {
        self.kind = kind
        self.bsdName = bsdName
        self.ipv4 = ipv4
    }

    public static func classify(bsdName: String, isWiFi: Bool) -> NetworkInterfaceKind {
        if ["utun", "ipsec", "ppp"].contains(where: bsdName.hasPrefix) { return .vpn }
        if bsdName.hasPrefix("en") { return isWiFi ? .wifi : .ethernet }
        return .other
    }

    /// nil when offline.
    public static func current() -> NetworkInterfaceInfo? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String, !name.isEmpty else { return nil }
        return NetworkInterfaceInfo(kind: classify(bsdName: name, isWiFi: isWiFi(name)), bsdName: name, ipv4: ipv4Address(of: name))
    }

    /// An interface's type never changes, so the system is asked once per name instead of once a second.
    private static let wifiByName = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    private static func isWiFi(_ name: String) -> Bool {
        if let known = wifiByName.withLock({ $0[name] }) { return known }
        // en0 is Ethernet on a desktop, so ask the system which interfaces are Wi-Fi.
        let wifiType = kSCNetworkInterfaceTypeIEEE80211 as String
        let isWiFi = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).contains {
            SCNetworkInterfaceGetBSDName($0) as String? == name && SCNetworkInterfaceGetInterfaceType($0) as String? == wifiType
        }
        wifiByName.withLock { $0[name] = isWiFi }
        return isWiFi
    }

    private static func ipv4Address(of name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name) == name else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let source = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            return withUnsafePointer(to: source) { inet_ntop(AF_INET, $0, &buffer, socklen_t(buffer.count)) }
                .map { String(cString: $0) }
        }
        return nil
    }
}
