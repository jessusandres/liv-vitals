import Foundation
import LivCore
import Observation

/// The user's settings as the UI sees them. Every real change is saved shortly after, through `SettingsStore`;
/// setting a value to what it already is saves nothing.
@Observable
final class AppSettings {
    var moveToTrash: Bool { didSet { if moveToTrash != oldValue { changed() } } }
    var dryRun: Bool { didSet { if dryRun != oldValue { changed() } } }
    var previewBeforeCleaning: Bool { didSet { if previewBeforeCleaning != oldValue { changed() } } }
    var skipRecentProjects: Bool { didSet { if skipRecentProjects != oldValue { changed() } } }
    var showMenuBarExtra: Bool { didSet { if showMenuBarExtra != oldValue { changed() } } }
    var hideFromDockWhenClosed: Bool { didSet { if hideFromDockWhenClosed != oldValue { changed() } } }
    var hasCompletedOnboarding: Bool { didSet { if hasCompletedOnboarding != oldValue { changed() } } }
    private(set) var indicators: [IndicatorSetting] { didSet { if indicators != oldValue { changed(); onIndicatorsChanged?() } } }
    var indicatorRefresh: Int { didSet { if indicatorRefresh != oldValue { changed(); onIndicatorsChanged?() } } }
    /// Called when the indicators or their refresh interval change, so sampling can follow.
    @ObservationIgnored var onIndicatorsChanged: (() -> Void)?
    var keepAwake: KeepAwakeSettings { didSet { if keepAwake != oldValue { changed(); onKeepAwakeChanged?() } } }
    /// Called when a keep-awake option changes, so the model can follow.
    @ObservationIgnored var onKeepAwakeChanged: (() -> Void)?
    private(set) var protectedPaths: [String] { didSet { if protectedPaths != oldValue { changed() } } }
    private(set) var projectRoots: [String] { didSet { if projectRoots != oldValue { changed() } } }
    private(set) var installerFolders: [String] { didSet { if installerFolders != oldValue { changed() } } }

    /// Debug and probe builds only: what to save while `-LivIndicators` forces other indicators on for this launch.
    @ObservationIgnored private var indicatorsToSave: [IndicatorSetting]?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `-LivIndicators cpu,network` on the command line (Debug and probe builds only).
    private static var launchIndicatorsArgument: String? {
        #if DEBUG || PERF_PROBE
        UserDefaults.standard.string(forKey: "LivIndicators")
        #else
        nil
        #endif
    }

    init(store: SettingsStore, home: URL, saveDelay: Duration = .milliseconds(300), launchIndicators: String? = AppSettings.launchIndicatorsArgument) {
        let loaded = store.load()
        self.store = store
        self.home = home
        self.saveDelay = saveDelay
        moveToTrash = loaded.moveToTrash
        dryRun = loaded.dryRun
        previewBeforeCleaning = loaded.previewBeforeCleaning
        skipRecentProjects = loaded.skipRecentProjects
        showMenuBarExtra = loaded.showMenuBarExtra
        hideFromDockWhenClosed = loaded.hideFromDockWhenClosed
        hasCompletedOnboarding = loaded.hasCompletedOnboarding
        indicators = loaded.indicators
        indicatorRefresh = loaded.indicatorRefresh
        keepAwake = loaded.keepAwake
        protectedPaths = loaded.protectedPaths
        projectRoots = loaded.projectRoots
        installerFolders = loaded.installerFolders
        // `-LivIndicators cpu,network` shows those indicators for this launch (the probe and snapshots use it). The real list is
        // kept in `indicatorsToSave`, so the override is never written to settings.json.
        if let names = launchIndicators {
            let chosen = Set(names.split(separator: ",").compactMap { MetricKind(rawValue: String($0)) })
            indicatorsToSave = indicators
            indicators = indicators.map { var copy = $0; copy.enabled = chosen.contains($0.metric); return copy }
        }
    }

    var values: Settings {
        var settings = Settings(protectedPaths: protectedPaths, projectRoots: projectRoots, installerFolders: installerFolders)
        settings.moveToTrash = moveToTrash
        settings.dryRun = dryRun
        settings.previewBeforeCleaning = previewBeforeCleaning
        settings.skipRecentProjects = skipRecentProjects
        settings.showMenuBarExtra = showMenuBarExtra
        settings.hideFromDockWhenClosed = hideFromDockWhenClosed
        settings.hasCompletedOnboarding = hasCompletedOnboarding
        settings.indicators = indicatorsToSave ?? indicators
        settings.indicatorRefresh = indicatorRefresh
        settings.keepAwake = keepAwake
        return settings
    }

    // MARK: - Menu bar indicators

    var enabledIndicators: [IndicatorSetting] { indicators.filter(\.enabled) }

    /// True when anything of Liv Vitals sits in the menu bar: the health icon, the keep-awake cup or at least one indicator. The login item,
    /// hiding from the Dock and keeping the app alive after the window closes all depend on it.
    var hasMenuBarContent: Bool { showMenuBarExtra || keepAwake.showInMenuBar || indicators.contains { $0.enabled } }

    func indicator(_ metric: MetricKind) -> IndicatorSetting {
        indicators.first { $0.metric == metric } ?? IndicatorSetting(metric: metric)
    }

    /// Changes one indicator. A style the metric does not offer is ignored.
    func updateIndicator(_ metric: MetricKind, _ change: (inout IndicatorSetting) -> Void) {
        guard let index = indicators.firstIndex(where: { $0.metric == metric }) else { return }
        var updated = indicators[index]
        change(&updated)
        if !metric.styles.contains(updated.style) { updated.style = indicators[index].style }
        // Assign the whole array, and only when something changed: an in-place edit notifies observers even with an
        // equal value, and the menu bar items write back the value they just read, which would loop forever.
        guard updated != indicators[index] else { return }
        var copy = indicators
        copy[index] = updated
        indicators = copy
    }

    /// How a cleaning run should behave right now.
    var cleanOptions: CleanOptions {
        CleanOptions(
            moveToTrash: moveToTrash,
            dryRun: dryRun,
            whitelist: protectedPaths.map { URL(filePath: $0) },
            projectRoots: projectRoots.map { URL(filePath: $0, directoryHint: .isDirectory) },
            installerFolders: installerFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
        )
    }

    /// What a scan should read from Settings right now.
    var scanOptions: ScanOptions {
        ScanOptions(
            whitelist: protectedPaths.map { URL(filePath: $0) },
            projectRoots: projectRoots.map { URL(filePath: $0, directoryHint: .isDirectory) },
            skipRecentProjects: skipRecentProjects,
            installerFolders: installerFolders.map { URL(filePath: $0, directoryHint: .isDirectory) }
        )
    }

    // MARK: - Paths

    /// Adds a folder to the protected list. Returns why it was refused, or nil when it was added or already there.
    func addProtectedPath(_ input: String) -> SettingsPathError? {
        add(input, to: \.protectedPaths)
    }

    func removeProtectedPath(_ path: String) {
        protectedPaths.removeAll { $0 == path }
    }

    /// Adds a folder for Dev Projects to search. Refuses one that is protected or does not exist; the roots
    /// already saved are left alone.
    func addProjectRoot(_ input: String) -> SettingsPathError? {
        if case .success(let path) = SettingsPath.normalize(input, home: home) {
            if isProtected(URL(filePath: path, directoryHint: .isDirectory)) { return .protected(display(path)) }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return .doesNotExist
            }
        }
        return add(input, to: \.projectRoots)
    }

    /// Adds a folder for Installers to search. Refuses one that is protected (the Desktop is the exception, since
    /// installer files directly on it can be removed) or does not exist.
    func addInstallerFolder(_ input: String) -> SettingsPathError? {
        if case .success(let path) = SettingsPath.normalize(input, home: home) {
            let isDesktop = path == home.appending(path: "Desktop").standardizedFileURL.path
            if !isDesktop, isProtected(URL(filePath: path, directoryHint: .isDirectory)) { return .protectedForInstallers(display(path)) }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return .doesNotExist
            }
        }
        return add(input, to: \.installerFolders)
    }

    func removeInstallerFolder(_ path: String) {
        installerFolders.removeAll { $0 == path }
    }

    /// Puts every setting back to its default except the onboarding flag, which is not a preference. The log and
    /// the administrator rule are not touched.
    func resetToDefaults() {
        let defaults = Settings.defaults(home: home)
        moveToTrash = defaults.moveToTrash
        dryRun = defaults.dryRun
        previewBeforeCleaning = defaults.previewBeforeCleaning
        skipRecentProjects = defaults.skipRecentProjects
        showMenuBarExtra = defaults.showMenuBarExtra
        hideFromDockWhenClosed = defaults.hideFromDockWhenClosed
        indicators = defaults.indicators
        indicatorRefresh = defaults.indicatorRefresh
        keepAwake = defaults.keepAwake
        protectedPaths = defaults.protectedPaths
        projectRoots = defaults.projectRoots
        installerFolders = defaults.installerFolders
    }

    /// True when cleaning can never act inside `folder`, or when it holds protected places (the home folder).
    private func isProtected(_ folder: URL) -> Bool {
        do {
            _ = try SafetyGuard(home: home, allowedRoots: []).validate(folder)
            return false
        } catch {
            switch error {
            case .protected, .containsProtected: return true
            default: return false
            }
        }
    }

    private func display(_ path: String) -> String {
        if path == home.path { return "~" }
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    func removeProjectRoot(_ path: String) {
        projectRoots.removeAll { $0 == path }
    }

    private func add(_ input: String, to list: ReferenceWritableKeyPath<AppSettings, [String]>) -> SettingsPathError? {
        switch SettingsPath.normalize(input, home: home) {
        case .failure(let error):
            return error
        case .success(let path):
            if !self[keyPath: list].contains(path) { self[keyPath: list].append(path) }
            return nil
        }
    }

    // MARK: - Saving

    /// Saves now instead of waiting for the delay, e.g. before the app quits.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        try? store.save(values)
    }

    private func changed() {
        saveTask?.cancel()
        saveTask = Task { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            flush()
        }
    }
}
