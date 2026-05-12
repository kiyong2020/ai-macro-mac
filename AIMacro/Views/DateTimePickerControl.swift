//
//  DateTimePickerControl.swift
//  AIMacro
//
//  Button-style control that displays a formatted date+time and, on click,
//  opens an NSPopover containing a `clockAndCalendar` NSDatePicker. Used in
//  place of the inline NSDatePicker text-field style so the user gets a
//  visual calendar+clock picker without sacrificing horizontal space.
//

import Cocoa

final class DateTimePickerControl: NSButton {
    /// The currently-selected date/time.
    var dateValue: Date = Date() {
        didSet { updateTitle() }
    }

    /// Called when the user picks a new date in the popover.
    var onChange: ((Date) -> Void)?

    /// Whether seconds appear in the picker + display.
    var includesSeconds: Bool = false {
        didSet { updateTitle() }
    }

    private var popover: NSPopover?
    private weak var calendarPicker: NSDatePicker?
    private weak var timeTextPicker: NSDatePicker?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // `.roundRect` renders a clear thin outline in both light and dark
        // mode at small control sizes — the original `.rounded` style was
        // nearly invisible in the toolbar against the dark window chrome.
        // Force isBordered explicitly in case the storyboard's `type="bevel"`
        // cell attribute would otherwise suppress the border.
        isBordered = true
        bezelStyle = .roundRect
        target = self
        action = #selector(showPopover)
        updateTitle()
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let displayFormatterWithSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private func updateTitle() {
        let f = includesSeconds ? Self.displayFormatterWithSeconds : Self.displayFormatter
        title = f.string(from: dateValue)
    }

    @objc private func showPopover() {
        let timeElements: NSDatePicker.ElementFlags = includesSeconds
            ? .hourMinuteSecond
            : .hourMinute

        // Visual calendar + clock for browsing dates and dragging the clock hands.
        let calendar = NSDatePicker()
        calendar.datePickerStyle = .clockAndCalendar
        calendar.datePickerElements = [.yearMonthDay, timeElements]
        calendar.dateValue = dateValue
        calendar.target = self
        calendar.action = #selector(calendarPickerChanged(_:))
        calendar.translatesAutoresizingMaskIntoConstraints = false

        // Text field below for typing the time directly — clockAndCalendar's
        // clock face is draggable only, so users couldn't punch in a precise
        // time without this companion picker.
        let timeText = NSDatePicker()
        timeText.datePickerStyle = .textField
        timeText.datePickerElements = timeElements
        timeText.dateValue = dateValue
        timeText.target = self
        timeText.action = #selector(timeTextChanged(_:))
        timeText.translatesAutoresizingMaskIntoConstraints = false

        let timeLabel = NSTextField(labelWithString: "Time:")
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .secondaryLabelColor

        let container = NSView()
        container.addSubview(calendar)
        container.addSubview(timeLabel)
        container.addSubview(timeText)
        NSLayoutConstraint.activate([
            calendar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            calendar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            calendar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            timeLabel.topAnchor.constraint(equalTo: calendar.bottomAnchor, constant: 10),
            timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            timeLabel.centerYAnchor.constraint(equalTo: timeText.centerYAnchor),

            timeText.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
            timeText.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            timeText.topAnchor.constraint(equalTo: calendar.bottomAnchor, constant: 8),
            timeText.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        let vc = NSViewController()
        vc.view = container

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = pop
        calendarPicker = calendar
        timeTextPicker = timeText
    }

    @objc private func calendarPickerChanged(_ picker: NSDatePicker) {
        dateValue = picker.dateValue
        timeTextPicker?.dateValue = picker.dateValue
        onChange?(dateValue)
    }

    @objc private func timeTextChanged(_ picker: NSDatePicker) {
        // The text picker only edits time-of-day. Merge its hour/minute(/second)
        // with the date portion of the current value so typing "14:30" doesn't
        // also reset the date to today.
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: dateValue)
        let t = cal.dateComponents([.hour, .minute, .second], from: picker.dateValue)
        comps.hour = t.hour
        comps.minute = t.minute
        comps.second = t.second
        guard let merged = cal.date(from: comps) else { return }
        dateValue = merged
        calendarPicker?.dateValue = merged
        onChange?(dateValue)
    }
}
