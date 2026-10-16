# Liv Vitals

A native macOS app to clean, uninstall, monitor and maintain your Mac. Liv Vitals finds caches, logs, leftovers and build artifacts, shows what is taking up your disk, keeps a live view of CPU, memory, disk, network and battery in the menu bar, and puts back what it removed.

## Features

- **Smart Care** scans Cleanup, Installers and Dev Projects together, lists everything once, and runs the cleaning plus the maintenance tasks you pick with one button.
- **Cleanup** removes caches, logs and other regenerable files, from a rule list that is checked path by path.
- **Dev Projects** finds `node_modules`, build folders and other artifacts next to their project markers, and never offers what git tracks.
- **Installers** finds disk images and packages in folders you choose, and tells which ones belong to apps you already have.
- **Uninstaller** removes an app together with its leftovers. Apps owned by root and system files ask for your password once.
- **Performance** runs maintenance tasks (DNS cache, Quick Look, Launch Services, Spotlight, icons, memory) and lists your startup items.
- **Space Lens** shows where the disk space went as an interactive sunburst and lets you move items to the Trash.
- **History** lists every cleanup with the items it removed, and **Put Back** returns anything that went to the Trash to its original place without overwriting.
- **Monitor** gives a live view of CPU, memory, disk, network, battery and the busiest processes, with a health score.
- **Menu bar indicators** (CPU, memory, GPU, disk, disk activity, network, battery) with six styles, and three **desktop widgets** (Battery Health, Storage, Device) that refresh about every 15 minutes.
- Menu bar mode: close the window with `⌘W` and the app stays in the menu bar without a Dock icon.

## Safety

- Every removal is validated against the exact path, right before it runs, with protected locations, an editable list of protected folders, and a guard against symlink swaps.
- Items go to the Trash by default, and **Simulate cleaning** records what would happen without touching anything.
- Every action is written to a local log, one line per item.
- Administrator rights are optional and narrow: either one password dialog per run, or a single `sudoers` rule that allows exactly the fixed commands the app uses and that you can remove at any time.
- Nothing is sent anywhere. The app has no network code and no analytics.

## Requirements

- macOS 14 or later
- Xcode 16 or later

## Install

```bash
make install
```

This builds the Release app and installs `LivVitals.app` in `/Applications`.

The project is signed with a personal development team. To build it yourself, open `LivVitals.xcodeproj`, select your own team under **Signing & Capabilities** for the `LivVitals` and `LivVitalsWidgets` targets, and change the bundle identifiers (`dev.asger.LivVitals`, `dev.asger.LivVitals.Widgets`) to ones you own.

### Permissions

macOS asks for these on first use. None is required to open the app.

- **Full Disk Access**, to measure and clean caches, logs and app data that macOS protects.
- **App Management**, to move other developers' apps to the Trash. macOS lists an app there only after it tries to modify another app, so if Liv Vitals is not listed, click **+** and add it from Applications.
- **Administrator password**, only for apps owned by root, system files and a few maintenance tasks.
- **Login Items**, only if you turn on *Open Liv Vitals at login*.

Settings and the operations log live in `~/Library/Application Support/LivVitals/` (`settings.json` and `operations.jsonl`).

## Development

```bash
make verify          # Run all tests and compile the app
make test            # LivCore unit tests (fast, no UI)
make test-app        # App unit tests
make snapshots       # Render every screen to PNG (light and dark) in build/snapshots
make strings         # Sync the String Catalog with the code
make check-strings   # Check the String Catalog for stale or mismatched entries
make perf            # Time the real scans (read-only)
make help            # List every target
```

## Architecture

- **LivCore** is a Swift package with the logic that can be tested without a UI: the safety guard, cleanup rules and runners, restore planning, scanners, metrics and system readers, settings and the operations log.
- **LivWidgetsUI** is a small package with the widget faces shared by the app and the widget extension.
- **LivVitals** is the SwiftUI app (macOS 14, Swift 6 strict concurrency), with services behind protocols so every screen is tested with fakes and never touches the real disk.
- **LivVitalsWidgets** is the WidgetKit extension.

## Contributing

Issues and pull requests are welcome. Please include tests for behavior changes and keep user-facing copy in English.

## License

This project is licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`). If you distribute a modified version, you must provide its corresponding source code under the same license.
