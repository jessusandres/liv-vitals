import AppKit
import LivCore
import SwiftUI
import Testing
@testable import LivVitals

/// Walks the accessibility tree AppKit builds for a view that is really laid out in a window, so the labels VoiceOver
/// would read are checked, not only the functions that produce them (`AccessibilityTextTests` does that).
/// Walks the accessibility tree AppKit builds for each screen, hosted in a window, instead of only the label functions.
///
/// What the walk cannot reach in the test host (SwiftUI does not expose them to AppKit here, so they are not checked
/// by the walk; the labels come from `AccessibilityText` and are covered by `AccessibilityTextTests`): the Smart Care and
/// Cleanup cards, the circular action buttons, the progress rings, the expand chevrons, the checkboxes and the Space Lens
/// sunburst segments. In every screen the walk found no element carrying one of those labels. The About window
/// exposes no elements at all, and most controls of the other screens appear as unnamed groups, so the walk checks
/// little beyond the raw-symbol and bare-"Button" rules. The unnamed groups it does see (empty `AXUnknown` containers)
/// are not controls and are not checked.
@MainActor
struct AccessibilityTreeTests {
    /// Roles of controls: a name that VoiceOver can read is required wherever AppKit exposes one.
    private static let controlRoles: Set<String> = [
        NSAccessibility.Role.button.rawValue,
        NSAccessibility.Role.checkBox.rawValue,
        NSAccessibility.Role.disclosureTriangle.rawValue,
        NSAccessibility.Role.radioButton.rawValue,
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.link.rawValue,
        NSAccessibility.Role.slider.rawValue,
        NSAccessibility.Role.progressIndicator.rawValue,
    ]

    /// A raw SF Symbol name such as `chevron.right` or `checkmark.circle.fill`, which is never a spoken label.
    private static let symbolName = /^[a-z0-9]+(\.[a-z0-9]+)+$/

    @Test func smartCareIdleHasNoRawLabels() async throws {
        try await expectNamed(RootView(selection: .smartCare, store: AppStore(services: .mock)), "Smart Care idle")
    }

    @Test func smartCareResultsHaveNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        let flow = store.scanFlow(for: .smartCare)
        flow.startScan()
        #expect(await waitUntil(timeout: .seconds(10)) { flow.phase == .results })
        try await expectNamed(RootView(selection: .smartCare, store: store), "Smart Care results")
    }

    @Test func cleanupResultsHaveNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        let flow = store.scanFlow(for: .cleanup)
        flow.startScan()
        #expect(await waitUntil(timeout: .seconds(10)) { flow.phase == .results })
        try await expectNamed(RootView(selection: .cleanup, store: store), "Cleanup results")
    }

    @Test func uninstallerResultsHaveNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        let flow = store.scanFlow(for: .applications)
        flow.startScan()
        #expect(await waitUntil(timeout: .seconds(10)) { flow.phase == .results })
        try await expectNamed(RootView(selection: .applications, store: store), "Uninstaller results")
    }

    @Test func performanceHasNoRawLabels() async throws {
        try await expectNamed(RootView(selection: .performance, store: AppStore(services: .mock)), "Performance")
    }

    @Test func spaceLensHasNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        store.spaceLens.scan()
        #expect(await waitUntil(timeout: .seconds(10)) { store.spaceLens.root != nil })
        try await expectNamed(RootView(selection: .spaceLens, store: store), "Space Lens")
    }

    @Test func monitorHasNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        store.monitor.start()
        #expect(await waitUntil(timeout: .seconds(10)) { store.monitor.latest != nil })
        try await expectNamed(RootView(selection: .monitor, store: store), "Monitor")
    }

    @Test func historyExpandedHasNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        await store.loadHistory()
        for run in store.history.prefix(1) { store.historyModel.expanded.insert(run.id) }
        try await expectNamed(RootView(selection: .history, store: store), "History expanded")
    }

    @Test func settingsHasNoRawLabels() async throws {
        try await expectNamed(RootView(selection: .settings, store: AppStore(services: .mock)), "Settings")
    }

    @Test func welcomeGuideStepsHaveNoRawLabels() async throws {
        let store = AppStore(services: .mock)
        for step in OnboardingModel.Step.allCases {
            try await expectNamed(
                OnboardingView(permissions: store.permissions, adminRule: store.adminRule, initialStep: step, onFinish: {}),
                "Welcome guide, step \(step.rawValue + 1)"
            )
        }
    }

    /// AppKit exposes no elements for the About window in this host (it has no subviews), so the walk has nothing to
    /// check there. Its only control-like image is hidden from accessibility, and its texts are read as plain text.
    @Test func aboutWindowHasNoControlsToName() async throws {
        let (nodes, _) = await walk(AboutView())
        #expect(nodes.allSatisfy { !Self.controlRoles.contains($0.role ?? "") })
    }

    // MARK: - Walking

    /// One node of the tree, with the name VoiceOver would read for it.
    private struct Node {
        let role: String?
        let label: String?
        let title: String?
        let value: String?
        let hidden: Bool
        let depth: Int
        /// The label, else the title, else the text inside the element.
        var name: String?
    }

    /// Hosts `view` in a window on screen, lays it out, and returns every node of its accessibility tree.
    private func walk<V: View>(_ view: V) async -> (nodes: [Node], subviews: Int) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 1120, height: 740),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // Lets SwiftUI lay out, run its `.task` modifiers and publish the first state.
        try? await Task.sleep(for: .milliseconds(1500))
        host.layoutSubtreeIfNeeded()
        var found: [Node] = []
        var seen = Set<ObjectIdentifier>()
        _ = collect(host, depth: 0, into: &found, seen: &seen)
        return (found, host.subviews.count)
    }

    /// Reads an accessibility attribute by its selector, as AppKit does, so it works on every element SwiftUI builds,
    /// including the ones that do not declare the `NSAccessibility` protocol.
    private func attribute<Value>(_ object: NSObject, _ name: String) -> Value? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? Value
    }

    /// Descends through the accessibility children and the subviews, since SwiftUI hosts its elements in subviews.
    /// Returns the text of everything below `element`, which names the element when it has no label of its own.
    private func collect(_ element: NSObject, depth: Int, into found: inout [Node], seen: inout Set<ObjectIdentifier>) -> [String] {
        let children: [NSObject] = ((attribute(element, "accessibilityChildren") as [Any]?) ?? []).compactMap { $0 as? NSObject }
            + ((element as? NSView)?.subviews ?? [])
        var texts: [String] = []
        for child in children where seen.insert(ObjectIdentifier(child)).inserted {
            let label: String? = attribute(child, "accessibilityLabel")
            let title: String? = attribute(child, "accessibilityTitle")
            let value: String? = attribute(child, "accessibilityValue")
            let index = found.count
            found.append(Node(
                role: attribute(child, "accessibilityRole"),
                label: label,
                title: title,
                value: value,
                hidden: attribute(child, "accessibilityHidden") ?? false,
                depth: depth,
                name: nil
            ))
            let inside = collect(child, depth: depth + 1, into: &found, seen: &seen)
            found[index].name = [label, title].compactMap { $0 }.first { !$0.isEmpty } ?? inside.first
            texts += [label, title, value].compactMap { $0 } + inside
        }
        return texts
    }

    /// Fails on what the walk can see: a raw symbol name or a bare "Button" in any visible label, and an empty label on
    /// a visible control. A control whose name AppKit does not expose is counted, not failed: see the review for why.
    private func expectNamed<V: View>(_ view: V, _ screen: String) async throws {
        let (nodes, subviews) = await walk(view)
        let visible = nodes.filter { !$0.hidden }
        let controls = visible.filter { Self.controlRoles.contains($0.role ?? "") }
        let unnamed = controls.filter { $0.name == nil }
        print("AX \(screen): \(nodes.count) nodes, \(subviews) top-level subviews, \(controls.count) controls, \(unnamed.count) without a name AppKit exposes")
        #expect(!nodes.isEmpty || subviews == 0, "\(screen): the tree is missing although the view has subviews")
        for node in visible {
            for text in [node.label, node.title, node.value].compactMap({ $0 }) {
                #expect(text.wholeMatch(of: Self.symbolName) == nil, "\(screen): \(text) is read as a raw symbol name")
                #expect(text != "Button" && text != "button", "\(screen): a control reads as a bare \(text)")
            }
        }
        for control in controls {
            #expect(control.name != "", "\(screen): a \(control.role ?? "control") has an empty name")
        }
    }
}
