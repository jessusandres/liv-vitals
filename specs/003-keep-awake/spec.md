# Feature Specification: Keep awake

**Feature Branch**: `feat/keep-awake`
**Created**: 2026-11-09
**Status**: Draft
**Input**: "Also add this feature" with a screenshot of Vorssaint's Keep awake settings: an on/off switch ("Active until you turn it off"), default duration chips (15 min, 30 min, 1 h, 2 h, 4 h, 8 h, Indefinite), automation cards (External display, Power, Applications: "Starts when any selected condition is active"), and "Pause while the Mac is locked".

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Keep the Mac awake from the menu bar (Priority: P1)

The user clicks a cup icon in the menu bar and starts keeping the Mac awake, either for the default duration or a chosen one. While a timed session runs, the icon shows the remaining time. They can change or stop it from the same menu.

**Independent Test**: start a 15-minute session; `pmset -g assertions` lists Liv Vitals' assertions; stop it and they are gone.

**Acceptance Scenarios**:

1. **Given** keep awake is off, **When** the user picks "1 hour", **Then** the Mac and display do not idle-sleep for one hour and the icon shows the remaining time.
2. **Given** a session runs, **When** the user stops it, the session ends, or the app quits, **Then** the assertions are released immediately.
3. **Given** "Indefinite", **Then** the session lasts until the user stops it.

### User Story 2 - Settings page like Vorssaint's (Priority: P1)

Settings gains a "Keep awake" page with: the on/off switch with its state line, default duration chips, the automation cards, and "Pause while the Mac is locked".

**Acceptance Scenarios**:

1. **Given** the default duration is 2 hours, **When** the switch is turned on (in Settings or the menu bar), **Then** a 2-hour session starts.
2. **Given** a session runs, **Then** the state line says how long is left ("Active for 1 h 12 min more", or "Active until you turn it off").

### User Story 3 - Automation (Priority: P2)

The user selects conditions; keep awake runs automatically while any selected condition is true and stops when none is (unless the user started a manual session, which keeps its own end).

- **External display**: a display other than the built-in one is connected.
- **Power**: the Mac is on the power adapter.
- **Applications**: any app from a user-picked list is running.

**Acceptance Scenarios**:

1. **Given** "Power" is selected, **When** the adapter is plugged in, **Then** keep awake starts; unplugged, it stops.
2. **Given** "Applications" lists Xcode, **When** Xcode launches/quits, **Then** keep awake starts/stops.
3. **Given** no condition is selected, **Then** automation never starts a session.

### User Story 4 - Pause while locked (Priority: P3)

With "Pause while the Mac is locked" on, locking the screen releases the assertions and freezes a timed session's remaining time; unlocking resumes it.

### Edge Cases

- The Mac is put to sleep manually (lid closed, Apple menu ▸ Sleep): assertions do not prevent this; a timed session's clock keeps running in wall time.
- An app in the automation list is renamed or uninstalled: matched by bundle identifier; missing apps are shown greyed out.
- Manual session and automation both active: the session stays until both are off.
- Liv Vitals crashes: the OS releases its assertions with the process.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Keep awake MUST use IOKit power assertions (idle system sleep and idle display sleep), never simulated input, `caffeinate`, or `pmset` changes.
- **FR-002**: A menu bar item (cup icon, can be turned off in Settings) MUST start/stop sessions, offer the durations 15 min, 30 min, 1 h, 2 h, 4 h, 8 h, Indefinite, and show remaining time for timed sessions.
- **FR-003**: Settings MUST offer the page described in User Story 2; choices persist across launches; an active session does not survive a relaunch.
- **FR-004**: Automation MUST support External display, Power and Applications (by bundle id), starting when any selected condition is true.
- **FR-005**: "Pause while the Mac is locked" MUST release assertions on lock and resume on unlock, keeping the remaining time.
- **FR-006**: Condition detection MUST be event-driven (notifications), not polling.

### Key Entities

- **KeepAwakeSettings**: defaultDuration, automation conditions (externalDisplay, power, applications [bundle ids]), pauseWhileLocked, showInMenuBar.
- **KeepAwakeSession**: started at, ends at (nil = indefinite), source (manual/automation), paused remaining.

## Success Criteria *(mandatory)*

- **SC-001**: With a session active, `pmset -g assertions` shows Liv Vitals' PreventUserIdleSystemSleep and PreventUserIdleDisplaySleep; with none, it shows neither.
- **SC-002**: Idle CPU with keep awake on stays within 0.1 points of today's.
- **SC-003**: Unit tests cover session timing, the automation decision, and pause/resume.

## Assumptions

- The core comes from the user's own `~/personal/coffe-awake` (GPL-3: AwakeController, PowerAssertions, SessionDuration); automation and pause-on-lock follow Vorssaint's KeepAwakeManager (GPL-3, same author), adapted, not copied wholesale.
- No keyboard shortcut, no notch/Dynamic Island strip, no custom icon picker, no mouse jiggle.
- The cup icon is a separate menu bar item, independent of the metric indicators.
