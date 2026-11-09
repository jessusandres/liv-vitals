# Implementation Plan: Per-app network traffic and network details

**Branch**: `feat/network-apps` | **Date**: 2026-11-09 | **Spec**: [spec.md](./spec.md)

## Summary

The NET panel (`IndicatorPanelView.details`, `case .network`) keeps its Download/Upload rows. Its "Last minute" fold is replaced by two folds:
- "Top apps": per-process rates from `nettop`, sampled only while this fold is open.
- "Details": interface, IPv4, session totals, and separate ↓/↑ peaks.

## Verified facts

- **nettop sampling.** `nettop -P -L 1 -n -x -J bytes_in,bytes_out` takes about 17 ms and almost no CPU, without root. Its counters are **cumulative** per pid. Lines look like `apsd.383,1659548,579092,` (trailing comma). The header is `,bytes_in,bytes_out,`, and there is no time column.
- **Why not delta mode.** `-d -L 2 -s 1` returns a delta in its second section, but it blocks for 1 s and costs about 1.46 s of CPU (0.33 user + 1.13 sys) per call. Vorssaint also uses `-L 1` and computes deltas between calls (`NetworkProcessDeltaTracker`). **Decision: `-L 1` plus our own delta.**
- **Process helper.** `ProcessCommandRunner` / `CommandRunning` (`LivCore/Sources/LivCore/CommandRunner.swift`) uses an absolute path, has a timeout and keeps at most 64 KB of output. Tests already have a fake: `FakeCommands` in `LivVitalsTests/TestSupport.swift`.
- **Sandbox.** The app target is not sandboxed (see the 001 plan, `ENABLE_APP_SANDBOX = NO`).
- **Current network totals.** `SystemReaders.network()` sums `en*` counters from `NET_RT_IFLIST2`. `MetricsAggregator.ingest` computes the rates with `rate(from:to:over:)`, which clamps counter resets to 0.
- **The ↓/↑ series already exist.** `MonitorModel.download` and `MonitorModel.upload` hold the last 60 samples, in MB/s. While the panel is open the model runs in `.full` mode at 1 s, so those 60 samples cover the last minute. **No new series is needed.**
- **Icon cache.** `MonitorModel.apply` calls `icons.keep(only:)` with the CPU and memory pids only. Without a change, it would evict network-app icons every second.
- **Folds.** `section(id,title)` keys its open state as `"network.<id>"` in `monitor.expandedPanelSections`. The panel calls `monitor.start` / `monitor.stop` on appear and disappear.
- **SystemConfiguration.** No current file in LivCore uses SystemConfiguration or `getifaddrs`.

## Steps

1. **nettop parser and delta in LivCore** `tdd`. Agent: coder.
   - New file `LivCore/Sources/LivCore/NetworkAppUsage.swift`, with a GPL header noting the Vorssaint origin.
   - `public struct NetworkAppUsage: Sendable, Equatable, Identifiable { pid, name, bytesInPerSecond, bytesOutPerSecond }`.
   - `enum NettopParser` with `static func parse(_ csv: String) -> [pid: (name, in, out)]`. Per line:
     - Split on `,`. Require at least 4 columns and an empty last column. A line cut off by the 64 KB limit is dropped this way.
     - `in` and `out` are columns `count-3` and `count-2`.
     - The name is everything before them, joined back with `,`.
     - The pid is the text after the **last** `.`.
     - The header line and malformed lines are skipped.
   - `public struct NetworkAppRates`, a delta tracker:
     - `mutating func rates(cumulative:at: ContinuousClock.Instant) -> [NetworkAppUsage]?`.
     - It returns nil on the first (priming) call.
     - A pid seen for the first time, or a counter that went down, counts as 0.
     - Rows with 0/0 are dropped. The result is sorted by in+out and capped at 8.
   - New file `LivCore/Tests/LivCoreTests/NetworkAppUsageTests.swift`. Cases:
     - The real sample line.
     - The header.
     - A name with dots (`com.apple.WebKit.Networking.812`).
     - A name with a comma (`Foo, Inc.77`).
     - A missing pid.
     - A truncated last line.
     - Priming returns nil.
     - The delta divided by the elapsed time.
     - A counter reset gives 0.
     - Sorting and the cap of 8.
   - Verify: `make test`.

2. **Interface classification and reader in LivCore** `tdd`. Agent: coder.
   - New file `LivCore/Sources/LivCore/NetworkInterface.swift`:
     - `public enum NetworkInterfaceKind { case wifi, ethernet, vpn, other }`.
     - A pure `static func classify(bsdName: String, isWiFi: Bool) -> NetworkInterfaceKind`:
       - `utun*`, `ipsec*` and `ppp*` give vpn.
       - `en*` gives wifi when `isWiFi`, ethernet otherwise.
       - Anything else gives other.
     - `public struct NetworkInterfaceInfo { kind, bsdName, ipv4: String? }`.
     - The reader `static func current() -> NetworkInterfaceInfo?`:
       - The primary interface comes from `SCDynamicStoreCopyValue("State:/Network/Global/IPv4")["PrimaryInterface"]`. It is nil when offline.
       - `isWiFi` is true when `SCNetworkInterfaceCopyAll()` has an entry with that BSD name whose type is `kSCNetworkInterfaceTypeIEEE80211`. Do not assume en0 is Wi-Fi: on desktops en0 is Ethernet.
       - The IPv4 address comes from `getifaddrs` (AF_INET on that name) plus `inet_ntop`.
   - Tests in `LivCore/Tests/LivCoreTests/NetworkInterfaceTests.swift`:
     - en0 with Wi-Fi gives wifi; en5 without gives ethernet; utun3, ipsec0 and ppp0 give vpn; bridge0 gives other.
     - A smoke test: `current()` either returns nil or a value whose `bsdName` is not empty.
   - Verify: `make test`. On this Mac (Mac16,7 on Wi-Fi, default route en0), `current()` gives `.wifi` and a 192.168/10.x style address.

3. **Snapshot plumbing for details and totals**. Agent: coder.
   - `LivCore/Sources/LivCore/MetricsModels.swift`, all new init parameters defaulted so existing call sites compile:
     - `RawMetrics` gets `networkInterface: NetworkInterfaceInfo? = nil`.
     - `MetricsSnapshot` gets `networkInterface`, plus `receivedBytes: UInt64 = 0` and `sentBytes: UInt64 = 0` (bytes moved since the previous reading).
   - `MetricsAggregator.ingest`: fill `receivedBytes` and `sentBytes` from the same deltas that `rate` uses, with a reset counting as 0. Pass the interface through.
   - `SystemSampler.read`: `networkInterface: includeProcesses ? NetworkInterfaceInfo.current() : nil`, so it is read only when a panel or window is open.
   - `MonitorModel`:
     - Add `private(set) var sessionReceived: UInt64` and `sessionSent: UInt64`.
     - `apply` adds the snapshot's deltas to them.
     - "Session" means since the app started. The first snapshot of each stream is skipped, so the totals undercount by about 1 s per mode switch. Note it with a `shortcut:` comment.
   - Test: a new `MetricsTests` case checking that the moved bytes match the counter delta and that a reset gives 0.
   - Verify: `make test`, `make test-app`.

4. **Per-app sampling loop in MonitorModel**. Agent: coder.
   - `MonitorModel`:
     - Change the init to `init(service:, commands: any CommandRunning = ProcessCommandRunner())`. Existing callers, `AppStore.swift:28` and the tests, stay unchanged.
     - Add `private(set) var networkApps: [NetworkAppUsage]?`. nil means "Loading…".
     - Add `private(set) var networkAppsFailed = false`.
     - Add `func sampleNetworkApps() async`, a loop until the task is cancelled:
       - Run `/usr/bin/nettop` with `-P -L 1 -n -x -J bytes_in,bytes_out` and a 2 s timeout.
       - On a throw, a non-zero status or empty output, set `networkAppsFailed`. Throwing nettop must not break the panel.
       - Otherwise parse the output and feed `NetworkAppRates`.
       - `try? await Task.sleep(for: .seconds(1))`, which gives at most 1 run per second.
       - On exit, reset the tracker and set `networkApps = nil`.
     - Skip the loop when `service.isSimulated`, so previews and snapshots never run nettop.
     - `apply`'s `icons.keep(only:)` also keeps `networkApps` pids.
   - App tests in `LivVitalsTests/MonitorModelTests.swift` using `FakeCommands` (extend it with a scripted sequence of outputs if needed):
     - Two outputs give rates.
     - A throwing runner sets `networkAppsFailed`.
     - Cancelling the task stops the calls (the call count stops growing).
   - Verify: `make test-app`.

5. **UI direction** (no code). Agent: main chat.
   - Apply `frontend-design` and `emil-design-eng` only to confirm reuse of the existing `processList` row look: 16 pt icon, name, monospaced trailing text "↓ 1.2 MB/s ↑ 40 KB/s", in one line or two stacked.
   - No new motion: the existing fold animation and Reduce Motion handling apply.

6. **NET panel folds**. Agent: coder. File: `LivVitals/Features/Monitor/IndicatorScenes.swift`.
   - `case .network`:
     - Keep the Download and Upload rows.
     - `section("apps", "Top apps")`:
       - "Per-app traffic is unavailable." when `networkAppsFailed`.
       - "Loading…" when `networkApps` is nil.
       - "No network activity" when it is empty.
       - Otherwise one row per app with `monitor.icons.icon(for:)`. Adapt it with a `ProcessUsage(pid:name:cpuPercent:0,memoryBytes:0)` or add an icon overload by pid; prefer the smallest of the two.
       - Accessibility label: "<name>, download X, upload Y".
     - `section("details", "Details")`:
       - Interface: Wi-Fi, Ethernet or VPN, otherwise the BSD name, otherwise "—".
       - IPv4, or "—".
       - "Downloaded" and "Uploaded" as session totals, using `ByteCountFormatter` with `.decimal`.
       - "Peak ↓" and "Peak ↑" from `monitor.download.map(\.value).max()` and the same for upload. Those values are MB/s, so multiply by 1e6 and pass to `MonitorModel.rateText`.
     - Remove the "minute" fold.
   - Sampling gate, on the panel root:
     - `.task(id: metric == .network && monitor.expandedPanelSections.contains("network.apps")) { if that is true { await monitor.sampleNetworkApps() } }`.
     - The task is cancelled when the fold closes or the panel disappears, which gives FR-002 and acceptance 1.3. Using the `.task` modifier avoids relying on whether `DisclosureGroup` mounts content while it is collapsed.
   - Strings: run `make strings`, then `make check-strings`. Remove the orphaned "Last minute", "Peak" and "Average" entries only if nothing else uses them.
   - Verify: `make verify`.
   - Manual check, when the user wants it (the walkthrough is deferred to Stage 9):
     - Open the fold and confirm with `pgrep -fl nettop` or `ps` that a nettop process appears once per second.
     - Close the fold and confirm that none appear.

7. **Review**. Agent: reviewer (or `/codex:review` from 2026-11-17). Scope: the diff of steps 1 to 6, with focus on task cancellation and the parser edge cases.

## Risks

- **Truncated names.** nettop names may be cut to the 16-character `p_comm` (for example `com.apple.WebKi`). The icon still resolves by pid through `NSRunningApplication`. The display name could later be taken from `NSRunningApplication.localizedName`; this is skipped for now.
- **What nettop counts.** It counts socket bytes, interface counters count `en*` only, and VPN traffic goes through `utun`. So the top app can differ from the NET total when a VPN is on, which affects SC-001 with a VPN.
- **Cancellation.** A `.task` that is not cancelled would leave nettop running once per second. The cancellation test in step 4 and the manual `ps` check guard against that.
- **Primary interface for VPNs.** `PrimaryInterface` reflects the primary service. A split-tunnel VPN stays on en0 and shows "Wi-Fi". This is acceptable: the spec says "VPN is the default route".
- **Rollback.** All new code sits in new files plus defaulted fields. Reverting the branch commits is enough, and there is no data migration.

## Skipped

- Grouping helpers under their parent app.
- External-only filtering (`-t external`).
- Vorssaint's lease and 5 s cadence, and its "keep the last rows when empty" cache.
- Public IP and SSID (FR-004).
- IPv6.
- A new ↓/↑ series (the existing `download` and `upload` are reused).

## Success criteria

- `make verify` is green.
- `make check-strings` is clean.
- The new parser and classification tests pass.
- With the fold closed, no nettop process is spawned.
- Files outside the ones listed above are unchanged.

## Open questions

1. Row layout for each app: should ↓ and ↑ sit on one line or two? The panel is 340 pt wide. Default proposal: one line, "↓ x  ↑ y".
2. In simulated mode, "Top apps" shows "No network activity". Is that acceptable, or does it need mock rows for snapshots?
3. Should "Peak ↓/↑" read from the last 60 samples even when the panel just opened after light mode? In that case some samples are 2–5 s apart, so the window covers more than one minute. The current "Last minute" fold already behaves this way.
