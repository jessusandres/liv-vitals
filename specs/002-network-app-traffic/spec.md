# Feature Specification: Per-app network traffic and network details

**Feature Branch**: `feat/network-apps`
**Created**: 2026-11-09
**Status**: Draft
**Input**: "On the network item, can I see how much traffic goes out per app? Something more detailed." Approved scope: (1) top apps by traffic, (2) interface, local IP, session totals and separate ↓/↑ peaks.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Which apps use the network (Priority: P1)

The user opens the NET indicator panel and expands "Top apps". They see up to 8 apps with icon, name, and current download and upload rate, busiest first. The list updates every second while the fold is open.

**Independent Test**: start a large download in a browser, open NET ▸ Top apps; the browser is first with a ↓ rate close to the bar's total.

**Acceptance Scenarios**:

1. **Given** the NET panel is open and "Top apps" is expanded, **When** a second passes, **Then** up to 8 apps are listed with ↓ and ↑ per second, sorted by ↓+↑.
2. **Given** no app moved data in the last second, **When** the fold is open, **Then** it says "No network activity".
3. **Given** the fold is closed or the panel is closed, **Then** no per-app sampling runs.
4. **Given** the per-app tool is missing or fails, **Then** the fold says the list is unavailable; the rest of the panel works.

### User Story 2 - Network details (Priority: P2)

The NET panel shows, in a "Details" fold: the active interface (Wi-Fi, Ethernet, VPN, or its BSD name), the local IPv4 address, the total downloaded and uploaded since Liv Vitals started, and the last-minute peak for download and upload separately.

**Independent Test**: on Wi-Fi, Details shows "Wi-Fi", an address like 192.168.x.x, totals that grow, and two peaks.

**Acceptance Scenarios**:

1. **Given** the Mac is on Wi-Fi, **Then** Details shows "Wi-Fi" and its IPv4 address.
2. **Given** a VPN is the default route, **Then** the interface shows "VPN" (utun/ipsec/ppp).
3. **Given** the Mac is offline, **Then** interface and address show "—".

### Edge Cases

- A process exits between samples: it simply disappears from the list.
- Processes with the same name (helpers): listed separately by pid, as in the CPU list.
- Very small rates show as "0 KB/s"; rows with 0 ↓ and 0 ↑ are hidden.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The NET panel MUST offer a "Top apps" fold listing up to 8 processes with icon, name, ↓/s and ↑/s, sorted by total.
- **FR-002**: Per-app sampling MUST run only while that fold is visible and expanded, at most once per second, without admin rights.
- **FR-003**: The NET panel MUST offer a "Details" fold with interface kind, local IPv4, session totals ↓/↑ and last-minute peak ↓/↑.
- **FR-004**: No network requests are made to obtain any of this (no public IP, no SSID).
- **FR-005**: Failures degrade to a plain message, never a crash or an empty panel.

### Key Entities

- **NetworkAppUsage**: pid, name, bytes in/s, bytes out/s.
- **NetworkDetails**: interface kind and name, IPv4, session totals, per-direction series.

## Success Criteria *(mandatory)*

- **SC-001**: During a download, the top app's ↓ rate is within 20% of the NET indicator's total.
- **SC-002**: With the fold closed, Liv Vitals' idle CPU is unchanged (within 0.1 percentage points).
- **SC-003**: Existing tests pass; new tests cover parsing the per-app output and the interface classification.

## Assumptions

- Per-app traffic comes from macOS's `nettop` in delta mode, as Vorssaint (GPL-3, same author) does; its parser may be adapted.
- "Session" means since Liv Vitals started sampling, not since boot.
- The "Last minute" fold is replaced by the new "Details" fold.
