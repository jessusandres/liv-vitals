import LivCore
import SwiftUI
import WidgetKit

extension LivWidgetEntry: TimelineEntry {}

/// Takes the reading for a widget. One is enough: the kept widgets show the disk, the battery and the Mac's facts, none of which
/// needs a second sample to become a rate. Nothing is launched (`NullProcessSampler`) and nothing is written: no history.
public enum LivWidgetReader {
    public static func read(now: Date = .now) -> LivWidgetEntry {
        let sampler = SystemSampler(processes: NullProcessSampler())
        var aggregator = MetricsAggregator()
        let snapshot = (try? sampler.read(includeProcesses: false)).map { aggregator.ingest($0) }
        return LivWidgetEntry(date: now, snapshot: snapshot, device: DeviceInfo.read(now: now))
    }
}

public struct LivWidgetProvider: TimelineProvider {
    public init() {}

    public func placeholder(in context: Context) -> LivWidgetEntry {
        LivWidgetEntry(date: .now, snapshot: nil, device: DeviceInfo.read())
    }

    public func getSnapshot(in context: Context, completion: @escaping @Sendable (LivWidgetEntry) -> Void) {
        DispatchQueue.global(qos: .utility).async { completion(LivWidgetReader.read()) }
    }

    public func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<LivWidgetEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let entry = LivWidgetReader.read()
            completion(Timeline(entries: [entry], policy: .after(WidgetSchedule.nextRefresh(after: entry.date))))
        }
    }
}

/// One definition for the three widgets. Metadata is literal text (`verbatim`): WidgetKit reads it when macOS lists the
/// extension and rejects formatted text.
@MainActor
public enum LivWidgetDefinition {
    public static func configuration(for kind: WidgetKind) -> some WidgetConfiguration {
        StaticConfiguration(kind: kind.widgetID, provider: LivWidgetProvider()) { entry in
            WidgetFace(kind: kind, entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName(Text(verbatim: kind.title))
        .description(Text(verbatim: kind.summary))
        .supportedFamilies([.systemMedium])
    }
}

public struct LivBatteryHealthWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration { LivWidgetDefinition.configuration(for: .batteryHealth) }
}

public struct LivStorageWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration { LivWidgetDefinition.configuration(for: .storage) }
}

public struct LivDeviceWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration { LivWidgetDefinition.configuration(for: .device) }
}
