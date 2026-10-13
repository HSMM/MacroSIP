import Foundation
import MacroSIPCore

/// What the menu bar submenu and Settings › General offer for Do Not Disturb (SCREENS.md 7.2, 8.1).
enum DNDChoice: Hashable {
    case off
    case on                         // until switched off by hand
    case minutes(Int)
    case untilTomorrowMorning       // tomorrow at 9:00

    static let presets: [DNDChoice] = [.off, .on, .minutes(30), .minutes(60), .untilTomorrowMorning]
}

extension AppModel {
    /// The end of a timed choice, counted from `now`; nil for `.off` and `.on`.
    static func dndEnd(of choice: DNDChoice, from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch choice {
        case .off, .on: return nil
        case let .minutes(m): return now.addingTimeInterval(Double(m) * 60)
        case .untilTomorrowMorning:
            // Between midnight and 9:00 "tomorrow morning" is the coming 9:00, today.
            let day = calendar.component(.hour, from: now) < 9
                ? calendar.startOfDay(for: now)
                : (calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400))
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
        }
    }

    func setDND(_ choice: DNDChoice) {
        switch choice {
        case .off: updateSettings { $0.general.doNotDisturb = false }
        case .on: updateSettings { $0.general.doNotDisturb = true; $0.general.doNotDisturbUntil = nil }
        case .minutes, .untilTomorrowMorning:
            let end = Self.dndEnd(of: choice)
            updateSettings { $0.general.doNotDisturb = true; $0.general.doNotDisturbUntil = end }
        }
    }

    /// Menu bar and Option-Command-D: on (until switched off) or off.
    func toggleDND() { setDND(doNotDisturb ? .off : .on) }

    /// Whole minutes left (rounded up, at least 1) of a timed Do Not Disturb.
    func dndRemainingMinutes(at now: Date = Date()) -> Int? {
        guard let end = doNotDisturbUntil else { return nil }
        return max(1, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "Do Not Disturb · 27 min" while timed, "Do Not Disturb" otherwise.
    func dndTitle(at now: Date = Date()) -> String {
        guard let minutes = dndRemainingMinutes(at: now) else { return L.menuDND }
        return L.menuDNDRemaining(L.durationShort(minutes: minutes))
    }

    /// Ends the timer's job when the time has come, and keeps one timer for the current end time.
    /// Called when the setting changes and at launch. The wait is cut in slices so a clock change or a long
    /// sleep of the Mac cannot leave Do Not Disturb on past its end.
    func armDNDTimer() {
        dndTask?.cancel()
        dndTask = nil
        guard settings.general.doNotDisturb, let end = settings.general.doNotDisturbUntil else { return }
        dndTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let left = end.timeIntervalSinceNow
                if left <= 0 { break }
                try? await Task.sleep(for: .seconds(min(left, 20)))
            }
            guard !Task.isCancelled, let self else { return }
            AppLog.app.info("timed Do Not Disturb ended")
            self.updateSettings { $0.general.doNotDisturb = false }
        }
    }
}
