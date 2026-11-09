# Feature Specification: Detailed menu bar panels and a temperature indicator

**Feature Branch**: `001-menubar-detail-temperature`
**Created**: 2026-11-09
**Status**: Draft
**Input**: "Make the detail of the menu bar items more detailed, and show the device temperature in the menu bar, with a collapsible view like Vorssaint's."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Richer panel for each menu bar indicator (Priority: P1)

A user clicks a Liv Vitals indicator in the menu bar (CPU, RAM, GPU, Disk, Disk activity, Network, Battery). The panel shows the current value, a history chart with a 100% guide, a usage bar, and the breakdown rows it shows today, plus collapsible sections they can open for more: the apps using the most of that resource, and extra readings. Sections start folded so the panel stays short.

**Why this priority**: it is the main ask and works on every Mac, with or without sensors.

**Independent Test**: open the CPU indicator, expand "Top apps", see up to 8 apps with their icon and CPU %; collapse it again; reopen the panel and the section is in the same state.

**Acceptance Scenarios**:

1. **Given** the CPU indicator is on, **When** the user opens its panel, **Then** it shows now/average values, a usage bar, the chart, and a folded "Top apps" row with a chevron.
2. **Given** the panel is open, **When** the user clicks a folded row, **Then** it expands with an animation and the chevron turns down; clicking again folds it.
3. **Given** the RAM panel, **When** "Top apps" is expanded, **Then** apps are sorted by memory and show human sizes (e.g. 4.54 GB).
4. **Given** a Mac without GPU stats, **When** the GPU panel opens, **Then** it says so and shows no empty sections.

### User Story 2 - Temperature in the menu bar (Priority: P1)

A user turns on a new "Temperature" indicator in Settings ▸ Menu bar. The menu bar shows the CPU temperature (e.g. "59°") in the same styles the other indicators offer that make sense for it (number, icon+number, chart). Its panel shows CPU and GPU temperature tiles (and battery temperature where present), a history chart, and a collapsible list of all readable sensors.

**Why this priority**: explicitly requested; it is the only new data.

**Independent Test**: enable the indicator; the bar shows a °C value that moves under load; the panel lists CPU and GPU temperatures.

**Acceptance Scenarios**:

1. **Given** the indicator is enabled on Apple silicon, **When** a second passes, **Then** the bar shows the CPU temperature in °C.
2. **Given** the sensors cannot be read, **When** the indicator is shown, **Then** it shows "—" and the panel explains temperatures are not available, without crashing.
3. **Given** no window or panel is open, **When** the indicator is on, **Then** temperature is sampled at the same light cadence as other indicators (no extra wake-ups).

### Edge Cases

- Sensors return 0, negative or absurd values (> 130 °C): ignored as unreadable.
- Intel Macs and Apple silicon use different sensor names: both must give a CPU value or "—".
- The process list is empty in light sampling mode: the section shows the last known list, or "Loading…" until the panel's full sampling fills it.
- Temperature indicator turned off: no sensor reads happen at all.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each indicator panel MUST show a usage bar (where the metric is a fraction) and its chart with a faint 100% guide line, matching the Vorssaint look.
- **FR-002**: CPU, RAM and GPU panels MUST offer a collapsible "Top apps" section listing up to 8 processes with icon, name and value, sorted by that resource.
- **FR-003**: Collapsible sections MUST start folded, use a chevron that rotates, and remember their open state per section across panel openings for the app session.
- **FR-004**: The system MUST add a "Temperature" menu bar indicator that users can enable, order and style like the existing ones.
- **FR-005**: The system MUST read CPU and GPU temperatures (battery when present) from the Mac's sensors, only while something that shows them is visible or enabled.
- **FR-006**: The temperature panel MUST show CPU/GPU tiles, a history chart and a collapsible list of individual sensors.
- **FR-007**: When temperatures are unavailable the indicator MUST show "—" and the panel a plain explanation.
- **FR-008**: Values MUST be shown in °C. (Fahrenheit not in scope.)

### Key Entities

- **TemperatureReading**: CPU °C, GPU °C (optional), battery °C (optional), named sensors [(name, °C)].
- **Temperature indicator setting**: same shape as existing indicator settings (enabled, style, tint, label, icon).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Every indicator panel exposes at least one collapsible section beyond today's rows.
- **SC-002**: On this Mac (Apple silicon), the temperature indicator shows a value within 5 °C of what Vorssaint shows at the same time.
- **SC-003**: With only the temperature indicator on and no panel open, Liv Vitals' CPU use stays within 0.5 percentage points of today's idle cost.
- **SC-004**: Existing unit tests and indicator image tests still pass; new tests cover sensor value filtering and the new indicator's formatting.

## Assumptions

- Vorssaint (same author's GPL-3 project) is the visual and technical reference; its sensor-reading approach may be adapted since both projects are GPL-3.
- Only °C; no fan speeds, no alerts, no per-core CPU graph in this change.
- The existing combined `MenuBarView` popover stays as it is; the change targets the per-metric indicator panels.
- Desktop widgets are out of scope (per the project rule, widgets only show values stable over 15 minutes).
