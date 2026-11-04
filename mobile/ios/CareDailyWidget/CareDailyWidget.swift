import WidgetKit
import SwiftUI

struct CareWidgetEntry: TimelineEntry {
  let date: Date
  let title: String
  let scope: String
  let summary: String
  let next: String
  let updated: String
}

struct CareWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> CareWidgetEntry { empty(Date()) }
  func getSnapshot(in context: Context, completion: @escaping (CareWidgetEntry) -> Void) { completion(entry(Date(), snapshot: DailyWidgetStore.read())) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<CareWidgetEntry>) -> Void) {
    let now = Date(), snapshot = DailyWidgetStore.read()
    var dates = [now]
    // Change the next-check line at supplied event times and at midnight.
    if let days = snapshot?["days"] as? [[String: Any]] {
      for day in days {
        if let start = day["start"] as? Double { dates.append(Date(timeIntervalSince1970: start / 1000)) }
        if let events = day["events"] as? [[String: Any]] {
          for event in events { if let at = event["at"] as? Double { dates.append(Date(timeIntervalSince1970: at / 1000 + 1)) } }
        }
      }
    }
    let future = Array(Set(dates.filter { $0 >= now })).sorted().prefix(128)
    let entries = future.map { entry($0, snapshot: snapshot) }
    completion(Timeline(entries: entries.isEmpty ? [empty(now)] : entries, policy: .after(now.addingTimeInterval(1800))))
  }
  private func empty(_ date: Date) -> CareWidgetEntry {
    CareWidgetEntry(date: date, title: "간병수첩", scope: "", summary: "앱에서 홈 위젯을 켜 주세요.", next: "앱을 눌러 오늘 내용을 확인해 주세요.", updated: "")
  }
  private func entry(_ date: Date, snapshot: [String: Any]?) -> CareWidgetEntry {
    guard let snapshot = snapshot,
          let days = snapshot["days"] as? [[String: Any]],
          let labels = snapshot["labels"] as? [String: String] else { return empty(date) }
    func label(_ key: String, _ fallback: String) -> String { labels[key] ?? fallback }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    guard (snapshot["timeZoneOffset"] as? Int) == TimeZone.current.secondsFromGMT(for: date) / 60,
          let day = days.first(where: { ($0["day"] as? String) == formatter.string(from: date) }) else {
      return CareWidgetEntry(date: date, title: label("title", "간병수첩"), scope: "", summary: label("refresh", "기록 갱신 필요"), next: label("open", "앱에서 확인"), updated: "")
    }
    let intakes = (day["intakes"] as? Int).map(String.init) ?? label("refresh", "기록 갱신 필요")
    let summary = "\(label("pending", "오늘 할 일")): \(day["pending"] as? Int ?? 0) · \(label("overdue", "지난 예정")): \(day["overdue"] as? Int ?? 0)\n\(label("intakes", "복용함 기록")): \(intakes)"
    let events = day["events"] as? [[String: Any]] ?? []
    let upcoming = events.first { ($0["at"] as? Double ?? 0) >= date.timeIntervalSince1970 * 1000 }
    let unfinished = (day["pending"] as? Int ?? 0) > 0 || (day["overdue"] as? Int ?? 0) > 0
    var next = (day["more"] as? Bool == true || unfinished) ? label("open", "앱에서 확인") : label("empty", "확인할 예정 없음")
    formatter.dateFormat = "HH:mm"
    if let upcoming = upcoming, let at = upcoming["at"] as? Double {
      next = label("next", "다음 확인") + ": " + formatter.string(from: Date(timeIntervalSince1970: at / 1000))
      if snapshot["details"] as? Bool == true, let text = upcoming["text"] as? String { next += " · " + text }
    }
    formatter.dateFormat = "MM/dd HH:mm"
    let updated = label("updated", "마지막 갱신") + " " + formatter.string(from: Date(timeIntervalSince1970: (snapshot["updated"] as? Double ?? 0) / 1000))
    return CareWidgetEntry(date: date, title: label("title", "간병수첩"), scope: label("scope", "선택한 수첩 · 입력한 기록 기준"), summary: summary, next: next, updated: updated)
  }
}

struct CareWidgetView: View {
  let entry: CareWidgetEntry
  @Environment(\.widgetFamily) var family
  @Environment(\.dynamicTypeSize) var textSize
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !textSize.isAccessibilitySize { Text(entry.title).font(.headline) }
      if family != .systemSmall && !textSize.isAccessibilitySize { Text(entry.scope).font(.caption) }
      Text(entry.summary).font(.subheadline)
      Text(entry.next).font(.subheadline).foregroundColor(.primary).lineLimit(2)
      Text(entry.updated).font(.caption).foregroundColor(.secondary)
    }
    .padding()
    .widgetURL(URL(string: "carenotebook://today"))
    .privacySensitive()
    .accessibilityElement(children: .combine)
  }
}

@main
struct CareDailyWidget: Widget {
  var body: some WidgetConfiguration {
    if #available(iOS 17.0, *) {
      configuration.disfavoredLocations([.iPhoneWidgetsOnMac], for: [.systemSmall, .systemMedium, .systemLarge])
    } else { configuration }
  }
  private var configuration: some WidgetConfiguration {
    StaticConfiguration(kind: "CareDailyWidget", provider: CareWidgetProvider()) { entry in
      if #available(iOS 17.0, *) { CareWidgetView(entry: entry).containerBackground(.background, for: .widget) }
      else { CareWidgetView(entry: entry) }
    }
    .configurationDisplayName("간병수첩")
    .description("오늘 할 일과 복약 기록, 다음 확인 시각")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
