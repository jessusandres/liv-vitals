import LivWidgetsUI
import SwiftUI
import WidgetKit

/// The three Liv Vitals widgets: battery health, storage and device. They refresh about every 15 minutes, so the values that move
/// (CPU, memory, GPU, disk activity, network) are menu bar indicators instead. The faces, the readings and the definitions live in
/// `LivWidgetsUI` so they are tested with `swift test`; this file only names the bundle.
@main
struct LivVitalsWidgets: WidgetBundle {
    var body: some Widget {
        LivBatteryHealthWidget()
        LivStorageWidget()
        LivDeviceWidget()
    }
}
