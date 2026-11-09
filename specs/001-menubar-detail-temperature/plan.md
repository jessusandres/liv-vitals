# Implementation Plan: Detailed menu bar panels and a temperature indicator

**Branch**: `001-menubar-detail-temperature` | **Date**: 2026-11-09 | **Spec**: [spec.md](./spec.md)

## Summary

Two changes, both in the per-metric menu bar panels (`IndicatorPanelView`). The combined `MenuBarView` and the widgets stay as they are.
1. Each panel gets a usage bar, a faint 100 % guide on its chart, and collapsible sections that start folded. Their open state lives in memory for the app session.
2. A new `MetricKind.temperature` indicator. It reads CPU, GPU and battery °C from the **SMC** (AppleSMC IOKit user client), adapted from Vorssaint's `SMCClient` and `TemperatureSensorSelector`. It reads sensors only while the temperature indicator is enabled.

**Sensor approach decision**: Vorssaint reads temperatures from the SMC, not HID. Its `Sources/HIDEventSystem` module map is only imported by `MouseAccelerationService`/`MouseAccelerationRecovery`. So **no module map, no bridging header and no private HID API** are needed. The SMC path uses only `IOKit`, which LivCore already imports (`SystemReaders.swift`, `SystemRegistryReaders.swift`). It has a verified per-chip key map for this Mac ("Apple M4 Pro", Mac16,7 -> `appleM4ProFamily`). On Intel or unmapped chips it falls back to the hottest plausible `Tp*`/`Te*` key. If `AppleSMC` cannot be opened, it returns nil and the bar shows "—".

**Sandbox/entitlements**: the app target has `ENABLE_APP_SANDBOX = NO` and hardened runtime, with no app entitlements file (`LivVitals.xcodeproj/project.pbxproj`). Opening AppleSMC for reads needs no entitlement there. The widget extension is sandboxed (`LivVitalsWidgetsSupport/LivVitalsWidgets.entitlements`) but never calls the reader.

## Technical Context

- Swift 6 package `LivCore` (macOS 14) plus the app target `LivVitals.xcodeproj`. SwiftUI, Charts, IOKit.
- Tests: `make test` (`swift test --package-path LivCore`), `make test-app` (xcodebuild test), `make verify` (both + build), `make check-strings` / `make strings` (String Catalog `LivVitals/Localizable.xcstrings`).
- Constitution: `.specify/memory/constitution.md` is still the unfilled template, so there are no gates.

## Verified facts this plan relies on

- `MetricKind` is exhaustive in: `LivCore/Sources/LivCore/Indicators.swift` (title, shortTitle, symbol, `IndicatorFormatter.value`), `LivVitals/DesignSystem/LocalizedTitles.swift` (`localizedTitle`), `LivVitals/Features/Monitor/IndicatorImage.swift` (`MetricKind.color`) and `LivVitals/Features/Monitor/IndicatorScenes.swift` (`details`). Settings (`IndicatorsSettingsView.swift`) iterates `MetricKind.allCases`, so the new row appears without changes. `AppSettings` only uses `rawValue`/lookups.
- Widgets: `LivCore/Sources/LivWidgetsUI/WidgetKinds.swift` switches over `WidgetKind`, not `MetricKind`. Its `metric` only ever returns `.disk`/nil. **Temperature is excluded from widgets with no code change.**
- `IndicatorSetting.normalized` fills missing metrics with an off default. Old settings files get `.temperature` disabled. `LivCore/Tests/LivCoreTests/IndicatorSettingsTests.swift:61` expects `count == 7`.
- The panel exists only while its `MenuBarExtra` is inserted (= the indicator is enabled). So "temperature indicator enabled" covers both the bar and its panel.
- The panel `onAppear` calls `monitor.start()`, which puts `MonitorModel` in `.full` mode (1 s, with processes). Light mode is `includeProcesses: false`.
- `MetricsAggregator.processCount = 5`, sorted by CPU only. `MonitorView.processesCard` shows all `model.processes` in a fixed 110 pt frame.
- `MetricsProviding.snapshots(every:includeProcesses:)` has three conformers: `LiveMetrics`, `MockMetrics`, `FakeMetrics` (`LivVitalsTests/TestSupport.swift`).
- There is no per-process GPU data anywhere in LivCore. Vorssaint's `ProcessUsageService.topGPU` is a separate, heavy subsystem.

## Steps

0. **UI direction (no code)**: apply `frontend-design` + `emil-design-eng`. Decisions to pin:
   - Native `DisclosureGroup` (its chevron rotates; it gives VoiceOver expanded/collapsed state).
   - Ease-out ≤ 200 ms; no animation under Reduce Motion.
   - `ProgressView(value:)` tinted with `metric.color` as the usage bar.
   - Temperature tiles as three small stat blocks.

   Agent: main chat. Verify: decisions noted in the step 6 prompt.

1. **Pure temperature logic in LivCore** `tdd`. Agent: coder.
   - New `LivCore/Sources/LivCore/Temperature.swift` (GPL header noting the Vorssaint origin, as `HardwareReadings.swift` does). It contains:
     - `public struct TemperatureReading { cpu: Double?, gpu: Double?, battery: Double?, sensors: [Sensor(name, celsius)] }`.
     - A port of `TemperatureSensorSelector`: platform from brand string, core-key sets, `isCPUTemperatureKey`, `displayedCPUTemperature`, `stabilizedTemperature` + `CachedSensorReading`, and the plausible range.
     - The `decode` half of `SMCValueCodec` only (no encode/write).
   - New `LivCore/Tests/LivCoreTests/TemperatureTests.swift`:
     - 0, negative, < 10 and ≥ 125 are rejected.
     - Mapped core keys win over hotter non-core keys.
     - Fallback to the hottest plausible key when no core key answers.
     - "Apple M4 Pro" -> `appleM4ProFamily`, "Intel…" -> generic.
     - Stabilisation keeps the last value for ≤ 4 misses within maxAge, then nil.
     - sp78/flt/fpe2 decoding.
   - Verify: `make test` green.

2. **SMC reader + data path**. Agent: coder.
   - New `LivCore/Sources/LivCore/SMCTemperatureSampler.swift`:
     - Read-only port of `SMCClient`: `init?`, `keys(where:)`, `readBytes`, `readValue`, `SMCParamStruct` and friends. Drop `writeValue`/`writeBytes`/`cmdWriteKey`.
     - `public final class SMCTemperatureSampler: @unchecked Sendable` with an `OSAllocatedUnfairLock` (same pattern as `TopProcessSampler`). Its `read(detailed: Bool) -> TemperatureReading?`:
       - Key discovery runs once per process in a static lock-protected cache (`shortcut:` comment), so a full/light stream switch does not enumerate every SMC key again.
       - Light mode reads only the preferred CPU keys. Detailed mode also reads GPU (`Tg*`) and battery (`TB?T`) keys and fills `sensors`.
       - The stabilisation caches live in the instance.
   - `MetricsModels.swift`: add `temperature: TemperatureReading? = nil` to `RawMetrics` and `MetricsSnapshot` (defaulted init params, so existing call sites compile).
   - `MetricsAggregator.swift`: pass it through.
   - `SystemSampler.swift`: add `temperatures: SMCTemperatureSampler? = nil`. In `read`, call `temperatures?.read(detailed: includeProcesses)`.
   - Verify: `make test` green. Add one throwaway check (or a test that tolerates nil): on this Mac, `SMCTemperatureSampler().read(detailed: true)?.cpu` is in 10..<125.

3. **Top apps data**. Agent: coder.
   - `MetricsAggregator.swift`: `processCount = 8`. Add `topMemoryProcesses` (top 8 by `memoryBytes`) to `MetricsSnapshot`.
   - `MonitorView.processesCard`: show `model.processes.prefix(5)` so the Monitor screen does not change.
   - `MonitorModel.apply`: `icons.keep(only:)` gets the union of both lists' pids.
   - Expose `memoryProcesses` on `MonitorModel`.
   - `MockMetrics` fills the new list.
   - Verify: a new `MetricsTests` case (memory order, cap 8). `make test`, `make test-app`.

4. **`MetricKind.temperature` + formatting**. Agent: coder.
   - `Indicators.swift`:
     - New case (last, so the stored order is unchanged).
     - Title "Temperature", shortTitle "TMP", symbol `thermometer.medium`.
     - `styles` = `[.number, .chart, .icon]`, default `.number`.
     - Formatter: `snapshot.temperature?.cpu` -> text `"59°"`, `fraction: nil`, `chartValue: °C`, spoken "Temperature, 59 degrees Celsius". nil -> `unavailable`.
     - Fix the "seven" comments.
   - `LocalizedTitles.swift`: add the case.
   - `IndicatorImage.swift`: `MetricKind.color` (warm orange/red).
   - `IndicatorScenes.swift` `details`: add a placeholder case (filled in step 6).
   - `LivVitalsApp.swift`: add `IndicatorScene(store: store, metric: .temperature)` inside the existing `Group` (8 children, under the builder limit).
   - Tests:
     - `IndicatorsTests` (°C rounding, "—" when nil, spoken text, styles exclude bars/gauge/speed).
     - `IndicatorSettingsTests` (count 8; an old 7-entry list decodes with temperature off; a stored `.gauge` style for temperature falls back to `.number`).
     - Check `LivVitalsTests/IndicatorImageTests.swift` still passes for the new case.
   - Verify: `make test`, `make test-app`.

5. **Sample sensors only when the indicator is on**. Agent: coder.
   - `ServiceProtocols.swift`: the requirement becomes `snapshots(every:includeProcesses:includeTemperature:)`. The extension keeps the two-argument overloads (passing `false`).
   - `LiveMetrics`: `SystemSampler(processes: …, temperatures: includeTemperature ? SMCTemperatureSampler() : nil)`.
   - `MockMetrics`: a random-walk temperature when asked.
   - `FakeMetrics`: record the flag.
   - `MonitorModel.setIndicatorRefresh(seconds:temperature:)`: the flag is part of the "wanted" comparison, so toggling it restarts the stream.
   - `AppStore.syncIndicatorSampling`: pass `settings.indicator(.temperature).enabled`.
   - Tests in `MonitorModelTests`: enabling or disabling the indicator opens a stream with the matching flag. Other indicators alone never request temperature.
   - Verify: `make test-app`.

6. **Richer panels** (`IndicatorScenes.swift` only, plus strings). Agent: coder, with step 0 decisions.
   - Usage bar under the header when `value.fraction != nil`.
   - `RuleMark(y: 100)` at low opacity for non-throughput charts. For temperature the ceiling is `max(100, values.max())`.
   - Session open state: `var expandedPanelSections: Set<String>` on `MonitorModel` (observable, not persisted), keyed `"<metric>.<section>"`. A small private `section(_ id:, _ title:, content:)` helper wraps `DisclosureGroup(isExpanded:)`.
   - Sections:
     - **CPU**: Top apps (icon via `monitor.icons`, name, CPU %).
     - **RAM**: Top apps by memory (`ByteCountFormatter` `.memory`).
     - **GPU**: "GPUs" listing each `GPUReading.devices` entry with utilization and memory in use. When there is no GPU, show the existing message and no sections.
     - **Disk**: "Activity" (read/write from `diskActivity`).
     - **Disk activity**: "Storage" (used/free).
     - **Network**: "Last minute" (peak ↓/↑ from `series[.network]`).
     - **Battery**: "Details" (health, cycle count moved in). See open question 3.
     - **Temperature**: CPU/GPU/Battery tiles (battery only if present), chart, "Sensors" section listing `reading.sensors`. When nil: "Temperatures are not available on this Mac."
   - An empty process list shows "Loading…".
   - Run `make strings` to add the new English keys to `Localizable.xcstrings`.
   - Verify: `make verify`, `make check-strings`. Manual: open CPU, expand Top apps, close and reopen, still expanded. Quitting resets it.

7. **Review**. Agent: reviewer (or `/codex:review` from 2026-11-17). Scope: the full diff, focusing on SMC struct layout/ABI, lock use, the sampling gate and the panel's accessibility.

8. **Acceptance checks**. Agent: main chat.
   - SC-002: run Vorssaint and Liv Vitals side by side, idle and under `yes > /dev/null` load. The CPU °C values are within 5 °C.
   - SC-003: Release build launched with `-LivIndicators cpu` vs `-LivIndicators cpu,temperature`, no panel open. Compare `ps -o %cpu` averaged over 60 s; the difference is ≤ 0.5 pp.
   - FR-005: with temperature off, no `SMCTemperatureSampler` is ever created (MonitorModelTests flag + a breakpoint/log check).

## Risks

- **SMC ABI**: a wrong `SMCParamStruct` layout returns garbage or errors, never a crash, if guarded. The `MemoryLayout` stride must be 80 (add an assert in tests). Reads only; no write code is ported.
- **Wrong sensor on another chip**: the fallback shows the hottest plausible key. That is accepted, the same behaviour as Vorssaint.
- **Cost**: discovery enumerates every SMC key once (tens of ms, off the main thread, inside the sampling task). Light mode reads about 16 keys every 2 s.
- **Process list growth 5 -> 8** affects only the panel; the Monitor stays at 5 via `prefix(5)`.
- **Protocol signature change** touches 3 conformers. The defaulted overload keeps `AppStore.firstReading` unchanged.
- **Rollback**: everything is additive. Revert the branch. Stored settings with a `temperature` entry decode on older builds? **No**: an older build would fail to decode an unknown `MetricKind` raw value. See open question 4.

## Explicitly skipped

Fahrenheit, fans, alerts, per-core graphs, per-process GPU "Top apps", widgets for temperature, persisted (cross-launch) open state, HID sensor path and its module map, SMC writes, changes to `MenuBarView`, indicator reordering UI (none exists today).

## Success criteria

`make verify` and `make check-strings` are green. The new `TemperatureTests` and the formatting/settings tests pass. The temperature indicator shows °C on this Mac within 5 °C of Vorssaint, and "—" when the sensors fail. Every panel has at least one folded section, and its state survives reopening the panel. Widget files are unchanged.

## Open questions

1. **GPU "Top apps" (FR-002)**: there is no per-process GPU source. Accept a "GPUs" device section instead, or port Vorssaint's `topGPU` (large, separate task)?
2. **Sensor value range**: the spec says ignore ≤ 0 and > 130 °C. Vorssaint, which SC-002 compares against, uses 10 ≤ v < 125. Which should apply? The plan uses Vorssaint's range.
3. **Extra sections for Disk, Disk activity, Network and Battery**: the proposed contents are listed in step 6. Should Battery's existing health/cycle rows move into the fold, or stay visible with something else in the fold?
4. **Downgrade safety**: a settings file saved with `temperature` may break `IndicatorSetting` decoding in older builds. Is that acceptable, or should older builds be tolerant first? (Not checked: how `SettingsStore` handles a failed array decode.)
5. **FR-004 "order"**: indicators have no ordering UI today, and the menu bar order is the macOS placement. Is "order" out of scope?
6. **Sensor names in the "Sensors" list**: raw SMC keys (e.g. "CPU · Tpx0") or a friendlier mapping (more code)?
7. **Menu bar short label**: "TMP", or a thermometer icon only?
