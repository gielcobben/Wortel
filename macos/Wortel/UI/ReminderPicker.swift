import AppKit
import SwiftUI

/// Remind Me ▸ Custom…: the system's alert, holding a month to pick a day
/// from and a menu of times.
///
/// The calendar is Wortel's own. The system's was tried in each of its forms
/// (docs/decisions.md): it brings its own field, stepper and selection, and
/// none of them sat with the alert's buttons. This one is laid out on the
/// buttons' columns and built from the numbers every other control here uses:
/// a 28pt cell with 8pt corners, the hover fill, the accent for what's chosen.
@MainActor
enum ReminderDialog {
    /// Asks when, and calls `then` with the answer unless it's cancelled. A
    /// sheet on the window, as the other questions about a session are (Close
    /// asks the same way): the window dims under it, and it stays with the
    /// window it's about.
    static func present(on window: NSWindow?, initial: Date?, then: @escaping (Date) -> Void) {
        let (alert, choice) = make(initial: initial, now: Date())
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, let date = choice.date else { return }
            // The alert may have sat open past the time it was showing.
            guard date > Date() else { return NSSound.beep() }
            then(date)
        }
        if let window {
            // Becoming a sheet, the alert lays itself out once more: it puts
            // its title back over the picker and sizes the window to that
            // (measured, macOS 26). So `make`'s layout is put back after.
            // The sheet stays centred on the window.
            let panel = alert.window
            let size = panel.frame.size
            let frames = panel.contentView?.subviews.map { ($0, $0.frame) } ?? []
            alert.beginSheetModal(for: window, completionHandler: answer)
            panel.setContentSize(size)
            for (view, frame) in frames { view.frame = frame }
        } else {
            answer(alert.runModal())
        }
    }

    /// The alert, laid out and ready to run.
    static func make(initial: Date?, now: Date,
                     calendar: Calendar = .current) -> (alert: NSAlert, choice: ReminderChoice) {
        let alert = NSAlert()
        // The month is the dialog's heading: no icon and no title over it.
        // The menu it was chosen from said what this is and which session.
        // The title is still set, for VoiceOver, and hidden in `fit`.
        alert.messageText = "Remind Me"
        let remind = alert.addButton(withTitle: "Remind Me")
        alert.addButton(withTitle: "Cancel")
        let choice = ReminderChoice(initial: initial, now: now, calendar: calendar)
        let picker = ReminderPickerView(choice: choice)
        // Laid out as if the picker were short, then grown to its height.
        // An alert that would come out taller than about five thirds of its
        // width (measured, macOS 26) lays itself out sideways and twice as
        // wide instead, with the icon in a column of its own; the picker is
        // taller than that allows at the alert's usual width. Changing the
        // layout between `layout()` and running is what `layout()` is for.
        picker.frame.size.height = 120
        alert.accessoryView = picker
        // The arrow keys move the day from the start; Return is Remind Me.
        alert.window.initialFirstResponder = picker
        alert.layout()
        fit(alert, around: picker)
        // The time menu stands on Remind Me: its width, over its edges.
        let button = picker.convert(remind.bounds, from: remind)
        picker.show(menu: picker.bounds.contains(NSPoint(x: button.midX, y: picker.bounds.midY))
                    ? button.minX...button.maxX : nil)
        return (alert, choice)
    }

    /// Grows the picker to its real height, and takes the icon and the title
    /// out: the alert has no switch for either. What is under the picker (the
    /// buttons) stays where the alert put it, and the window ends just above
    /// the picker, so the month stands where the title's text stood.
    private static func fit(_ alert: NSAlert, around picker: NSView) {
        guard let content = alert.window.contentView else { return }
        // The alert's own view holding the picker, if it wrapped it.
        var holder = picker
        while let parent = holder.superview, parent !== content { holder = parent }
        guard holder.superview === content else { return }

        var frames = Dictionary(uniqueKeysWithValues: content.subviews.map { (ObjectIdentifier($0), $0.frame) })
        let grow = ReminderPicker.height - holder.frame.height
        let above = content.subviews.filter { $0 !== holder && $0.frame.minY >= holder.frame.maxY }
        frames[ObjectIdentifier(holder)]?.size.height += grow
        for view in above { frames[ObjectIdentifier(view)]?.origin.y += grow }
        var height = content.bounds.height + grow

        // Stacked, the title is under the icon and over the picker: hide
        // both. Sideways (which the short layout above avoids) they stay.
        if let icon = content.subviews.first(where: { $0 is NSImageView }),
           let title = label(alert.messageText, in: content),
           let iconFrame = frames[ObjectIdentifier(icon)], let titleFrame = frames[ObjectIdentifier(title)],
           titleFrame.maxY <= iconFrame.minY, let pickerFrame = frames[ObjectIdentifier(holder)] {
            icon.isHidden = true
            title.isHidden = true
            // The icon's margin, less the room over the text in the month's
            // 28pt row: the month's text starts where the title's did.
            let margin = height - iconFrame.maxY
            height = pickerFrame.maxY + margin - ReminderPicker.headerLead
        }
        alert.window.setContentSize(NSSize(width: content.bounds.width, height: height))
        for view in content.subviews { frames[ObjectIdentifier(view)].map { view.frame = $0 } }
        if holder !== picker { picker.frame = holder.bounds }
    }

    /// The alert's own label showing `text`.
    private static func label(_ text: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.stringValue == text { return field }
        return view.subviews.lazy.compactMap { label(text, in: $0) }.first
    }
}

/// What the dialog is showing and what's chosen in it.
@MainActor
final class ReminderChoice: ObservableObject {
    let calendar: Calendar
    /// When the dialog opened. Days and times before it aren't offered.
    let now: Date
    /// A reminder already set off the half hour keeps its own time on the menu.
    private let extra: Int?
    /// The first day of the month on show.
    @Published private(set) var month: Date
    /// The chosen day, at its start.
    @Published private(set) var day: Date
    /// The chosen time, as minutes past midnight.
    @Published var clock: Int

    /// Starts on the reminder already set, or an hour from now on the next
    /// half hour.
    init(initial: Date?, now: Date, calendar: Calendar) {
        self.calendar = calendar
        self.now = now
        let pending = initial.flatMap { $0 > now ? $0 : nil }
        let start = pending ?? now.addingTimeInterval(3600)
        var day = calendar.startOfDay(for: start)
        var clock = ReminderCalendar.clock(of: start, calendar: calendar)
        let step = ReminderCalendar.step
        if pending == nil {
            clock = (clock + step - 1) / step * step
            if clock >= 24 * 60 {
                clock = 0
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            }
        }
        extra = clock % step == 0 ? nil : clock
        self.day = day
        self.clock = clock
        month = Self.firstOfMonth(day, calendar)
        settle()
    }

    /// The moment chosen.
    var date: Date? { ReminderCalendar.moment(on: day, clock: clock, calendar: calendar) }

    /// The times the chosen day offers.
    var clocks: [Int] { ReminderCalendar.clocks(on: day, now: now, extra: extra, calendar: calendar) }

    func isOpen(_ day: Date) -> Bool {
        ReminderCalendar.isOpen(day, now: now, extra: extra, calendar: calendar)
    }

    func choose(_ day: Date) {
        guard isOpen(day) else { return }
        self.day = calendar.startOfDay(for: day)
        month = Self.firstOfMonth(day, calendar)
        settle()
    }

    /// The arrow keys: a day or a week either way, into the next month if
    /// that's where it lands.
    func move(days: Int) {
        guard let next = calendar.date(byAdding: .day, value: days, to: day) else { return }
        choose(next)
    }

    var canGoBack: Bool { month > Self.firstOfMonth(now, calendar) }

    var canGoForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { return false }
        return next.timeIntervalSince(now) <= ReminderTime.longest
    }

    /// Shows the month before or after. The chosen day stays chosen.
    func turn(months: Int) {
        guard months < 0 ? canGoBack : canGoForward,
              let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = next
    }

    /// Keeps the time on one the day offers: today has no 09:00 left at noon.
    private func settle() {
        let offered = clocks
        guard !offered.contains(clock) else { return }
        clock = offered.first { $0 >= clock } ?? offered.first ?? clock
    }

    private static func firstOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}

/// The picker as the alert's accessory. It holds the keyboard itself, so the
/// arrow keys move the day whatever was last clicked; the SwiftUI view inside
/// takes the pointer.
final class ReminderPickerView: NSView {
    private let choice: ReminderChoice

    init(choice: ReminderChoice) {
        self.choice = choice
        super.init(frame: NSRect(x: 0, y: 0, width: ReminderPicker.width, height: ReminderPicker.height))
    }

    /// Draws the picker, once the alert has laid out and its buttons can be
    /// measured. `menu` is where the time menu goes, from this view's left
    /// edge; nil puts it in the right half.
    func show(menu: ClosedRange<CGFloat>?) {
        let menu = menu ?? (bounds.midX + 4)...(bounds.maxX - 4)
        let host = NSHostingView(rootView: ReminderPicker(choice: choice, menu: menu))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    // The chosen day is the cursor.
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    override func keyDown(with event: NSEvent) {
        let forward = userInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        switch event.specialKey {
        case .leftArrow: choice.move(days: -forward)
        case .rightArrow: choice.move(days: forward)
        case .upArrow: choice.move(days: -7)
        case .downArrow: choice.move(days: 7)
        default: super.keyDown(with: event)
        }
    }
}

/// A month of days over a menu of times. Seven equal columns across whatever
/// width it's given, with every control 28pt high.
struct ReminderPicker: View {
    @ObservedObject var choice: ReminderChoice
    /// Where the time menu goes, from the leading edge.
    let menu: ClosedRange<CGFloat>

    private static let cell = Chrome.controlSize
    private static let weekdayRow: CGFloat = 18
    private static let timeGap: CGFloat = 8
    /// The alert's text column, in from the accessory's edges: the grid
    /// spans it, so the days stand under the alert's own two lines.
    private static let columnInset: CGFloat = 4
    /// Where the alert's labels start their text inside that column. The
    /// month and "Time" start there too.
    private static let textInset: CGFloat = 2

    /// As wide as the alert's two buttons together, so the alert keeps its
    /// usual width.
    static let width: CGFloat = 228
    /// The room over the month's text in its row: a 16pt line in 28pt.
    static let headerLead: CGFloat = 6
    static let height = cell + weekdayRow + 6 * cell + timeGap + cell

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdays
            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            cell(day).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Self.columnInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomLeading) { time }
        .font(.system(size: 13))
    }

    private var weeks: [[Date?]] { ReminderCalendar.weeks(of: choice.month, calendar: choice.calendar) }

    /// The month, and the arrows over the last two columns.
    private var header: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            arrow("chevron.left", "Previous Month", enabled: choice.canGoBack) { choice.turn(months: -1) }
                .frame(maxWidth: .infinity)
            arrow("chevron.right", "Next Month", enabled: choice.canGoForward) { choice.turn(months: 1) }
                .frame(maxWidth: .infinity)
        }
        .frame(height: Self.cell)
        .overlay(alignment: .leading) {
            // The alert's own title weight: this is the heading.
            Text(Self.monthTitle(choice.month, choice.calendar))
                .fontWeight(.bold)
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.leading, Self.textInset)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func arrow(_ symbol: String, _ name: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        HoverCell(enabled: enabled, action: action) { _ in
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: enabled ? .secondaryLabelColor : .quaternaryLabelColor))
        }
        .accessibilityLabel(name)
        .help(name)
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(Array(ReminderCalendar.weekdaySymbols(calendar: choice.calendar).enumerated()),
                    id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.weekdayRow)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func cell(_ day: Date?) -> some View {
        if let day {
            let selected = choice.calendar.isDate(day, inSameDayAs: choice.day)
            let today = choice.calendar.isDate(day, inSameDayAs: choice.now)
            let open = choice.isOpen(day)
            HoverCell(enabled: open, lit: selected, action: { choice.choose(day) }) { _ in
                Text(choice.calendar.component(.day, from: day).formatted())
                    .fontWeight(selected || today ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white
                                     : !open ? Color(nsColor: .tertiaryLabelColor)
                                     : today ? Color.accentColor : Color(nsColor: .labelColor))
            }
            .accessibilityLabel(Self.dayName(day, choice.calendar))
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }

    /// "Time" where the alert's text starts, the menu over Remind Me.
    private var time: some View {
        TimeMenu(clocks: choice.clocks,
                 titles: choice.clocks.map { Self.timeTitle($0, on: choice.day, choice.calendar) },
                 clock: $choice.clock)
        // The alert's buttons are the large size. Said here: SwiftUI hands
        // its own control size to an AppKit control it hosts.
        .controlSize(.large)
        .frame(width: menu.upperBound - menu.lowerBound)
        .padding(.leading, menu.lowerBound)
        .frame(maxWidth: .infinity, minHeight: Self.cell, maxHeight: Self.cell, alignment: .leading)
        .overlay(alignment: .leading) {
            Text("Time")
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.leading, Self.columnInset + Self.textInset)
        }
    }

    // MARK: Words

    private static func formatter(_ calendar: Calendar, _ configure: (DateFormatter) -> Void) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        configure(formatter)
        return formatter
    }

    private static func monthTitle(_ month: Date, _ calendar: Calendar) -> String {
        formatter(calendar) { $0.setLocalizedDateFormatFromTemplate("MMMMy") }.string(from: month)
    }

    private static func dayName(_ day: Date, _ calendar: Calendar) -> String {
        formatter(calendar) { $0.dateStyle = .full }.string(from: day)
    }

    private static func timeTitle(_ clock: Int, on day: Date, _ calendar: Calendar) -> String {
        guard let moment = ReminderCalendar.moment(on: day, clock: clock, calendar: calendar) else { return "" }
        return formatter(calendar) { $0.timeStyle = .short }.string(from: moment)
    }
}

/// One 28pt control with 8pt corners: a day, or a month arrow. The hover fill
/// under the pointer, the accent when lit, as a glyph button in a titlebar
/// row has it.
private struct HoverCell<Label: View>: View {
    let enabled: Bool
    var lit = false
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label(hovering)
                .frame(width: Chrome.controlSize, height: Chrome.controlSize)
                .background(
                    RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                        .fill(lit ? Color.accentColor
                              : hovering && enabled ? Color(nsColor: Chrome.hoverFill) : .clear)
                        // The rows touch; a point of air keeps a hovered day
                        // off the chosen one above it.
                        .padding(1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// The times, as the system's pop-up button at the size of the alert's own
/// buttons. AppKit's, not SwiftUI's `Picker`: that one is as wide as its
/// title, and this one has to be as wide as Remind Me.
private struct TimeMenu: NSViewRepresentable {
    let clocks: [Int]
    let titles: [String]
    @Binding var clock: Int

    func makeCoordinator() -> Coordinator { Coordinator(clock: $clock) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.chose(_:))
        button.setAccessibilityLabel("Time")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.clock = $clock
        let menu = button.menu ?? NSMenu()
        if menu.items.map(\.tag) != clocks || menu.items.map(\.title) != titles {
            menu.removeAllItems()
            for (clock, title) in zip(clocks, titles) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = clock
                menu.addItem(item)
            }
            button.menu = menu
        }
        button.selectItem(withTag: clock)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let fitting = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    @MainActor final class Coordinator: NSObject {
        var clock: Binding<Int>
        init(clock: Binding<Int>) { self.clock = clock }
        @objc func chose(_ sender: NSPopUpButton) { clock.wrappedValue = sender.selectedTag() }
    }
}
