# Implementation Plan: Keep awake

**Branch**: `feat/keep-awake` | **Date**: 2026-11-09 | **Spec**: [spec.md](./spec.md)

## Summary

A cup menu bar item and a "Keep Awake" section in Settings hold two IOKit assertions: PreventUserIdleSystemSleep and PreventUserIdleDisplaySleep.
- Sessions are timed or indefinite.
- Automation can start a session from the external display, the power adapter or running apps (any of them). The checks run on events.
- "Pause while locked" freezes the remaining time while the screen is locked.
- The pure logic lives in LivCore. The IOKit, AppKit and notification glue lives in LivVitals.
- Base: `~/personal/coffe-awake` (PowerAssertions, SessionDuration, AwakeController). From Vorssaint `KeepAwakeManager` we take only the condition sources and the lock/suppression rules.

## Verified facts

- **Scenes.** Menu bar items are `MenuBarExtra(isInserted:)` scenes declared in `LivVitals/App/LivVitalsApp.swift`. Each indicator is a `Scene` struct in `LivVitals/Features/Monitor/IndicatorScenes.swift`.
- **Settings.** Settings is one `Form` with `Section`s (`LivVitals/Features/Settings/SettingsView.swift`), so there are no separate pages. "Page" here means a new `Section`, built the way `IndicatorsSettingsSection` is.
- **Persistence.**
  - `LivCore/Sources/LivCore/Settings.swift` declares the fields. `SettingsStore.load()` maps an all-optional `Stored` struct, falls back to defaults field by field, and uses `Lossy` for array entries.
  - `currentSchemaVersion = 4`.
  - `AppSettings` (`LivVitals/Features/Settings/AppSettings.swift`) mirrors each field with `didSet { changed() }` and has `onIndicatorsChanged`-style hooks.
- **Quitting with the window closed.** `AppSettings.hasMenuBarContent` feeds `DockPresence`. `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` re-reads `SettingsStore.standard()`. Both must know about the cup.
- **Services.** `ServiceContainer` has `.live` and `.mock`, and tests and snapshots use `.mock`. Nothing in the app creates IOKit assertions yet.
- **Power.** `SystemReaders.battery()` already uses `IOPSCopyPowerSourcesInfo`, but it returns nil on Macs without a battery. Use `IOPSGetProvidingPowerSourceType(nil) == kIOPMACPowerKey` instead, which also works on desktops.
- **Project files.** The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so new files need no pbxproj edits.
- **Other keep-awake apps.** Neither coffe-awake nor Vorssaint is running now (`pgrep`). Assertions are reference-counted per process by powerd, so several holders stack. Releasing ours never touches theirs, and the Mac stays awake while any app holds one. **There is no conflict.** Vorssaint's clamshell `pmset disablesleep` is its own and we do not touch it.

## Design decisions

- **Label refresh: once a minute, never per second.**
  - The label shows compact time ("45m", "2h", rounded up, as coffe-awake does), which changes at most once a minute.
  - One `Task` sleeps until `state.nextDeadline(now)`: the earlier of the session end and the next minute boundary of the remaining time.
  - When the session is off, indefinite or paused, nothing is scheduled. Idle cost is therefore zero, apart from one wake-up a minute during a timed session.
  - A per-second refresh while the menu is open is skipped: the `.menu` style renders an NSMenu snapshot, and the Settings state line ("1 h 12 min more") also has minute precision.
  - Times are wall-clock `Date`s, re-checked on `NSWorkspace.didWakeNotification`. The time a closed lid spends asleep counts (spec edge case).
- **Effective state.** `active = (manual session alive || (automation holds && !suppressed)) && !(locked && pauseWhileLocked)`.
  - Turning the switch off while automation holds sets `suppressed` (Vorssaint's `automationSuppressedUntilConditionsClear`). Without it, a user on the power adapter could never turn keep awake off.
  - `suppressed` clears when no condition holds.
- **Applications matching.** Apps match by bundle id. An empty list never matches. "Any" is the only rule (no "all" mode).

## Steps

1. **Pure logic in LivCore** `tdd`. Agent: coder.
   - New file `LivCore/Sources/LivCore/KeepAwake.swift`, with a GPL header noting the coffe-awake and Vorssaint origins.
   - `public enum KeepAwakeDuration: Int, Codable, CaseIterable, Sendable`. The raw value is minutes (15, 30, 60, 120, 240, 480), with 0 meaning indefinite. Add `var seconds: TimeInterval?`.
   - `public struct KeepAwakeSettings: Codable, Equatable, Sendable`:
     - Fields: `defaultDuration = .oneHour`, `externalDisplay = false`, `power = false`, `applications = false`, `bundleIDs: [String] = []`, `pauseWhileLocked = false`, `showInMenuBar = false`.
     - A custom `init(from:)` uses `decodeIfPresent` per field, and an unknown duration falls back to the default. This makes it lossy.
   - `public struct KeepAwakeState: Equatable, Sendable`, the state machine:
     - Fields: `manualEnd: Date??` (no session / indefinite / timed), `pausedRemaining: TimeInterval?`, `automationHolds`, `suppressed`, `locked`, `pauseWhileLocked`.
     - Mutating functions: `start(_:now:)`, `stop()`, `setAutomation(holds:)`, `setLocked(_:now:)` (freezes or resumes the remaining time), `tick(now:)` (expires the session).
     - Read-only: `wantsAssertions`, `remaining(now:) -> TimeInterval?`, `nextDeadline(now:) -> Date?`.
   - `public enum KeepAwakeAutomation` with `static func holds(_ s: KeepAwakeSettings, externalDisplay: Bool, onAC: Bool, runningBundleIDs: Set<String>) -> Bool` (the any-condition rule).
   - `static func compactRemaining(_ seconds: TimeInterval) -> String`, giving "Xm" or "Xh" rounded up and never less than "1m". It is language-neutral, so it adds no catalog entry.
   - New file `LivCore/Tests/LivCoreTests/KeepAwakeTests.swift`. Cases:
     - A timed session expires exactly at its end.
     - An indefinite session never expires.
     - `stop` clears the session.
     - No condition selected never holds.
     - `applications` on with an empty list never holds.
     - Any one condition holds.
     - A manual session overlapping automation lasts until both are off.
     - Stopping while automation holds suppresses it until the conditions clear.
     - Locking with `pauseWhileLocked` freezes the remaining time, and unlocking resumes it with the same remaining time.
     - Locking without the option changes nothing.
     - The lock pause applies to automation too.
     - `nextDeadline` is the minute boundary or the end, and nil when indefinite, off or paused.
     - `compactRemaining`: 14:59 gives "15m", 61 min gives "2h", 10 s gives "1m".
   - Verify: `make test`.

2. **Persistence**. Agent: coder.
   - `Settings.swift`: `public var keepAwake = KeepAwakeSettings()`.
   - `SettingsStore.swift`: schema 5 (update the doc comment), `Stored.keepAwake: KeepAwakeSettings?`, and `settings.keepAwake = stored.keepAwake ?? defaults.keepAwake`.
   - Add cases to `LivCore/Tests/LivCoreTests/SettingsStoreTests.swift`:
     - A v4 file gives the defaults.
     - A bad duration or a missing field keeps the other fields.
     - Values survive a round trip.
   - Verify: `make test`.

3. **App glue: assertions, conditions, model**. Agent: coder.
   - Assertions:
     - `LivVitals/Services/ServiceProtocols.swift`: `protocol PowerAssertionHolding: AnyObject { func acquire(reason:) throws; func release(); var isHeld: Bool { get } }`.
     - `LivVitals/Services/Live/LivePowerAssertions.swift`: adapted from coffe-awake `PowerAssertions.swift`, with both types, released in `deinit`.
     - A mock in `LivVitals/Services/Mock/MockServices.swift`.
     - Add `keepAwake` to `ServiceContainer` (`.live` real, `.mock` fake), so tests and snapshots never hold real assertions.
   - Conditions: `LivVitals/Features/KeepAwake/KeepAwakeConditions.swift`. Each source is attached only while its option is on:
     - `NSApplication.didChangeScreenParametersNotification` plus `CGGetOnlineDisplayList`/`CGDisplayIsBuiltin`.
     - `IOPSNotificationCreateRunLoopSource` plus `IOPSGetProvidingPowerSourceType`.
     - `NSWorkspace.shared` KVO on `\.runningApplications` (Vorssaint #1468: helper apps post no launch notifications).
     - `DistributedNotificationCenter` `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked`, attached only while `pauseWhileLocked` is on.
     - `NSWorkspace.didWakeNotification`, used for `tick`.
     - Events are debounced 0.1 to 0.35 s, as in Vorssaint. There is no polling.
   - Model: `LivVitals/Features/KeepAwake/KeepAwakeModel.swift`, `@Observable @MainActor`.
     - Holds `KeepAwakeState` and calls `acquire()` or `release()` whenever `wantsAssertions` flips.
     - Runs the single deadline `Task`.
     - Exposes `turnOn()` (default duration), `start(_:)`, `turnOff()`, `labelText`, `stateLine`. The state line uses `Duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))`.
     - Has an `errorMessage` that is set when `acquire` fails.
   - Wiring:
     - `AppStore` creates the model, and `settings.onKeepAwakeChanged` re-syncs it.
     - `AppSettings` gets a `keepAwake` field with `didSet` and the hook, plus entries in `values` and `init`.
     - `hasMenuBarContent` includes `keepAwake.showInMenuBar`.
     - `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` includes `keepAwake.showInMenuBar`.
     - `AppDelegate.applicationWillTerminate` releases the assertions. It reaches the store through a static/weak hook set in `LivVitalsApp.init`.
   - Tests in `LivVitalsTests/KeepAwakeModelTests.swift`, with the fake holder:
     - `turnOn` acquires the assertions, and `turnOff` releases them.
     - A failed `acquire` sets the error and leaves keep awake off.
     - A simulated lock with the option on releases the assertions, and unlock acquires them again.
     - Changing the settings attaches or detaches sources. Check this with a fake conditions provider behind a small protocol only if it stays under about 20 lines. Otherwise leave it to the manual check.
   - Verify: `make test-app`.

4. **Review**. Agent: reviewer. Read only steps 1 to 3: assertion lifetime, retain cycles in the C callbacks (`Unmanaged` context), and observers removed when they are turned off.

5. **UI design pass**. Main chat. Apply `frontend-design` and `emil-design-eng` to the section and the menu:
   - Native Form look.
   - The duration chips: a custom capsule row, or `Picker(.segmented)` with 7 segments.
   - Card style using the existing `CardModifier` in `LivVitals/DesignSystem/Components.swift`.
   - Motion for the switch and state line only, respecting reduce motion.

6. **Cup menu bar item and Settings section**. Agent: coder.
   - `LivVitals/Features/KeepAwake/KeepAwakeScene.swift`, a `MenuBarExtra(isInserted: settings.keepAwake.showInMenuBar)` in `.menu` style:
     - Label: `cup.and.saucer` or `cup.and.saucer.fill` plus `labelText`, with an accessibility label giving the state.
     - Menu: the state line, "Turn On" or "Turn Off", the 7 durations with a check on the current one, "Keep Awake Settings…" (`requestedModule = .settings`, as `IndicatorPanelView.open` does), and Quit.
     - Declared in `LivVitalsApp.body`.
   - `LivVitals/Features/Settings/KeepAwakeSettingsView.swift`, `KeepAwakeSettingsSection`, inserted after "Menu Bar" in `SettingsView`:
     - The switch and its state line.
     - The duration chips.
     - Three cards (External display, Power, Applications), each with an icon, a title, a one-line description and a toggle. The footer reads "Starts when any selected condition is active."
     - The Applications card lists the chosen apps. Each shows its icon from `NSWorkspace.urlForApplication(withBundleIdentifier:)` and is greyed with "Not installed" when that returns nil. The card has an "Add…" button and a remove button per app.
     - "Add…" opens an `NSOpenPanel` on `/Applications` with `[.application]` and multiple selection, reads `Bundle(url:)?.bundleIdentifier`, and skips duplicates and apps without an id.
     - "Pause while the Mac is locked".
     - "Show in the menu bar".
   - Add a `DebugSnapshots` scenario that shows this section (mock services).
   - Verify: `make strings`, `make check-strings`, `make snapshots` (look at the new image), `make verify`.

7. **Acceptance on the real Mac**. Main chat (read-only checks after `make install`).
   - `pmset -g assertions | grep -A1 -i "liv vitals"`:
     - With a 15-minute session on, both PreventUserIdleSystemSleep and PreventUserIdleDisplaySleep show.
     - After Turn Off they are gone.
     - After Quit they are gone.
   - Plug and unplug the adapter with Power selected.
   - Launch and quit an app from the list.
   - Lock and unlock (⌃⌘Q) with pause on, and check that the remaining time is unchanged.
   - `make perf`: idle CPU with keep awake on stays within 0.1 points of main (SC-002).

## Risks

- **Assertions leaked by a retained model.** The OS frees them on exit or crash, and the model releases them in `deinit` and in `applicationWillTerminate`.
- **The cup hidden while a session or automation runs.** With no menu bar content, closing the window quits the app and ends keep awake. That is accepted, but see question 2.
- **Lock notifications.** `com.apple.screenIsLocked` is undocumented, though stable for years and used by Vorssaint. If it ever stops arriving, the only effect is no pause.
- **The schema bump to 5.** An older build reading a v5 file falls back to its defaults (`load()` rejects newer versions). This is existing behavior and the file is untouched until the next save.
- **Rollback.** All changes are on this branch. The new files are additive. The settings field is optional, so a downgrade loses only the keep-awake choices.

## Skipped (spec or brief)

Mouse jiggle, keyboard shortcuts, the notch strip, the icon picker, the "all conditions" mode, clamshell or `pmset` changes, battery-protection cut-off, "extend session", resuming a session after relaunch (FR-003), and a per-second countdown.

## Open questions (proposed defaults)

1. `showInMenuBar` default. The brief says "defaults off", but an off cup is hard to discover. **Proposed: off, like the indicators.** Settings is the way in.
2. Should a running session or automation keep the app alive when the window closes and the cup is hidden? **Proposed: no, keep the current rule.** Show a footer note when automation is on and the cup is hidden.
3. Default duration. **Proposed: 1 h.**
4. The switch with automation holding: turning it off suppresses until the conditions clear. **Proposed: yes**, with the state line "Off until the condition clears".
5. Duration chips: a custom capsule row (matches the screenshot) or a segmented Picker (native, less code). **Proposed: segmented Picker**, unless the design pass in step 5 says otherwise.
