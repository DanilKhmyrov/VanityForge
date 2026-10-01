import AppKit
import Foundation
import UserNotifications

/// Пока идёт поиск, Mac не уходит в сон — иначе многочасовой перебор на
/// ноутбуке тихо останавливается, как только система решит поспать.
/// Экран при этом гаснуть может: нужен только работающий процессор/GPU.
@MainActor
final class SleepGuard {
    private var activity: NSObjectProtocol?

    var isActive: Bool { activity != nil }

    func begin(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
    }

    func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Системные уведомления о находках, пока окно приложения не в фокусе.
/// Приватный ключ в уведомление не попадает никогда — только адрес и
/// условие. Частые находки склеиваются: не больше одного уведомления в
/// 15 секунд, следующее сообщает, сколько ещё набежало.
@MainActor
final class FoundNotifier {
    private static let minInterval: TimeInterval = 15
    private var lastSent: Date?
    private var pending = 0
    private var authorizationRequested = false

    /// Без идентификатора бандла (запуск через `swift run`) центр уведомлений
    /// недоступен и падает при обращении — там уведомления просто выключены.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func prepare() {
        lastSent = nil
        pending = 0
        guard available, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func found(_ event: FoundEvent, lang: AppLanguage) {
        guard available, !NSApp.isActive else { return }
        if let lastSent, Date().timeIntervalSince(lastSent) < Self.minInterval {
            pending += 1
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(L.notifyFoundTitle.s(lang)) · \(event.networkFull)"
        var body = Format.shortAddress(event.checksumAddress ?? event.address, head: 12, tail: 8)
        if let condition = event.matchedDesc.first { body += " · \(condition)" }
        if pending > 0 { body += "\(L.notifyMoreFinds.s(lang))\(pending)" }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "found-\(event.seq)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        lastSent = Date()
        pending = 0
    }
}

enum DockBadge {
    @MainActor static func set(_ count: Int?) {
        NSApp?.dockTile.badgeLabel = count.map { $0 > 999 ? "999+" : String($0) }
    }
}
