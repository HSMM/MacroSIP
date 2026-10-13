import SwiftUI
import MacroSIPCore

/// Settings › General › Do Not Disturb (SCREENS.md 8.1): off, on, or a timer.
struct DoNotDisturbGroup: View {
    @Environment(AppModel.self) private var model

    /// What the DND pop-up shows: off, on, or the running timer (a row of its own while one runs).
    private var dndSelection: Binding<DNDChoice> {
        Binding(
            get: {
                if !model.doNotDisturb { return .off }
                return model.doNotDisturbUntil == nil ? .on : .minutes(0)
            },
            set: { choice in
                if case .minutes(0) = choice { return }       // the running timer: nothing to change
                model.setDND(choice)
            })
    }

    var body: some View {
        FormGroup { dndRow }
    }

    private var dndRow: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let end = model.doNotDisturbUntil
            let remaining = model.dndRemainingMinutes(at: context.date).map { L.durationShort(minutes: $0) }
            FormRow(label: L.menuDND, help: end.flatMap { e in remaining.map { L.dndUntil(Self.untilText(e), $0) } } ?? L.dndHelp) {
                Picker("", selection: dndSelection) {
                    if let end, let remaining {
                        Text(L.dndUntil(Self.untilText(end), remaining)).tag(DNDChoice.minutes(0))
                        Divider()
                    }
                    Text(L.dndOff).tag(DNDChoice.off)
                    Text(L.dndOn).tag(DNDChoice.on)
                    Text(L.dnd30Minutes).tag(DNDChoice.minutes(30))
                    Text(L.dnd1Hour).tag(DNDChoice.minutes(60))
                    Text(L.dndTomorrow).tag(DNDChoice.untilTomorrowMorning)
                }
                .labelsHidden().frame(width: 250)
            }
        }
    }

    /// "14:30", or "Tue 9:00" when the end is not today.
    static func untilText(_ end: Date) -> String {
        if Calendar.current.isDateInToday(end) { return end.formatted(date: .omitted, time: .shortened) }
        return end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
