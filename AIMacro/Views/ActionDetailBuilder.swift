//
//  ActionDetailBuilder.swift
//  AIMacro
//
//  Builds the right-pane detail view for the currently-selected action.
//  Replaces the inline-editing role of ActionCellFactory's XIB cells: each
//  action type gets a vertical form composed of "cards" with labelled rows.
//

import Cocoa
import RxSwift

final class ActionDetailBuilder {
    private let mouseListener: MouseListener
    /// Called whenever an editable field on the detail pane mutates the
    /// underlying action's `name`. ViewController uses this to reload the
    /// list cell on the left so the rename is reflected immediately.
    var onActionRenamed: (() -> Void)?

    init(mouseListener: MouseListener) {
        self.mouseListener = mouseListener
    }

    /// Produce a detail view for the given action. Pass nil to render the
    /// empty-state placeholder.
    func detailView(for action: AutoAction?, disposeBag: DisposeBag) -> NSView {
        guard let action = action else { return makeEmptyState() }

        // FlippedStackView so that anchoring `topAnchor` actually pins the
        // content to the visual top of the enclosing NSScrollView. A standard
        // NSStackView's coord system is bottom-up, which left content
        // gravitating to the bottom of the pane.
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 32, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeHeader(for: action))
        for card in makeCards(for: action, disposeBag: disposeBag) {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = stack

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return container
    }

    // MARK: - Empty state

    private func makeEmptyState() -> NSView {
        let label = NSTextField(labelWithString: "왼쪽에서 액션을 선택하세요")
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabelColor
        let host = NSView()
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    // MARK: - Header

    private func makeHeader(for action: AutoAction) -> NSView {
        // Compact tinted icon — 28×28 host with an inner 16×16 SF Symbol.
        let iconHost = NSView()
        iconHost.wantsLayer = true
        iconHost.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        iconHost.layer?.cornerRadius = 6
        iconHost.layer?.cornerCurve = .continuous
        iconHost.translatesAutoresizingMaskIntoConstraints = false
        iconHost.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconHost.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let iconView = NSImageView()
        iconView.image = ActionIcons.image(for: action.type)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconHost.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: iconHost.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconHost.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Action type pill — primary text in the header now (action name has
        // been removed since it's already shown in the sidebar list).
        let typeTag = NSTextField(labelWithString: "  \(ActionIcons.label(for: action.type))  ")
        typeTag.font = .systemFont(ofSize: 11)
        typeTag.textColor = .secondaryLabelColor
        typeTag.wantsLayer = true
        typeTag.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        typeTag.layer?.cornerRadius = 10
        typeTag.layer?.borderWidth = 1
        typeTag.layer?.borderColor = NSColor.separatorColor.cgColor
        typeTag.cell?.lineBreakMode = .byClipping
        typeTag.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconHost, typeTag])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: - Cards (per action type)

    private func makeCards(for action: AutoAction, disposeBag: DisposeBag) -> [NSView] {
        var cards: [NSView] = []

        // "기본" card: name + delay (delay is meaningful for almost every type).
        let basic = makeCard(title: "기본")
        basic.addRow(label: "이름", control: makeNameField(action, disposeBag: disposeBag))
        if shouldShowDelay(for: action.type) {
            basic.addRow(label: "지연 시간",
                         control: makeDelayField(action, disposeBag: disposeBag),
                         hint: "액션 실행 후 다음 단계까지 대기 (초)")
        }
        cards.append(basic)

        // Type-specific card.
        switch action.type {
        case .click:
            let card = makeCard(title: "클릭 위치")
            card.addRow(label: "좌표", control: makePointPicker(action, disposeBag: disposeBag),
                        hint: "버튼을 누르고 화면에서 위치를 클릭")
            card.addRow(label: "반복", control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            cards.append(card)

        case .scroll:
            let card = makeCard(title: "입력 옵션")
            card.addRow(label: "반복", control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            cards.append(card)

        case .key:
            let card = makeCard(title: "키 입력")
            let custom = makeCustomKeyControl(action, disposeBag: disposeBag)
            // 모드 드롭다운이 곧 라벨 역할 — 별도의 "키" 라벨은 두지 않음.
            card.addRow(labelView: custom.modePopup,
                        control: custom.control,
                        hint: "키 모드: 클릭 후 단축키 입력 / 텍스트 모드: 자유 입력")
            card.addRow(label: "반복", control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            cards.append(card)

        case .wait(.click), .wait(.enter), .wait(.code):
            let card = makeCard(title: "대기")
            card.addRow(label: "타입", control: NSTextField(labelWithString: waitDescription(action.type)))
            cards.append(card)

        case .wait(.time):
            let card = makeCard(title: "시간 대기")
            card.addRow(label: "목표 시각",
                        control: makeWaitTimeControl(action, disposeBag: disposeBag),
                        hint: "지정한 시각이 되면 다음 단계로 진행")
            cards.append(card)

        case .ocr:
            let card = makeCard(title: "OCR 검색")
            card.addRow(label: "타겟 좌표",
                        control: makeOCRPointPicker(action, disposeBag: disposeBag),
                        hint: "클릭하면 라이브 OCR 미리보기가 마우스를 따라 움직입니다")
            card.addRow(label: "찾을 텍스트",
                        control: makeTextField(action, disposeBag: disposeBag, placeholder: "예: 09:00"),
                        hint: "캡처 영역에서 이 텍스트를 인식하면 클릭")
            card.addRow(label: "스캔 영역",
                        control: makeScanSizeControl(action, disposeBag: disposeBag),
                        hint: "타겟 좌표를 중심으로 한 정사각형 캡처 영역 (50–600 px)")
            card.addRow(label: "미리보기",
                        control: makeOCRSnapshotView(action, disposeBag: disposeBag),
                        hint: "위치 지정 직후 캡처된 스캔 영역")
            cards.append(card)

        case .script:
            let card = makeCard(title: "스크립트")
            card.addRow(label: "타겟 좌표",
                        control: makePointPicker(action, disposeBag: disposeBag))
            card.addRow(label: "텍스트 인자",
                        control: makeTextField(action, disposeBag: disposeBag,
                                               placeholder: "${TEXT} 자리표시자 값"),
                        hint: "코드 안의 ${TEXT} 가 이 값으로 치환됩니다")
            cards.append(card)

        case .setURL, .openChrome:
            let card = makeCard(title: action.type.isOpenChrome ? "새 Chrome 창" : "URL 설정")
            // The default URL is taken from the enum payload; pre-fill if blank.
            if (try? action.text.value())?.isEmpty == true {
                action.text.onNext(action.type.defaultURL ?? "")
            }
            card.addRow(label: "URL",
                        control: makeTextField(action, disposeBag: disposeBag,
                                               placeholder: "https://..."))
            cards.append(card)

        case .windowFrame:
            let card = makeCard(title: "창 프레임")
            card.addRow(label: "저장된 프레임",
                        control: makeWindowFrameRow(action, disposeBag: disposeBag),
                        hint: "x, y, width, height")
            cards.append(card)
        }

        return cards
    }

    private func shouldShowDelay(for type: AutoAction.ActionType) -> Bool {
        switch type {
        case .wait: return false
        default:    return true
        }
    }

    private func waitDescription(_ type: AutoAction.ActionType) -> String {
        switch type {
        case .wait(.click): return "사용자가 마우스 클릭할 때까지 일시정지"
        case .wait(.enter): return "사용자가 엔터 키를 누를 때까지 일시정지"
        case .wait(.code):  return "외부에서 인증코드를 수신할 때까지 일시정지"
        default:            return ""
        }
    }

    // MARK: - Form pieces

    private func makeNameField(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let field = NSTextField(string: action.name)
        field.bezelStyle = .roundedBezel
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak self, weak action] new in
            action?.name = new
            self?.onActionRenamed?()
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeDelayField(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let field = NSTextField(string: String(format: "%g", (try? action.delay.value()) ?? 0))
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            action?.delay.onNext(Double(new) ?? 0)
        }
        let unit = NSTextField(labelWithString: "초")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [field, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func makeCountField(_ action: AutoAction, disposeBag: DisposeBag, suffix: String) -> NSView {
        let field = NSTextField(string: String((try? action.count.value()) ?? 1))
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            action?.count.onNext(Int(new) ?? 1)
        }
        let unit = NSTextField(labelWithString: suffix)
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [field, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func makeTextField(_ action: AutoAction, disposeBag: DisposeBag, placeholder: String) -> NSView {
        let field = NSTextField(string: (try? action.text.value()) ?? "")
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            action?.text.onNext(new)
        }
        return field
    }

    /// Wait-time picker — reuses `DateTimePickerControl` so the user gets the
    /// same calendar+clock+text popover as the Start time picker. Reads/writes
    /// `action.text` in "yyyy-MM-dd HH:mm:ss" format; legacy time-only values
    /// ("HH:mm:ss" / "HH:mm") are combined with today's date for display.
    private func makeWaitTimeControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let picker = DateTimePickerControl()
        picker.includesSeconds = true
        picker.translatesAutoresizingMaskIntoConstraints = false

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        // Initial value: parse whatever is in action.text.
        let raw = (try? action.text.value()) ?? ""
        var initial: Date?
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "HH:mm:ss", "HH:mm"] {
            formatter.dateFormat = fmt
            if let parsed = formatter.date(from: raw) {
                if fmt.hasPrefix("yyyy") {
                    initial = parsed
                } else {
                    // Time-only — anchor on today so the picker shows it
                    // alongside the current date instead of 1970.
                    let cal = Calendar.current
                    var comps = cal.dateComponents([.year, .month, .day], from: Date())
                    let t = cal.dateComponents([.hour, .minute, .second], from: parsed)
                    comps.hour = t.hour; comps.minute = t.minute; comps.second = t.second
                    initial = cal.date(from: comps)
                }
                break
            }
        }
        picker.dateValue = initial ?? Date()

        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        picker.onChange = { [weak action] date in
            action?.text.onNext(formatter.string(from: date))
        }
        return picker
    }

    /// Snapshot thumbnail showing what was captured at the moment the user
    /// committed the OCR position. Loads from `OCRSnapshotStore` and
    /// auto-refreshes via `.ocrSnapshotChanged` notifications.
    private func makeOCRSnapshotView(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let placeholder = NSTextField(labelWithString: "(아직 캡처되지 않음)")
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 240),
            container.heightAnchor.constraint(equalToConstant: 240),
        ])

        let actionId = action.id
        func reload() {
            let img = OCRSnapshotStore.shared.load(actionId: actionId)
            imageView.image = img
            placeholder.isHidden = (img != nil)
        }
        reload()

        NotificationCenter.default.rx.notification(.ocrSnapshotChanged)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { note in
                guard let id = note.userInfo?["id"] as? String, id == actionId else { return }
                reload()
            })
            .disposed(by: disposeBag)

        return container
    }

    /// Slider + number field pair for the OCR scan area size. Both stay in
    /// sync; values clamp to 50…600 px in 25 px steps. Persists to
    /// `action.count` (0 means "default 200").
    private func makeScanSizeControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let stored = (try? action.count.value()) ?? 0
        let initial = stored > 0 ? stored : Int(Constants.ocrCaptureSize)

        let slider = NSSlider(value: Double(initial),
                              minValue: 50,
                              maxValue: 600,
                              target: nil,
                              action: nil)
        slider.numberOfTickMarks = (600 - 50) / 25 + 1
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let field = NSTextField(string: "\(initial)")
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let unit = NSTextField(labelWithString: "px")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let state = ScanSizeState(action: action, slider: slider, field: field)
        slider.target = state
        slider.action = #selector(ScanSizeState.sliderChanged)
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak state] _ in
            state?.fieldChanged()
        }
        objc_setAssociatedObject(field, &Self.scanSizeStateAssocKey,
                                 state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [slider, field, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static var scanSizeStateAssocKey: UInt8 = 0

    /// Returns the mode dropdown (intended for the row's label slot) and the
    /// recorder/text-field stack (the row's control). Splitting them lets
    /// the caller wire the popup directly into `addRow(labelView:…)` instead
    /// of having a separate "키" label.
    private func makeCustomKeyControl(_ action: AutoAction, disposeBag: DisposeBag)
        -> (modePopup: NSView, control: NSView) {
        let initial = CustomKey.decode((try? action.text.value()) ?? "")

        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["키", "텍스트"])
        modePopup.selectItem(at: initial.isText ? 1 : 0)
        modePopup.translatesAutoresizingMaskIntoConstraints = false

        // 키 모드 레코더 — 클릭 후 누른 단축키를 캡처.
        let recorder = KeyRecorderView()
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
        if !initial.isText {
            // 공백 문자는 "space" 대신 실제 공백으로 표시 — 사용자가 직접
            // 키를 다시 누르면 정상적으로 "space" 로 다시 인코딩됨.
            var k = initial
            if k.key.lowercased() == "space" { k.key = " " }
            recorder.customKey = k
        }

        // 텍스트 모드 입력 필드 — 자유 입력.
        let textField = NSTextField(string: initial.isText ? initial.key : "")
        textField.placeholderString = "여러 글자 입력"
        textField.bezelStyle = .roundedBezel
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let state = CustomKeyState(action: action,
                                   modePopup: modePopup,
                                   recorder: recorder,
                                   textField: textField)
        state.applyModeUI()

        modePopup.target = state
        modePopup.action = #selector(CustomKeyState.modeChanged)
        recorder.onChange = { [weak state] _ in state?.commit() }
        textField.delegate = TextFieldChangeDelegate.attach(to: textField) { [weak state] _ in
            state?.commit()
        }
        objc_setAssociatedObject(textField, &Self.customKeyStateAssocKey,
                                 state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Control side of the row: just the recorder + text field (only one
        // is visible at a time, driven by the mode popup).
        let controlStack = NSStackView(views: [recorder, textField])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 6
        return (modePopup, controlStack)
    }

    private static var customKeyStateAssocKey: UInt8 = 0

    /// Variant of `makePointPicker` for the OCR action — its pick button
    /// shows the floating ScanPreviewPanel + OCRDebugWindow with a live OCR
    /// stream that follows the cursor, so the user can verify the target
    /// text is recognized before committing the position.
    private func makeOCRPointPicker(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let display = NSTextField(labelWithString: "")
        display.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        display.textColor = .labelColor
        display.wantsLayer = true
        display.layer?.borderWidth = 1
        display.layer?.borderColor = NSColor.separatorColor.cgColor
        display.layer?.cornerRadius = 6
        display.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        display.cell?.usesSingleLineMode = true
        display.translatesAutoresizingMaskIntoConstraints = false
        display.heightAnchor.constraint(equalToConstant: 22).isActive = true

        action.point
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { p in
                display.stringValue = (p == .zero ? "  (미설정)" : "  \(Int(p.x)), \(Int(p.y))")
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: "📍 위치 지정", target: self,
                                  action: #selector(pickOCRPoint(_:)))
        pickButton.bezelStyle = .roundRect
        pickButton.controlSize = .small
        objc_setAssociatedObject(pickButton, &Self.actionAssocKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(pickButton, &Self.displayAssocKey, display, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [display, pickButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makePointPicker(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let display = NSTextField(labelWithString: "")
        display.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        display.textColor = .labelColor
        display.wantsLayer = true
        display.layer?.borderWidth = 1
        display.layer?.borderColor = NSColor.separatorColor.cgColor
        display.layer?.cornerRadius = 6
        display.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        display.cell?.usesSingleLineMode = true
        display.translatesAutoresizingMaskIntoConstraints = false
        display.heightAnchor.constraint(equalToConstant: 22).isActive = true

        action.point
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { p in
                display.stringValue = (p == .zero ? "  (미설정)" : "  \(Int(p.x)), \(Int(p.y))")
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: "📍 위치 지정", target: self,
                                  action: #selector(pickPoint(_:)))
        pickButton.bezelStyle = .roundRect
        pickButton.controlSize = .small
        objc_setAssociatedObject(pickButton, &Self.actionAssocKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(pickButton, &Self.displayAssocKey, display, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [display, pickButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeWindowFrameRow(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let display = NSTextField(labelWithString: "")
        display.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        display.wantsLayer = true
        display.layer?.borderWidth = 1
        display.layer?.borderColor = NSColor.separatorColor.cgColor
        display.layer?.cornerRadius = 6
        display.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        display.translatesAutoresizingMaskIntoConstraints = false
        display.heightAnchor.constraint(equalToConstant: 22).isActive = true

        action.text
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { s in
                display.stringValue = s.isEmpty ? "  (미설정)" : "  \(s)"
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: "📍 윈도우 선택", target: self,
                                  action: #selector(pickWindow(_:)))
        pickButton.bezelStyle = .roundRect
        pickButton.controlSize = .small
        objc_setAssociatedObject(pickButton, &Self.actionAssocKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let restore = NSButton(title: "🪟 복원", target: self, action: #selector(restoreWindow(_:)))
        restore.bezelStyle = .roundRect
        restore.controlSize = .small
        restore.contentTintColor = .controlAccentColor
        objc_setAssociatedObject(restore, &Self.actionAssocKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [display, pickButton, restore])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: - Picker actions (target/action via associated objects)

    private static var actionAssocKey: UInt8 = 0
    private static var displayAssocKey: UInt8 = 0

    @objc private func pickOCRPoint(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        let display = objc_getAssociatedObject(sender, &Self.displayAssocKey) as? NSTextField
        Self.armPickerVisuals(button: sender, display: display, active: true)

        let targetText = (try? action.text.value()) ?? ""
        // Match the runtime: per-action scan size from action.count
        // (0 = default 200).
        let storedSize = (try? action.count.value()) ?? 0
        let captureSize: CGFloat = storedSize > 0
            ? CGFloat(storedSize)
            : Constants.ocrCaptureSize
        ScanPreviewPanel.shared.show(size: captureSize)
        OCRDebugWindow.shared.show(target: targetText)

        // Live OCR capture that follows the cursor — same pattern as the
        // legacy ActionCellFactory.makeOCRCell.onClickPosition.
        let capturer = ScreenCapturer()
        capturer.showsCursor = true
        let half = captureSize / 2
        func rectAt(_ pt: CGPoint) -> CGRect {
            CGRect(x: pt.x - half, y: pt.y - half, width: captureSize, height: captureSize)
        }

        // Throttle Vision so a 60fps SCStream doesn't backlog the main thread.
        var lastProcessAt = Date.distantPast
        var ocrInFlight = false
        // Latest image delivered by the live capturer — saved as the
        // action's snapshot when the user commits the position.
        var lastImage: NSImage?
        let liveHandler: (NSImage?) -> Void = { img in
            if let img = img { lastImage = img }
            let now = Date()
            guard now.timeIntervalSince(lastProcessAt) > 0.15, !ocrInFlight else { return }
            lastProcessAt = now
            guard let img = img, let cgImg = img.toCGImage() else { return }
            ocrInFlight = true
            recognizeText(from: cgImg) { results in
                OCRDebugWindow.shared.update(image: img, results: results, target: targetText)
                ocrInFlight = false
            }
        }
        capturer.handler = liveHandler
        capturer.start(rect: rectAt(NSEvent.mouseLocation))

        // Restart the stream when the cursor crosses display boundaries.
        // Compare by displayID rather than NSScreen identity (the latter can
        // return distinct instances for the same physical display).
        func displayID(at point: CGPoint) -> CGDirectDisplayID? {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return NSScreen.screens.first { $0.frame.contains(point) }?
                .deviceDescription[key] as? CGDirectDisplayID
        }
        var lastDisplayID = displayID(at: NSEvent.mouseLocation)
        var globalMoveMonitor: Any?
        var localMoveMonitor: Any?
        let updateForMove: () -> Void = {
            let pt = NSEvent.mouseLocation
            let rect = rectAt(pt)
            let id = displayID(at: pt)
            if let id = id, id != lastDisplayID {
                capturer.stop()
                capturer.handler = liveHandler   // stop() clears it
                capturer.showsCursor = true
                capturer.start(rect: rect)
                lastDisplayID = id
            } else {
                capturer.updateCaptureRect(rect)
            }
        }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            DispatchQueue.main.async { updateForMove() }
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            updateForMove()
            return event
        }

        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { [weak self] (point, _) in
            guard let self = self else { return }
            action.point.onNext(point)
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: display, active: false)
            capturer.stop()
            if let m = globalMoveMonitor { NSEvent.removeMonitor(m) }
            if let m = localMoveMonitor { NSEvent.removeMonitor(m) }
            // Persist the most recent live preview as the action's snapshot
            // so the OCR card's preview thumbnail reflects what was picked.
            if let img = lastImage {
                OCRSnapshotStore.shared.save(img, actionId: action.id)
            }
            DispatchQueue.main.async {
                ScanPreviewPanel.shared.hide()
                OCRDebugWindow.shared.hide()
            }
        }
        mouseListener.start()
    }

    @objc private func pickPoint(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        let display = objc_getAssociatedObject(sender, &Self.displayAssocKey) as? NSTextField
        Self.armPickerVisuals(button: sender, display: display, active: true)

        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { [weak self] (point, _) in
            guard let self = self else { return }
            action.point.onNext(point)
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: display, active: false)
        }
        mouseListener.start()
    }

    @objc private func pickWindow(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        Self.armPickerVisuals(button: sender, display: nil, active: true)
        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { [weak self] (point, _) in
            guard let self = self else { return }
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: nil, active: false)
            if let frame = WindowFrameUtil.windowFrame(at: point) {
                let encoded = WindowFrameUtil.encode(frame)
                action.text.onNext(encoded)
                AppLogger.shared.log("🪟 윈도우 선택: \(encoded)")
            } else {
                AppLogger.shared.log("⚠️ 해당 위치에서 윈도우를 찾지 못했습니다")
            }
        }
        mouseListener.start()
    }

    /// Toggle the recording-state visuals on a position-pick button + its
    /// optional coordinate display. Active = red bezel + red border on the
    /// display; inactive = system defaults. Also pushes/pops a custom
    /// crosshair cursor so the user has clear feedback that the next click
    /// will be captured.
    private static func armPickerVisuals(button: NSButton, display: NSTextField?, active: Bool) {
        if active {
            button.bezelColor = .systemRed
            button.contentTintColor = .white
            display?.layer?.borderColor = NSColor.systemRed.cgColor
            display?.layer?.borderWidth = 2
            pickerCursor.push()
        } else {
            button.bezelColor = nil
            button.contentTintColor = nil
            display?.layer?.borderColor = NSColor.separatorColor.cgColor
            display?.layer?.borderWidth = 1
            NSCursor.pop()
        }
    }

    /// Custom crosshair cursor used while a position-pick session is active.
    /// Drawn programmatically so we don't need an asset file.
    private static let pickerCursor: NSCursor = {
        let size: CGFloat = 32
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // Outer white "halo" so the crosshair is visible on dark and light
            // backgrounds alike.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(3)
            let mid = size / 2
            ctx.move(to: CGPoint(x: 0, y: mid));    ctx.addLine(to: CGPoint(x: size, y: mid))
            ctx.move(to: CGPoint(x: mid, y: 0));    ctx.addLine(to: CGPoint(x: mid, y: size))
            ctx.strokePath()

            // Red crosshair lines on top.
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: 0, y: mid));    ctx.addLine(to: CGPoint(x: size, y: mid))
            ctx.move(to: CGPoint(x: mid, y: 0));    ctx.addLine(to: CGPoint(x: mid, y: size))
            ctx.strokePath()

            // Center hollow circle marking the exact click point.
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: mid - 4, y: mid - 4, width: 8, height: 8))
            ctx.restoreGState()
        }
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }()

    @objc private func restoreWindow(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        let s = (try? action.text.value()) ?? ""
        guard let frame = WindowFrameUtil.decode(s) else {
            AppLogger.shared.log("⚠️ 저장된 프레임 없음 — 먼저 윈도우를 선택하세요")
            return
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if WindowFrameUtil.applyFrame(frame, toWindowAt: center) {
            AppLogger.shared.log("🪟 프레임 복원: \(s)")
        } else {
            AppLogger.shared.log("⚠️ 저장된 중심 좌표에 해당하는 윈도우 없음")
        }
    }
}

// MARK: - Card helpers

/// NSStackView whose coordinate system is top-down (`isFlipped == true`),
/// so it can be used as an NSScrollView's document view without content
/// gravitating to the bottom of the visible area.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A single card section: rounded-corner panel with a small uppercase header
/// and child rows. Mirrors the `.card` element in the redesign HTML.
private final class CardView: NSView {
    private let stack: NSStackView

    init(title: String) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.addArrangedSubview(header)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                         constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func addRow(label: String, control: NSView, hint: String? = nil) {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .medium)
        labelView.textColor = .secondaryLabelColor
        addRow(labelView: labelView, control: control, hint: hint)
    }

    /// Variant of `addRow` that takes an arbitrary view in place of the
    /// usual text label — used by the .key form so the mode dropdown sits
    /// in the label column.
    func addRow(labelView: NSView, control: NSView, hint: String? = nil) {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 100).isActive = true

        var trailing: [NSView] = [control]
        if let hint = hint, !hint.isEmpty {
            let h = NSTextField(labelWithString: hint)
            h.font = .systemFont(ofSize: 11)
            h.textColor = .tertiaryLabelColor
            trailing.append(h)
        }
        let trailStack = NSStackView(views: trailing)
        trailStack.orientation = .vertical
        trailStack.alignment = .leading
        trailStack.spacing = 4
        trailStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [labelView, trailStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                   constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
    }
}

private extension ActionDetailBuilder {
    func makeCard(title: String) -> CardView { CardView(title: title) }
}

// MARK: - Action type helpers

enum ActionIcons {
    /// SF Symbol image for the given action type. Each entry has fallbacks
    /// in case a symbol is unavailable on the target macOS version. Returns
    /// nil if every candidate fails (the call site renders an empty slot).
    static func image(for type: AutoAction.ActionType) -> NSImage? {
        let names: [String]
        switch type {
        case .click:        names = ["cursorarrow.click.2", "cursorarrow.click", "cursorarrow"]
        case .scroll:       names = ["arrow.down.circle", "arrow.down"]
        case .key:          names = ["keyboard", "command"]
        case .wait(.click): names = ["hand.tap", "hand.tap.fill", "hourglass"]
        case .wait(.enter): names = ["hourglass.bottomhalf.filled", "hourglass"]
        case .wait(.code):  names = ["lock.shield", "lock.shield.fill", "key"]
        case .wait(.time):  names = ["clock", "alarm"]
        case .ocr:          names = ["text.viewfinder"]
        case .script:       names = ["curlybraces", "chevron.left.forwardslash.chevron.right"]
        case .setURL:       names = ["globe"]
        case .openChrome:   names = ["plus.rectangle.on.rectangle", "rectangle.on.rectangle"]
        case .windowFrame:  names = ["macwindow", "rectangle"]
        }
        let label = ActionIcons.label(for: type)
        for name in names {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: label) {
                return img
            }
        }
        return nil
    }

    /// Legacy emoji fallback — kept for places that still need a string
    /// (e.g. context menu items where embedding NSImage is more involved).
    static func icon(for type: AutoAction.ActionType) -> String {
        switch type {
        case .click:                return "🖱"
        case .scroll:               return "⬇"
        case .key:                  return "⌨︎"
        case .wait(.click):         return "⏳"
        case .wait(.enter):         return "⏎⏳"
        case .wait(.code):          return "🔐"
        case .wait(.time):          return "⏱"
        case .ocr:                  return "🔍"
        case .script:               return "📝"
        case .setURL:               return "🌐"
        case .openChrome:           return "🆕"
        case .windowFrame:          return "🪟"
        }
    }

    static func label(for type: AutoAction.ActionType) -> String {
        switch type {
        case .click:                return "클릭"
        case .scroll:               return "스크롤"
        case .key:                  return "키 입력"
        case .wait(.click):         return "클릭 대기"
        case .wait(.enter):         return "엔터 대기"
        case .wait(.code):          return "인증코드 대기"
        case .wait(.time):          return "시간 대기"
        case .ocr:                  return "OCR 클릭"
        case .script:               return "스크립트 실행"
        case .setURL:               return "URL 설정"
        case .openChrome:           return "새 Chrome 창"
        case .windowFrame:          return "창 프레임"
        }
    }
}

private extension AutoAction.ActionType {
    var isOpenChrome: Bool {
        if case .openChrome = self { return true }
        return false
    }
    var defaultURL: String? {
        switch self {
        case .setURL(let url):     return url
        case .openChrome(let url): return url
        default:                   return nil
        }
    }
}

// MARK: - Key recorder (Xcode-style shortcut input)

/// Single-tap shortcut recorder. Click → next keypress (with modifier flags)
/// becomes the value. Esc cancels. Mirrors Xcode's storyboard "Key Equivalent"
/// field — replaces the inline modifier checkboxes in 키 mode.
final class KeyRecorderView: NSView {
    var customKey: CustomKey = CustomKey() {
        didSet { updateTitle() }
    }
    var onChange: ((CustomKey) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private var isRecording = false { didSet { updateAppearance() } }
    private var monitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        updateTitle()
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit { stopRecording() }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Local monitor consumes all keyDown events while recording — required
        // to capture Tab/Esc/etc., which the window would otherwise route to
        // focus-management.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            self.handleKeyDown(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var k = CustomKey()
        if mods.contains(.command) { k.modifiers.insert(.command) }
        if mods.contains(.shift)   { k.modifiers.insert(.shift) }
        if mods.contains(.control) { k.modifiers.insert(.control) }
        if mods.contains(.option)  { k.modifiers.insert(.option) }
        k.key = Self.keyName(from: event)
        customKey = k
        onChange?(k)
        stopRecording()
    }

    private static func keyName(from event: NSEvent) -> String {
        switch event.keyCode {
        case 49:  return "space"
        case 48:  return "tab"
        case 36, 76: return "return"
        case 53:  return "escape"
        case 51, 117: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            // charactersIgnoringModifiers gives the unmodified character —
            // forced to lowercase so "S" with Shift becomes "s" + .shift.
            let raw = event.charactersIgnoringModifiers ?? ""
            return raw.isEmpty ? "" : String(raw.first!).lowercased()
        }
    }

    private func updateAppearance() {
        if isRecording {
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.borderWidth = 2
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        }
        updateTitle()
    }

    private func updateTitle() {
        if isRecording {
            titleLabel.stringValue = "키 입력 대기..."
            titleLabel.textColor = .systemRed
            return
        }
        titleLabel.textColor = .labelColor
        var parts: [String] = []
        if customKey.modifiers.contains(.control) { parts.append("⌃") }
        if customKey.modifiers.contains(.option)  { parts.append("⌥") }
        if customKey.modifiers.contains(.shift)   { parts.append("⇧") }
        if customKey.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.displayName(for: customKey.key))
        let s = parts.joined(separator: "")
        titleLabel.stringValue = s.isEmpty ? "클릭하여 단축키 입력" : s
    }

    private static func displayName(for key: String) -> String {
        switch key.lowercased() {
        case "":                      return ""
        case "space", " ":            return "Space"
        case "tab", "\t":             return "⇥"
        case "return", "enter", "\n": return "↵"
        case "escape", "esc":         return "⎋"
        case "delete", "backspace":   return "⌫"
        case "left":                  return "←"
        case "right":                 return "→"
        case "up":                    return "↑"
        case "down":                  return "↓"
        default:                      return key.uppercased()
        }
    }
}

// MARK: - Custom-key state

/// Mediates between the mode dropdown, the key recorder (키 mode), and the
/// text field (텍스트 mode). Whichever is active is read on commit and
/// (re-)serialised into `AutoAction.text`.
private final class CustomKeyState: NSObject {
    private weak var action: AutoAction?
    private let modePopup: NSPopUpButton
    private let recorder: KeyRecorderView
    private let textField: NSTextField

    init(action: AutoAction,
         modePopup: NSPopUpButton,
         recorder: KeyRecorderView,
         textField: NSTextField) {
        self.action = action
        self.modePopup = modePopup
        self.recorder = recorder
        self.textField = textField
    }

    private var isText: Bool { modePopup.indexOfSelectedItem == 1 }

    func applyModeUI() {
        recorder.isHidden = isText
        textField.isHidden = !isText
    }

    @objc func modeChanged() {
        applyModeUI()
        commit()
    }

    @objc func commit() {
        guard let action = action else { return }
        var k = CustomKey()
        k.isText = isText
        if k.isText {
            k.key = textField.stringValue
        } else {
            k = recorder.customKey
            k.isText = false
        }
        action.text.onNext(k.encode())
    }
}

// MARK: - OCR scan-size state

/// Keeps the OCR scan-size slider and number field in sync, persisting the
/// chosen value (in pixels) to `action.count`.
private final class ScanSizeState: NSObject {
    private weak var action: AutoAction?
    private let slider: NSSlider
    private let field: NSTextField

    init(action: AutoAction, slider: NSSlider, field: NSTextField) {
        self.action = action
        self.slider = slider
        self.field = field
    }

    @objc func sliderChanged() {
        let v = Int(slider.doubleValue)
        field.stringValue = "\(v)"
        action?.count.onNext(v)
    }

    func fieldChanged() {
        let raw = Int(field.stringValue) ?? Int(Constants.ocrCaptureSize)
        let clamped = max(50, min(600, raw))
        // Snap to nearest 25 to match the slider's tick steps.
        let snapped = Int(round(Double(clamped) / 25.0)) * 25
        slider.doubleValue = Double(snapped)
        if snapped != raw {
            field.stringValue = "\(snapped)"
        }
        action?.count.onNext(snapped)
    }
}

// MARK: - Tiny NSTextField change-delegate shim

/// Forwards `controlTextDidChange` and `controlTextDidEndEditing` to a closure
/// and keeps itself alive via objc_setAssociatedObject so callers don't have
/// to manually retain the delegate.
private final class TextFieldChangeDelegate: NSObject, NSTextFieldDelegate {
    private let onChange: (String) -> Void
    init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }

    func controlTextDidChange(_ note: Notification) {
        guard let f = note.object as? NSTextField else { return }
        onChange(f.stringValue)
    }
    func controlTextDidEndEditing(_ note: Notification) {
        guard let f = note.object as? NSTextField else { return }
        onChange(f.stringValue)
    }

    private static var key: UInt8 = 0

    @discardableResult
    static func attach(to field: NSTextField, _ onChange: @escaping (String) -> Void) -> TextFieldChangeDelegate {
        let d = TextFieldChangeDelegate(onChange)
        objc_setAssociatedObject(field, &key, d, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return d
    }
}
