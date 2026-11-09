import Testing
@testable import LivCore

struct NetworkInterfaceTests {
    @Test func classifiesByNameAndWiFi() {
        #expect(NetworkInterfaceInfo.classify(bsdName: "en0", isWiFi: true) == .wifi)
        #expect(NetworkInterfaceInfo.classify(bsdName: "en5", isWiFi: false) == .ethernet)
        for name in ["utun3", "ipsec0", "ppp0"] {
            #expect(NetworkInterfaceInfo.classify(bsdName: name, isWiFi: false) == .vpn)
        }
        #expect(NetworkInterfaceInfo.classify(bsdName: "bridge0", isWiFi: false) == .other)
    }

    @Test func currentIsNilOrNamed() {
        if let info = NetworkInterfaceInfo.current() { #expect(!info.bsdName.isEmpty) }
    }
}

struct NetworkInterfaceProbe {
    /// Hardware probe: prints what this Mac reports; asserts nothing.
    @Test func printsTheCurrentInterface() {
        print("PROBE interface: \(String(describing: NetworkInterfaceInfo.current()))")
    }
}
