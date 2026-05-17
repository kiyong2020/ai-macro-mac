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
        let label = NSTextField(labelWithString: L("Select an action from the left"))
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
        // Wrap the label in a container so we get real horizontal *and*
        // vertical padding (NSTextField's whitespace-based padding only adds
        // horizontal width, not height).
        let typeLabel = NSTextField(labelWithString: ActionIcons.label(for: action.type))
        typeLabel.font = .systemFont(ofSize: 11)
        typeLabel.textColor = .secondaryLabelColor
        typeLabel.cell?.lineBreakMode = .byClipping
        typeLabel.translatesAutoresizingMaskIntoConstraints = false

        let typeTag = NSView()
        typeTag.wantsLayer = true
        typeTag.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        typeTag.layer?.cornerRadius = 10
        typeTag.layer?.borderWidth = 1
        typeTag.layer?.borderColor = NSColor.separatorColor.cgColor
        typeTag.translatesAutoresizingMaskIntoConstraints = false
        typeTag.addSubview(typeLabel)
        NSLayoutConstraint.activate([
            typeLabel.leadingAnchor.constraint(equalTo: typeTag.leadingAnchor, constant: 10),
            typeLabel.trailingAnchor.constraint(equalTo: typeTag.trailingAnchor, constant: -10),
            typeLabel.topAnchor.constraint(equalTo: typeTag.topAnchor, constant: 4),
            typeLabel.bottomAnchor.constraint(equalTo: typeTag.bottomAnchor, constant: -4),
        ])
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
        let basic = makeCard(title: L("Basic"))
        basic.addRow(label: L("Name"), control: makeNameField(action, disposeBag: disposeBag))
        if shouldShowDelay(for: action.type) {
            basic.addRow(label: L("Delay"),
                         control: makeDelayField(action, disposeBag: disposeBag),
                         hint: "액션 실행 후 다음 단계까지 대기 (초)")
        }
        cards.append(basic)

        // Type-specific card.
        switch action.type {
        case .click:
            let card = makeCard(title: L("Click Position"))
            card.addRow(label: L("Position"), control: makePointPicker(action, disposeBag: disposeBag),
                        hint: "버튼을 누르고 화면에서 위치를 클릭")
            card.addRow(label: L("Button"),
                        control: makeClickButtonControl(action, disposeBag: disposeBag),
                        hint: "좌클릭 / 우클릭 선택")
            card.addRow(label: L("Modifiers"),
                        control: makeClickModifiersControl(action, disposeBag: disposeBag),
                        hint: "클릭 시 함께 누를 키 (⌘ ⇧ ⌃ ⌥)")
            card.addRow(label: L("Repeat"), control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "위치 지정 직후 캡처된 클릭 영역")
            cards.append(card)

        case .scroll:
            let card = makeCard(title: L("Scroll"))
            card.addRow(label: L("Direction"),
                        control: makeScrollDirectionControl(action, disposeBag: disposeBag),
                        hint: L("Simulates mouse wheel / Magic Mouse swipe"))
            card.addRow(label: L("Repeat"),
                        control: makeCountField(action, disposeBag: disposeBag, suffix: "틱"),
                        hint: "1틱 ≈ 휠 한 칸 (3줄)")
            card.addRow(label: L("Options"),
                        control: makeScrollSlowControl(action, disposeBag: disposeBag),
                        hint: L("Spaces wheel ticks further apart so apps like Android Emulator don't add momentum scrolling."))
            card.addRow(label: L("Record"),
                        control: makeScrollRecorderButton(action, disposeBag: disposeBag),
                        hint: "버튼을 누른 뒤 실제로 스크롤하면 방향·틱 수가 자동 입력")
            cards.append(card)

        case .drag:
            let card = makeCard(title: L("Drag"))
            card.addRow(label: L("Path"),
                        control: makeDragRecorder(action, disposeBag: disposeBag),
                        hint: "녹화 버튼을 누른 뒤 실제로 마우스를 드래그하세요")
            card.addRow(label: L("Repeat"), control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "드래그 시작 위치에서 캡처된 영역")
            cards.append(card)

        case .key:
            let card = makeCard(title: L("Key"))
            let custom = makeCustomKeyControl(action, disposeBag: disposeBag)
            // 모드 드롭다운이 곧 라벨 역할 — 별도의 "키" 라벨은 두지 않음.
            card.addRow(labelView: custom.modePopup,
                        control: custom.control,
                        hint: "키 모드: 클릭 후 단축키 입력 / 텍스트 모드: 자유 입력")
            card.addRow(label: L("Repeat"), control: makeCountField(action, disposeBag: disposeBag, suffix: "회"))
            cards.append(card)

        case .wait:
            cards.append(makeWaitCard(action, disposeBag: disposeBag))

        case .ocr:
            let card = makeCard(title: L("OCR Search"))
            card.addRow(label: L("Search Text"),
                        control: makeTextField(action, disposeBag: disposeBag, placeholder: "구매"),
                        hint: "캡처 영역에서 이 텍스트를 인식하면 클릭")
            card.addRow(label: L("Scan Area"),
                        control: makeOCRAreaPicker(action, disposeBag: disposeBag),
                        hint: "화면에서 직접 드래그하여 OCR 영역의 위치와 크기를 한 번에 지정")
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "영역 지정 직후 캡처된 스캔 영역")
            cards.append(card)

        case .script:
            let card = makeCard(title: L("Script"))
            card.addRow(label: L("Target Position"),
                        control: makePointPicker(action, disposeBag: disposeBag))
            card.addRow(label: L("Text Argument"),
                        control: makeTextField(action, disposeBag: disposeBag,
                                               placeholder: "${TEXT} 자리표시자 값"),
                        hint: "코드 안의 ${TEXT} 가 이 값으로 치환됩니다")
            cards.append(card)

        case .setURL, .openChrome:
            let card = makeCard(title: action.type.isOpenChrome ? L("New Chrome Window") : L("URL Settings"))
            // The default URL is taken from the enum payload; pre-fill if blank.
            if (try? action.text.value())?.isEmpty == true {
                action.text.onNext(action.type.defaultURL ?? "")
            }
            card.addRow(label: L("URL"),
                        control: makeTextField(action, disposeBag: disposeBag,
                                               placeholder: "https://..."))
            cards.append(card)

        case .openBrowser:
            let card = makeCard(title: L("Browser"))
            seedBrowserDefaults(action)
            card.addRow(label: L("URL"),
                        control: makeBrowserURLField(action, disposeBag: disposeBag,
                                                     placeholder: "https://..."),
                        hint: L("Opens in default browser (Chrome / Safari / Edge etc.)"))
            card.addRow(label: L("Width"),
                        control: makeBrowserSizeControl(action, axis: .width,
                                                        disposeBag: disposeBag),
                        hint: "창 너비 (px)")
            card.addRow(label: L("Height"),
                        control: makeBrowserSizeControl(action, axis: .height,
                                                        disposeBag: disposeBag),
                        hint: "창 높이 (px)")
            card.addRow(label: L("Location"),
                        control: makeBrowserPositionPicker(action, disposeBag: disposeBag),
                        hint: "버튼을 누르고 화면에서 창 중심이 될 위치를 클릭")
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "위치 지정 직후 캡처된 창 영역")
            cards.append(card)

        case .windowFrame:
            let card = makeCard(title: L("Window Frame"))
            card.addRow(label: L("Saved Frame"),
                        control: makeWindowFrameRow(action, disposeBag: disposeBag),
                        hint: "x, y, width, height")
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "윈도우 선택 직후 캡처된 영역")
            cards.append(card)

        case .nextScenario:
            let card = makeCard(title: L("Go to Flow"))
            addNextScenarioRows(to: card, action: action, disposeBag: disposeBag)
            cards.append(card)

        case .aiGen:
            let card = makeCard(title: L("AI Generate"))
            card.addRow(label: L("Instruction"),
                        control: makeAIGenInstructionField(action, disposeBag: disposeBag,
                                                           placeholder: "예: 로그인 버튼을 클릭"),
                        hint: "캡처 영역에 대해 무엇을 할지 자연어로 적어주세요. 서버가 동작을 자동 생성합니다.")
            card.addRow(label: L("End Condition"),
                        control: makeAIGenEndConditionField(action, disposeBag: disposeBag,
                                                            placeholder: "예: 로그인 화면이 보이면 종료"),
                        hint: "비워두면 1회만 호출 후 종료. 입력 시 조건이 충족될 때까지 반복")
            card.addRow(label: L("Interval"),
                        control: makeAIGenIntervalField(action, disposeBag: disposeBag),
                        hint: "서버 호출 사이 대기 시간 (각 턴마다 화면 캡처 후 액션 실행)")
            card.addRow(label: L("Scan Area"),
                        control: makeOCRAreaPicker(action, disposeBag: disposeBag),
                        hint: "AI 가 분석할 화면 영역을 드래그로 지정")
            card.addRow(label: L("Preview"),
                        control: makeActionSnapshotView(action, disposeBag: disposeBag),
                        hint: "영역 지정 직후 캡처된 스캔 영역")
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
        case .wait(.time):  return "지정한 시각이 되면 다음 단계로 진행"
        default:            return ""
        }
    }

    // MARK: - Form pieces

    private func makeNameField(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let field = NSTextField(string: action.name)
        field.bezelStyle = .roundedBezel
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak self, weak action] new in
            action?.name = new
            // name isn't a BehaviorSubject so the throttled save in
            // loadCurrentScenario doesn't pick it up — persist now or
            // restore() will revert this rename to the stale SQLite value.
            action?.save()
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
        // Reflect programmatic count updates (e.g. scroll recorder auto-fill)
        // back into the field — but skip while the user is editing so we
        // don't yank characters out from under them mid-type.
        action.count
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak field] new in
                guard let field = field, field.currentEditor() == nil else { return }
                let s = "\(new)"
                if field.stringValue != s { field.stringValue = s }
            })
            .disposed(by: disposeBag)

        let unit = NSTextField(labelWithString: suffix)
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [field, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// Add one row per FlowMode to the `.nextScenario` card. The default
    /// (first) mode shows `[Next in list, scenario1, ...]`; non-default
    /// modes prepend a `Use default` option that clears the per-mode
    /// override so they fall back to the default mode's target.
    private func addNextScenarioRows(to card: CardView,
                                     action: AutoAction,
                                     disposeBag: DisposeBag) {
        let modes = FlowModeStore.shared.flowModes
        guard let defaultModeId = modes.first?.id.uuidString else { return }
        for (i, mode) in modes.enumerated() {
            let isDefault = (i == 0)
            let popup = makeNextScenarioPopupForMode(
                action: action,
                modeId: mode.id.uuidString,
                defaultModeId: defaultModeId,
                isDefaultMode: isDefault,
                disposeBag: disposeBag
            )
            let hint = isDefault
                ? L("Stops the current flow and starts the next one in the list.")
                : nil
            card.addRow(label: mode.name, control: popup, hint: hint)
        }
    }

    private func makeNextScenarioPopupForMode(action: AutoAction,
                                              modeId: String,
                                              defaultModeId: String,
                                              isDefaultMode: Bool,
                                              disposeBag: DisposeBag) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false

        let bridge = NextScenarioPopupBridge(action: action,
                                             popup: popup,
                                             modeId: modeId,
                                             defaultModeId: defaultModeId,
                                             isDefaultMode: isDefaultMode)
        popup.target = bridge
        popup.action = #selector(NextScenarioPopupBridge.changed(_:))
        objc_setAssociatedObject(popup, &Self.nextScenarioBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        bridge.repopulate()

        // Keep the items list fresh when scenarios are added / renamed /
        // removed elsewhere in the app.
        NotificationCenter.default.rx
            .notification(ScenarioStore.didChangeNotification)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak bridge] _ in bridge?.repopulate() })
            .disposed(by: disposeBag)
        return popup
    }

    private static var nextScenarioBridgeAssocKey: UInt8 = 0

    /// 4-up direction selector for `.scroll` actions (↓ ↑ ← →). Persists
    /// the choice in `action.text` via `setScrollDirection`. Subscribes to
    /// `action.text` so a programmatic update (e.g. scroll recorder) flips
    /// the selected segment in place.
    private func makeScrollDirectionControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let segmented = NSSegmentedControl(labels: ["↓", "↑", "←", "→"],
                                           trackingMode: .selectOne,
                                           target: nil,
                                           action: nil)
        let directions: [ScrollDirection] = [.down, .up, .left, .right]
        segmented.selectedSegment = directions.firstIndex(of: action.scrollDirection) ?? 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let bridge = ScrollDirectionBridge(action: action, directions: directions)
        segmented.target = bridge
        segmented.action = #selector(ScrollDirectionBridge.changed(_:))
        objc_setAssociatedObject(segmented, &Self.scrollDirectionBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        action.text
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak segmented, weak action] _ in
                guard let segmented = segmented, let action = action else { return }
                let idx = directions.firstIndex(of: action.scrollDirection) ?? 0
                if segmented.selectedSegment != idx {
                    segmented.selectedSegment = idx
                }
            })
            .disposed(by: disposeBag)
        return segmented
    }

    private static var scrollDirectionBridgeAssocKey: UInt8 = 0

    /// "Slow interval" checkbox + a numeric ms field that's enabled only
    /// while the checkbox is on. The checkbox flips `ScrollConfig.slow`
    /// (widening the inter-tick gap so flick-detecting receivers like
    /// Android Emulator's Qt widgets don't synthesise momentum), and the
    /// field lets the user tune the exact step delay used by the runner.
    private func makeScrollSlowControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: L("Slow interval"),
                                target: nil, action: nil)
        checkbox.state = action.scrollConfig.slow ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let delayField = NSTextField(string: "\(action.scrollConfig.slowDelayMs)")
        delayField.bezelStyle = .roundedBezel
        delayField.translatesAutoresizingMaskIntoConstraints = false
        delayField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        delayField.isEnabled = action.scrollConfig.slow
        delayField.delegate = TextFieldChangeDelegate.attach(to: delayField) { [weak action] new in
            let parsed = Int(new) ?? ScrollConfig.defaultSlowDelayMs
            action?.setScrollSlowDelay(parsed)
        }

        let unit = NSTextField(labelWithString: "ms")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let bridge = ScrollSlowBridge(action: action,
                                      checkbox: checkbox,
                                      delayField: delayField)
        checkbox.target = bridge
        checkbox.action = #selector(ScrollSlowBridge.toggled)
        objc_setAssociatedObject(checkbox, &Self.scrollSlowBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Keep the checkbox + field in sync when text changes from elsewhere
        // (e.g. scroll recorder rewriting the direction).
        action.text
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak checkbox, weak delayField, weak action] _ in
                guard let action = action else { return }
                let cfg = action.scrollConfig
                if let checkbox = checkbox {
                    let desired: NSControl.StateValue = cfg.slow ? .on : .off
                    if checkbox.state != desired { checkbox.state = desired }
                }
                if let field = delayField {
                    field.isEnabled = cfg.slow
                    // Don't yank characters out from under the user mid-type.
                    if field.currentEditor() == nil {
                        let s = "\(cfg.slowDelayMs)"
                        if field.stringValue != s { field.stringValue = s }
                    }
                }
            })
            .disposed(by: disposeBag)

        let row = NSStackView(views: [checkbox, delayField, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private static var scrollSlowBridgeAssocKey: UInt8 = 0

    /// "🎯 스크롤 녹화" button — taps the system scroll event stream,
    /// accumulates deltas until the user pauses, then auto-fills direction
    /// and tick count on the action.
    private func makeScrollRecorderButton(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let button = NSButton(title: L("🎯 Record Scroll"),
                              target: self,
                              action: #selector(recordScroll(_:)))
        button.bezelStyle = .roundRect
        button.controlSize = .small
        button.toolTip = "버튼을 누른 뒤 자유롭게 클릭(스크롤 전 클릭은 모두 무시) → 스크롤 → 한 번 더 클릭하면 녹화 종료."
        objc_setAssociatedObject(button, &Self.actionAssocKey,
                                 action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return button
    }

    @objc private func recordScroll(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey)
                as? AutoAction else { return }
        // Drop any prior recorder still anchored to the button.
        objc_setAssociatedObject(sender, &Self.scrollRecorderAssocKey,
                                 nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        Self.armPickerVisuals(button: sender, display: nil, active: true, pushCursor: false)
        ScanPreviewPanel.shared.show(rectSize: CGSize(width: 40, height: 40))

        let recorder = ScrollWheelRecorder()
        // Anchor so the CGEventTap's unretained pointer stays valid past
        // this stack frame — same pattern as `MouseDragRecorder`.
        objc_setAssociatedObject(sender, &Self.scrollRecorderAssocKey,
                                 recorder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let esc = EscCancelMonitor()
        esc.onCancel = { [weak recorder, weak sender] in
            recorder?.cancel()
            if let sender = sender {
                Self.armPickerVisuals(button: sender, display: nil, active: false, pushCursor: false)
                objc_setAssociatedObject(sender, &Self.scrollRecorderAssocKey,
                                         nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
            AppLogger.shared.log("⎋ 스크롤 녹화 취소")
        }

        recorder.onEnd = { [weak action, weak sender] dy, dx in
            esc.stop()
            // Pick the dominant axis. Sign convention matches the playback
            // helper: negative wheel1 = `.down`, positive = `.up`; negative
            // wheel2 = `.right`, positive = `.left`.
            let absY = abs(dy)
            let absX = abs(dx)
            let direction: ScrollDirection
            let magnitude: CGFloat
            if absY == 0 && absX == 0 {
                // No scroll captured — leave the existing config alone.
                AppLogger.shared.log("🌀 스크롤 녹화: 입력 없음")
                if let sender = sender {
                    Self.armPickerVisuals(button: sender, display: nil, active: false, pushCursor: false)
                    objc_setAssociatedObject(sender, &Self.scrollRecorderAssocKey,
                                             nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
                DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
                return
            }
            if absY >= absX {
                direction = dy < 0 ? .down : .up
                magnitude = absY
            } else {
                direction = dx < 0 ? .right : .left
                magnitude = absX
            }
            let ticks = max(1, Int(ceil(magnitude / 3)))
            action?.setScrollDirection(direction)
            action?.count.onNext(ticks)

            if let sender = sender {
                Self.armPickerVisuals(button: sender, display: nil, active: false, pushCursor: false)
                objc_setAssociatedObject(sender, &Self.scrollRecorderAssocKey,
                                         nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
            AppLogger.shared.log("🌀 스크롤 녹화: \(direction.rawValue) \(ticks)틱")
        }
        recorder.start()
        esc.start()
    }

    private static var scrollRecorderAssocKey: UInt8 = 0

    /// 좌/우 mouse button selector for `.click` actions. Persists the choice
    /// in `action.text` via `setClickButton`.
    private func makeClickButtonControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let segmented = NSSegmentedControl(labels: ["좌", "우"],
                                           trackingMode: .selectOne,
                                           target: nil,
                                           action: nil)
        segmented.selectedSegment = action.clickButton == .right ? 1 : 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let bridge = ClickButtonBridge(action: action)
        segmented.target = bridge
        segmented.action = #selector(ClickButtonBridge.changed(_:))
        objc_setAssociatedObject(segmented, &Self.clickButtonBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return segmented
    }

    private static var clickButtonBridgeAssocKey: UInt8 = 0

    /// 4-up checkbox row for `.click` action modifier keys (⌘ ⇧ ⌃ ⌥).
    /// Each toggle flips one bit of `action.clickConfig.modifiers`, leaving
    /// the button slot and the other modifiers untouched.
    private func makeClickModifiersControl(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let entries: [(label: String, flag: NSEvent.ModifierFlags)] = [
            ("⌘", .command),
            ("⇧", .shift),
            ("⌃", .control),
            ("⌥", .option),
        ]
        let current = action.clickConfig.modifiers

        let bridges = entries.map { entry -> ClickModifierBridge in
            let checkbox = NSButton(checkboxWithTitle: entry.label,
                                    target: nil, action: nil)
            checkbox.state = current.contains(entry.flag) ? .on : .off
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            let bridge = ClickModifierBridge(action: action,
                                             flag: entry.flag,
                                             checkbox: checkbox)
            checkbox.target = bridge
            checkbox.action = #selector(ClickModifierBridge.toggled)
            return bridge
        }

        let row = NSStackView(views: bridges.map { $0.checkbox })
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        // Keep the bridges alive for the row's lifetime.
        objc_setAssociatedObject(row, &Self.clickModifierBridgesAssocKey,
                                 bridges, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return row
    }

    private static var clickModifierBridgesAssocKey: UInt8 = 0

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

    /// Scrollable, multi-line text editor that mirrors `action.text`. Used
    /// for free-form natural-language fields (`.aiGen` instruction).
    private func makeMultilineTextField(_ action: AutoAction,
                                        disposeBag: DisposeBag,
                                        placeholder: String) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let textView = NSTextView()
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = (try? action.text.value()) ?? ""
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let bridge = TextViewChangeBridge { [weak action] new in
            action?.text.onNext(new)
        }
        textView.delegate = bridge
        objc_setAssociatedObject(scroll, &Self.textViewBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Lightweight placeholder via overlay label — NSTextView lacks a
        // built-in `placeholderString` (unlike NSTextField).
        let placeholderLabel = NSTextField(labelWithString: placeholder)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.isHidden = !textView.string.isEmpty
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        bridge.onChange = { [weak action, weak placeholderLabel] new in
            action?.text.onNext(new)
            placeholderLabel?.isHidden = !new.isEmpty
        }

        scroll.documentView = textView
        scroll.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 6),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
        ])
        return scroll
    }

    /// Multi-line editor for the `.aiGen` instruction only — strips and
    /// preserves the encoded `@interval=` header so editing the prose
    /// doesn't clobber the user's interval setting.
    private func makeAIGenInstructionField(_ action: AutoAction,
                                           disposeBag: DisposeBag,
                                           placeholder: String) -> NSView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let textView = NSTextView()
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = action.aiGenInstruction
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let placeholderLabel = NSTextField(labelWithString: placeholder)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.isHidden = !textView.string.isEmpty
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let bridge = TextViewChangeBridge { [weak action, weak placeholderLabel] new in
            action?.setAIGenInstruction(new)
            placeholderLabel?.isHidden = !new.isEmpty
        }
        textView.delegate = bridge
        objc_setAssociatedObject(scroll, &Self.textViewBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        scroll.documentView = textView
        scroll.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 6),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
        ])
        return scroll
    }

    /// Single-line text field for the `.aiGen` end condition. Empty value
    /// switches the runner into one-shot mode (no loop); non-empty value
    /// is forwarded to the server each turn so the model can decide when
    /// to set `finish: true`. Writes via `setAIGenEndCondition` so the
    /// encoded header is updated without touching the instruction body.
    private func makeAIGenEndConditionField(_ action: AutoAction,
                                            disposeBag: DisposeBag,
                                            placeholder: String) -> NSView {
        let field = NSTextField(string: action.aiGenEndCondition)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            action?.setAIGenEndCondition(new)
        }
        return field
    }

    /// Numeric field for the `.aiGen` inter-iteration interval (seconds).
    /// Mirrors the layout of `makeDelayField`. Writes via
    /// `setAIGenInterval` so the encoded header is updated without
    /// touching the instruction body.
    private func makeAIGenIntervalField(_ action: AutoAction,
                                        disposeBag: DisposeBag) -> NSView {
        let field = NSTextField(string: String(format: "%g", action.aiGenInterval))
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            guard let action = action else { return }
            let v = Double(new) ?? AIGenPayload.defaultInterval
            action.setAIGenInterval(v)
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

    private static var textViewBridgeAssocKey: UInt8 = 0

    /// Initialize a `.openBrowser` action's `text` so subsequent UI bindings
    /// have something concrete to render. Pre-fills the URL slot from the
    /// enum payload (if the user hasn't edited yet) and seeds a default
    /// 1024×768 window frame so the position-picker preview has a size to
    /// draw before any explicit user input.
    private func seedBrowserDefaults(_ action: AutoAction) {
        let raw = (try? action.text.value()) ?? ""
        let parsed = OpenBrowserPayload.parse(raw)
        let url: String
        if parsed.url.isEmpty, let seed = action.type.defaultURL, !seed.isEmpty {
            url = seed
        } else {
            url = parsed.url
        }
        let frame: String
        if parsed.frame.isEmpty {
            frame = WindowFrameUtil.encode(CGRect(x: 0, y: 0, width: 1024, height: 768))
        } else {
            frame = parsed.frame
        }
        let seeded = OpenBrowserPayload.encode(url: url, frame: frame)
        if seeded != raw { action.text.onNext(seeded) }
    }

    /// Slider + number field pair for one axis of the `.openBrowser` window
    /// size. Mirrors the OCR scan-area control's layout but writes into the
    /// frame's width or height (200…3000 px). Updating the axis preserves the
    /// other axis, the origin, and the URL.
    private func makeBrowserSizeControl(_ action: AutoAction,
                                        axis: BrowserSizeAxis,
                                        disposeBag: DisposeBag) -> NSView {
        let initial = axis == .width ? Int(action.browserFrame.width)
                                     : Int(action.browserFrame.height)
        let displayInitial = max(200, min(3000, initial == 0
                                          ? (axis == .width ? 1024 : 768)
                                          : initial))

        let slider = NSSlider(value: Double(displayInitial),
                              minValue: 200,
                              maxValue: 3000,
                              target: nil,
                              action: nil)
        slider.numberOfTickMarks = (3000 - 200) / 50 + 1
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let field = NSTextField(string: "\(displayInitial)")
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let unit = NSTextField(labelWithString: "px")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .tertiaryLabelColor

        let state = BrowserSizeState(action: action, axis: axis, slider: slider, field: field)
        slider.target = state
        slider.action = #selector(BrowserSizeState.sliderChanged)
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak state] _ in
            state?.fieldChanged()
        }
        objc_setAssociatedObject(field, &Self.browserSizeStateAssocKey,
                                 state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [slider, field, unit])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static var browserSizeStateAssocKey: UInt8 = 0

    /// Position picker for `.openBrowser`. Pressing the button shows the
    /// floating `ScanPreviewPanel` sized to the action's current width×height,
    /// follows the cursor, then on click stores the frame whose CENTER is
    /// the click point (cursor is at the center of the visual rect, matching
    /// the OCR position picker).
    private func makeBrowserPositionPicker(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
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
            .subscribe(onNext: { [weak action] _ in
                guard let action = action else { return }
                let f = action.browserFrame
                if f == .zero || (f.width == 0 && f.height == 0) {
                    display.stringValue = "  " + L("(Not set)")
                } else {
                    display.stringValue = "  중심 (\(Int(f.midX)), \(Int(f.midY)))"
                }
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: L("📍 Pick Location"), target: self,
                                  action: #selector(pickBrowserPosition(_:)))
        pickButton.bezelStyle = .roundRect
        pickButton.controlSize = .small
        objc_setAssociatedObject(pickButton, &Self.actionAssocKey,
                                 action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [display, pickButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func pickBrowserPosition(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        let cur = action.browserFrame
        let size = CGSize(width: max(50, cur.width == 0 ? 1024 : cur.width),
                          height: max(50, cur.height == 0 ? 768 : cur.height))

        Self.armPickerVisuals(button: sender, display: nil, active: true, pushCursor: false)
        ScanPreviewPanel.shared.show(rectSize: size)

        let captureSession = PickerCaptureSession(size: size)
        captureSession.start()

        let esc = EscCancelMonitor()
        let teardown: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: nil, active: false, pushCursor: false)
            DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
        }
        esc.onCancel = {
            _ = captureSession.stop()
            teardown()
            AppLogger.shared.log("⎋ 위치 선택 취소")
        }

        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { (point, _) in
            esc.stop()
            if let img = captureSession.stop() {
                OCRSnapshotStore.shared.save(img, actionId: action.id)
            }
            teardown()

            // `point` is in Quartz screen coords (Y-down) — same coord
            // system AX uses for window position, so the saved origin maps
            // directly when the runner applies the frame.
            let origin = CGPoint(x: point.x - size.width / 2,
                                 y: point.y - size.height / 2)
            let newFrame = CGRect(origin: origin, size: size)
            action.setBrowserFrame(newFrame)
            AppLogger.shared.log("🪟 위치 선택: \(WindowFrameUtil.encode(newFrame))")
        }
        mouseListener.start()
        esc.start()
    }

    /// URL field for `.openBrowser` — reads/writes only the URL half of the
    /// pipe-delimited `<url>|<frame>` payload so the frame slot survives
    /// edits.
    private func makeBrowserURLField(_ action: AutoAction, disposeBag: DisposeBag, placeholder: String) -> NSView {
        let raw = (try? action.text.value()) ?? ""
        let initial = OpenBrowserPayload.parse(raw).url
        let field = NSTextField(string: initial)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = TextFieldChangeDelegate.attach(to: field) { [weak action] new in
            guard let action = action else { return }
            let cur = OpenBrowserPayload.parse((try? action.text.value()) ?? "")
            action.text.onNext(OpenBrowserPayload.encode(url: new, frame: cur.frame))
        }
        return field
    }

    /// Unified wait card — single popup at the top picks between the three
    /// wait modes (time / click / enter) and the row below reactively swaps
    /// to whichever editor that mode needs (or a hint label when the mode
    /// has no extra config). Default mode is `.time`, which is what the
    /// picker menu seeds for new wait actions.
    private func makeWaitCard(_ action: AutoAction, disposeBag: DisposeBag) -> CardView {
        let card = makeCard(title: L("Wait"))

        // Ordered list of all sub-types — segment / popup index → enum.
        let waitTypes: [AutoAction.WaitType] = [.time, .click, .enter]
        let labels = [L("Wait Time"), L("Wait Click"), L("Wait Enter")]
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: labels)
        let currentWait: AutoAction.WaitType
        if case .wait(let wt) = action.type { currentWait = wt } else { currentWait = .time }
        popup.selectItem(at: waitTypes.firstIndex(of: currentWait) ?? 0)
        popup.translatesAutoresizingMaskIntoConstraints = false

        // Container that holds the option view for the currently-selected
        // wait type. Rebuilt in `rebuildOption` whenever the popup changes.
        let optionContainer = NSView()
        optionContainer.translatesAutoresizingMaskIntoConstraints = false

        let rebuildOption: () -> Void = { [weak self, weak action, weak optionContainer] in
            guard let self = self,
                  let action = action,
                  let container = optionContainer else { return }
            for v in container.subviews { v.removeFromSuperview() }

            let inner: NSView
            switch action.type {
            case .wait(.time):
                inner = self.makeWaitTimeControl(action, disposeBag: disposeBag)
            default:
                let label = NSTextField(labelWithString: self.waitDescription(action.type))
                label.textColor = .secondaryLabelColor
                inner = label
            }
            inner.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                inner.topAnchor.constraint(equalTo: container.topAnchor),
                inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        rebuildOption()

        let bridge = WaitTypeBridge(action: action,
                                    waitTypes: waitTypes,
                                    onChange: rebuildOption)
        popup.target = bridge
        popup.action = #selector(WaitTypeBridge.changed(_:))
        objc_setAssociatedObject(popup, &Self.waitTypeBridgeAssocKey,
                                 bridge, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        card.addRow(label: L("Type"), control: popup,
                    hint: "기본값은 시간 대기")
        card.addRow(label: L("Options"), control: optionContainer)
        return card
    }

    private static var waitTypeBridgeAssocKey: UInt8 = 0

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
    /// committed a position-pick (OCR / click / browser / window-frame).
    /// Loads from `OCRSnapshotStore` and auto-refreshes via the
    /// `.ocrSnapshotChanged` notification — the store name predates the
    /// generalisation but the file format is action-id-keyed PNG, agnostic
    /// to action type.
    private func makeActionSnapshotView(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        imageView.layer?.cornerRadius = 6
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let placeholder = NSTextField(labelWithString: L("(Not captured yet)"))
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

    /// Button that launches a macOS-Screenshot-style drag-to-select overlay
    /// for the OCR action. The drag rectangle sets both `action.point`
    /// (center of the rect, in Quartz coords) and the packed width/height in
    /// `action.count` in a single gesture.
    private func makeOCRAreaPicker(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let dragButton = NSButton(title: L("🔲 Drag to Select Area"),
                                  target: self,
                                  action: #selector(pickOCRArea(_:)))
        dragButton.bezelStyle = .roundRect
        dragButton.controlSize = .small
        objc_setAssociatedObject(dragButton, &Self.actionAssocKey,
                                 action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [dragButton, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
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
                display.stringValue = (p == .zero ? "  " + L("(Not set)") : "  \(Int(p.x)), \(Int(p.y))")
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: L("📍 Pick Position"), target: self,
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

    /// Drag recorder UI: live summary of the recorded path + a single
    /// "🎯 드래그 녹화" button. Pressing the button starts a `MouseDragRecorder`
    /// that captures the user's real mouseDown → drag → mouseUp gesture
    /// system-wide and stores it as `action.point` (start) + the
    /// distance-sampled waypoint list in `action.text` (intermediate points
    /// + final release point).
    private func makeDragRecorder(_ action: AutoAction, disposeBag: DisposeBag) -> NSView {
        let summary = NSTextField(labelWithString: "")
        summary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.wantsLayer = true
        summary.layer?.borderWidth = 1
        summary.layer?.borderColor = NSColor.separatorColor.cgColor
        summary.layer?.cornerRadius = 6
        summary.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        summary.cell?.lineBreakMode = .byTruncatingTail
        summary.translatesAutoresizingMaskIntoConstraints = false
        summary.heightAnchor.constraint(equalToConstant: 22).isActive = true
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refresh: () -> Void = { [weak action] in
            guard let action = action else { return }
            let start = (try? action.point.value()) ?? .zero
            let waypoints = action.dragWaypoints
            if start == .zero && waypoints.isEmpty {
                summary.stringValue = "  " + L("(Not recorded)")
                return
            }
            let endStr: String
            if let end = waypoints.last {
                endStr = "(\(Int(end.x)), \(Int(end.y)))"
            } else {
                endStr = "(없음)"
            }
            let inner = max(0, waypoints.count - 1)
            summary.stringValue = "  시작 (\(Int(start.x)), \(Int(start.y)))  →  경로점 \(inner)개  →  끝 \(endStr)"
        }
        // The point and text subjects together fully describe the path —
        // rebuild whenever either changes.
        action.point
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { _ in refresh() })
            .disposed(by: disposeBag)
        action.text
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { _ in refresh() })
            .disposed(by: disposeBag)

        let recordButton = NSButton(title: L("🎯 Record Drag"),
                                    target: self,
                                    action: #selector(recordDrag(_:)))
        recordButton.bezelStyle = .roundRect
        recordButton.controlSize = .small
        recordButton.toolTip = "버튼을 누른 뒤 실제로 마우스를 드래그하세요. 클릭→드래그→떼기 한 번이 그대로 기록됩니다."
        objc_setAssociatedObject(recordButton, &Self.actionAssocKey,
                                 action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let row = NSStackView(views: [summary, recordButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func recordDrag(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey)
                as? AutoAction else { return }
        // If a previous recorder is somehow still attached (re-click before
        // onEnd cleared it), drop it now — its deinit will tear down the
        // tap before we install a fresh one.
        objc_setAssociatedObject(sender, &Self.dragRecorderAssocKey,
                                 nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        Self.armPickerVisuals(button: sender, display: nil, active: true, pushCursor: false)
        ScanPreviewPanel.shared.show(rectSize: CGSize(width: 40, height: 40))

        var samples: [DragWaypoint] = []
        var startPoint: CGPoint = .zero
        let recorder = MouseDragRecorder()
        // Anchor the recorder to the button so it survives past this
        // function's stack frame — the CGEventTap callback uses an
        // unretained pointer, so without this strong reference the first
        // mouseDown after `recordDrag` returns would access a freed object
        // (EXC_BAD_ACCESS).
        objc_setAssociatedObject(sender, &Self.dragRecorderAssocKey,
                                 recorder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let esc = EscCancelMonitor()
        let teardown: () -> Void = { [weak sender] in
            if let sender = sender {
                Self.armPickerVisuals(button: sender, display: nil, active: false, pushCursor: false)
                // Release the recorder anchor so the tap is torn down by
                // its deinit and we don't leak the run-loop source.
                objc_setAssociatedObject(sender, &Self.dragRecorderAssocKey,
                                         nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
        }
        esc.onCancel = { [weak recorder] in
            recorder?.stop()
            teardown()
            AppLogger.shared.log("⎋ 드래그 녹화 취소")
        }

        recorder.onStart = { [weak action] point in
            startPoint = point
            action?.point.onNext(point)
            samples.removeAll()
            AppLogger.shared.log("✋ 드래그 녹화 시작: (\(Int(point.x)), \(Int(point.y)))")
        }
        recorder.onSample = { point, tMs in
            samples.append(DragWaypoint(point: point, tMs: tMs))
        }
        recorder.onEnd = { [weak action] point, tMs in
            esc.stop()
            samples.append(DragWaypoint(point: point, tMs: tMs))
            action?.setDragWaypointsTimed(samples)
            // One-shot screenshot of the area covering start + waypoints,
            // overlaid with start/end markers. Replaces the start-point-only
            // live capture so long drags show both endpoints in context.
            if let id = action?.id,
               let img = ActionDetailBuilder.makeDragSnapshot(start: startPoint,
                                                              waypoints: samples.map { $0.point }) {
                OCRSnapshotStore.shared.save(img, actionId: id)
            }
            teardown()
            AppLogger.shared.log("✋ 드래그 녹화 완료: 경로점 \(samples.count)개, \(tMs)ms (끝 \(Int(point.x)), \(Int(point.y)))")
        }
        recorder.start()
        esc.start()
    }

    private static var dragRecorderAssocKey: UInt8 = 0

    /// Take a one-shot screenshot of the smallest rect that contains the
    /// drag's start and every waypoint (with padding + minimum size), then
    /// overlay a green start marker, a red end marker, and a yellow polyline
    /// connecting the path. Coords throughout are global Quartz (Y-down,
    /// origin top-left of the primary display) — same as what the recorder
    /// captures from CGEventTap.
    static func makeDragSnapshot(start: CGPoint, waypoints: [CGPoint]) -> NSImage? {
        let allPoints = [start] + waypoints
        guard let minX = allPoints.map(\.x).min(),
              let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(),
              let maxY = allPoints.map(\.y).max() else { return nil }

        let padding: CGFloat = 60
        let minSize: CGFloat = 200
        let w = max(minSize, maxX - minX + padding * 2)
        let h = max(minSize, maxY - minY + padding * 2)
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        let captureRect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

        // CGWindowListCreateImage is deprecated in macOS 14 but still
        // functional and matches the app's macOS 12 deployment target. It
        // returns nil if Screen Recording permission isn't granted — caller
        // silently skips saving the snapshot in that case.
        guard let cg = CGWindowListCreateImage(captureRect,
                                               .optionOnScreenOnly,
                                               kCGNullWindowID,
                                               .nominalResolution) else {
            return nil
        }

        let imageSize = NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        let base = NSImage(cgImage: cg, size: imageSize)

        // Quartz (Y-down) → image-local (Y-up). The drawing context inside
        // lockFocus is Y-up by default.
        func toImage(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x - captureRect.minX,
                    y: imageSize.height - (p.y - captureRect.minY))
        }

        let composite = NSImage(size: imageSize)
        composite.lockFocus()
        defer { composite.unlockFocus() }

        base.draw(in: CGRect(origin: .zero, size: imageSize))

        // Path polyline (yellow translucent stroke).
        if !waypoints.isEmpty {
            let path = NSBezierPath()
            path.move(to: toImage(start))
            for wp in waypoints {
                path.line(to: toImage(wp))
            }
            NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        // Start marker (green dot + white outline).
        drawMarker(at: toImage(start), color: .systemGreen)

        // End marker (red dot + white outline) — last waypoint only.
        if let endPt = waypoints.last {
            drawMarker(at: toImage(endPt), color: .systemRed)
        }

        return composite
    }

    /// Filled circle with a white outline ring — used by `makeDragSnapshot`
    /// to mark the drag endpoints. Caller is responsible for being inside
    /// an active `lockFocus()` context.
    private static func drawMarker(at point: CGPoint, color: NSColor) {
        let r: CGFloat = 10
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.setStroke()
        let outline = NSBezierPath(ovalIn: rect)
        outline.lineWidth = 2
        outline.stroke()
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

        // Re-render whenever the underlying text changes — `encodedFrame`
        // hides whether the action stores frame directly (`text`) or in the
        // pipe-delimited `.openBrowser` payload.
        action.text
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak action] _ in
                let s = action?.encodedFrame ?? ""
                display.stringValue = s.isEmpty ? "  " + L("(Not set)") : "  \(s)"
            })
            .disposed(by: disposeBag)

        let pickButton = NSButton(title: L("📍 Pick Window"), target: self,
                                  action: #selector(pickWindow(_:)))
        pickButton.bezelStyle = .roundRect
        pickButton.controlSize = .small
        pickButton.toolTip = "버튼을 누르고 기준 윈도우를 클릭하면 그 위치/크기를 저장"
        objc_setAssociatedObject(pickButton, &Self.actionAssocKey, action, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let restore = NSButton(title: L("🪟 Restore"), target: self, action: #selector(restoreWindow(_:)))
        restore.bezelStyle = .roundRect
        restore.controlSize = .small
        restore.contentTintColor = .controlAccentColor
        restore.toolTip = "저장된 좌표 위치의 윈도우에 프레임을 즉시 적용 (테스트용)"
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

    @objc private func pickOCRArea(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey)
                as? AutoAction else { return }
        // No floating preview panel or cursor push here — the full-screen
        // overlay handles its own cursor and dimming.
        Self.armPickerVisuals(button: sender, display: nil,
                              active: true, pushCursor: false)

        let controller = AreaSelectionController()
        // Anchor to the button so the controller survives until the user
        // commits or cancels. Cleared in `onFinish` below.
        objc_setAssociatedObject(sender, &Self.areaSelectorAssocKey,
                                 controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        // Backup ESC handler in case the overlay panel hasn't become key
        // (e.g. another app holds focus on a fullscreen display).
        let esc = EscCancelMonitor()
        esc.onCancel = { [weak controller] in controller?.cancel() }

        controller.onFinish = { [weak sender, weak action] quartzRect in
            esc.stop()
            // Always reset the button visuals and drop the anchor first so a
            // cancelled gesture doesn't leave the UI in the "armed" state.
            if let sender = sender {
                Self.armPickerVisuals(button: sender, display: nil,
                                      active: false, pushCursor: false)
                objc_setAssociatedObject(sender, &Self.areaSelectorAssocKey,
                                         nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            guard let action = action, let rect = quartzRect else {
                AppLogger.shared.log("⎋ OCR 영역 선택 취소")
                return
            }
            // Snap dimensions to 25 px to match the slider grid; clamp to the
            // 50…600 range so the stored size remains valid for both the UI
            // and the runtime.
            let snap: (CGFloat) -> Int = { Int(round($0 / 25.0)) * 25 }
            let w = max(50, min(600, snap(rect.width)))
            let h = max(50, min(600, snap(rect.height)))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            action.point.onNext(center)
            action.setOCRScanSize(width: w, height: h)

            // Capture a snapshot of the final selected area (matching the
            // pattern in `makeDragSnapshot`). CGWindowListCreateImage is
            // deprecated but still works for one-shot grabs on the supported
            // macOS 12 baseline. Run on the next runloop tick so the
            // overlays have actually been torn down before we capture —
            // otherwise the dim layer ends up in the screenshot.
            let snapRect = CGRect(x: center.x - CGFloat(w) / 2,
                                  y: center.y - CGFloat(h) / 2,
                                  width: CGFloat(w), height: CGFloat(h))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let cg = CGWindowListCreateImage(
                    snapRect, .optionOnScreenOnly,
                    kCGNullWindowID, .nominalResolution) {
                    let img = NSImage(cgImage: cg,
                                      size: NSSize(width: cg.width, height: cg.height))
                    OCRSnapshotStore.shared.save(img, actionId: action.id)
                }
            }
            AppLogger.shared.log("🔲 OCR 영역 선택: 중심 (\(Int(center.x)), \(Int(center.y))) 크기 \(w)×\(h)")
        }
        controller.start()
        esc.start()
    }

    private static var areaSelectorAssocKey: UInt8 = 0

    @objc private func pickPoint(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        let display = objc_getAssociatedObject(sender, &Self.displayAssocKey) as? NSTextField
        Self.armPickerVisuals(button: sender, display: display, active: true, pushCursor: false)

        // Small floating box centered on the cursor — same overlay style as
        // the OCR area picker, just sized down. Marks where the click will
        // be recorded without replacing the system cursor.
        let pointPickerSize: CGFloat = 40
        ScanPreviewPanel.shared.show(rectSize: CGSize(width: pointPickerSize,
                                                      height: pointPickerSize))

        // Larger reference snapshot (independent of the small visual overlay)
        // so the action's detail pane has a useful screenshot to display.
        let captureSession = PickerCaptureSession(
            size: CGSize(width: 200, height: 200))
        captureSession.start()

        let esc = EscCancelMonitor()
        let teardown: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: display, active: false, pushCursor: false)
            DispatchQueue.main.async { ScanPreviewPanel.shared.hide() }
        }
        esc.onCancel = {
            _ = captureSession.stop()
            teardown()
            AppLogger.shared.log("⎋ 좌표 선택 취소")
        }

        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { (point, _) in
            esc.stop()
            action.point.onNext(point)
            if let img = captureSession.stop() {
                OCRSnapshotStore.shared.save(img, actionId: action.id)
            }
            teardown()
        }
        mouseListener.start()
        esc.start()
    }

    @objc private func pickWindow(_ sender: NSButton) {
        guard let action = objc_getAssociatedObject(sender, &Self.actionAssocKey) as? AutoAction else { return }
        Self.armPickerVisuals(button: sender, display: nil, active: true)

        let captureSession = PickerCaptureSession(
            size: CGSize(width: 200, height: 200))
        captureSession.start()

        let esc = EscCancelMonitor()
        let teardown: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.mouseListener.stop()
            self.mouseListener.consumesAllClicks = false
            Self.armPickerVisuals(button: sender, display: nil, active: false)
        }
        esc.onCancel = {
            _ = captureSession.stop()
            teardown()
            AppLogger.shared.log("⎋ 윈도우 선택 취소")
        }

        mouseListener.consumesAllClicks = true
        mouseListener.onMouseDown = { (point, _) in
            esc.stop()
            if let img = captureSession.stop() {
                OCRSnapshotStore.shared.save(img, actionId: action.id)
            }
            teardown()
            if let frame = WindowFrameUtil.windowFrame(at: point) {
                let encoded = WindowFrameUtil.encode(frame)
                action.setEncodedFrame(encoded)
                AppLogger.shared.log("🪟 윈도우 선택: \(encoded)")
            } else {
                AppLogger.shared.log("⚠️ 해당 위치에서 윈도우를 찾지 못했습니다")
            }
        }
        mouseListener.start()
        esc.start()
    }

    /// Toggle the recording-state visuals on a position-pick button + its
    /// optional coordinate display. Active = red bezel + red border on the
    /// display; inactive = system defaults. When `pushCursor` is true (the
    /// default for pickers without their own floating preview), pushes/pops
    /// a custom crosshair cursor for click feedback. Pickers that show their
    /// own overlay (`pickPoint`, `pickOCRArea`, `pickBrowserPosition`)
    /// pass `pushCursor: false` so the system cursor stays visible and the
    /// box marks the target location instead.
    private static func armPickerVisuals(button: NSButton,
                                         display: NSTextField?,
                                         active: Bool,
                                         pushCursor: Bool = true) {
        if active {
            button.bezelColor = .systemRed
            button.contentTintColor = .white
            display?.layer?.borderColor = NSColor.systemRed.cgColor
            display?.layer?.borderWidth = 2
            if pushCursor { pickerCursor.push() }
            setMainWindowHidden(true, anchor: button)
        } else {
            button.bezelColor = nil
            button.contentTintColor = nil
            display?.layer?.borderColor = NSColor.separatorColor.cgColor
            display?.layer?.borderWidth = 1
            if pushCursor { NSCursor.pop() }
            setMainWindowHidden(false, anchor: button)
        }
    }

    /// Hides every main window while a picker/recorder session is active
    /// so they don't obscure the area the user is about to click or drag —
    /// and so the picker's snapshot doesn't capture our own chrome.
    /// Reference-counted so concurrent picker sessions (if any) still
    /// restore correctly on the last `active: false` call.
    ///
    /// All Runner windows are hidden, not just the anchor's: with native
    /// window tabbing each tab is its own `NSWindow`, so `orderOut` on one
    /// would leave the sibling tabs visible.
    private static var activePickerSessions = 0
    private static var hiddenPickerWindows: [NSWindow] = []

    static func setMainWindowHidden(_ hidden: Bool, anchor: NSView) {
        if hidden {
            activePickerSessions += 1
            guard activePickerSessions == 1 else { return }
            var toHide: [NSWindow] = WindowRegistry.shared.windows.compactMap { wc in
                guard let w = wc.window, w.isVisible else { return nil }
                return w
            }
            if toHide.isEmpty,
               let w = anchor.window ?? NSApp.windows.first(where: { $0.contentViewController is ViewController }),
               w.isVisible {
                toHide = [w]
            }
            guard !toHide.isEmpty else { return }
            hiddenPickerWindows = toHide
            for w in toHide { w.orderOut(nil) }
            // orderOut alone keeps us frontmost — the previous app won't
            // regain focus until we explicitly step aside. `NSApp.deactivate()`
            // is unreliable while our floating picker panels
            // (ScanPreviewPanel, OCRDebugWindow) are visible, so we instead
            // activate the prior frontmost app directly. Those panels are
            // `.nonactivatingPanel` at .floating+ level so they remain
            // visible after the activation handoff.
            if let prev = PreviousAppTracker.shared.previousApp, !prev.isTerminated {
                prev.activate(options: [])
            } else {
                NSApp.deactivate()
            }
        } else {
            guard activePickerSessions > 0 else { return }
            activePickerSessions -= 1
            guard activePickerSessions == 0 else { return }
            let toRestore = hiddenPickerWindows
            hiddenPickerWindows = []
            guard !toRestore.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            for w in toRestore { w.makeKeyAndOrderFront(nil) }
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
        let s = action.encodedFrame
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
    ///
    /// Every label/control row has the same `[label, control]` shape so the
    /// row's intrinsic height is determined solely by the control. The
    /// optional hint becomes its own sibling row indented to align under
    /// the control — this keeps inter-row spacing identical whether or
    /// not a row has a hint. A previous design wrapped control + hint in
    /// a vertical sub-stack, which made the row's intrinsic height vary
    /// with hint presence and produced intermittent layout glitches as
    /// NSStackView's measurement raced with constraint resolution.
    func addRow(labelView: NSView, control: NSView, hint: String? = nil) {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                   constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true

        guard let hint = hint, !hint.isEmpty else { return }
        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        // Pulls the hint up under the control by overlapping the previous
        // row's bottom inset (10pt) — the result is ~4pt visual gap between
        // control and hint, matching the previous nested-stack spacing.
        let hintRow = NSStackView(views: [hintLabel])
        hintRow.orientation = .horizontal
        hintRow.edgeInsets = NSEdgeInsets(top: -6, left: 114, bottom: 4, right: 0)
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hintRow)
        hintRow.widthAnchor.constraint(equalTo: stack.widthAnchor,
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
        case .drag:         names = ["hand.draw", "arrow.up.and.down.and.arrow.left.and.right", "arrow.right"]
        case .key:          names = ["keyboard", "command"]
        case .wait(.click): names = ["hand.tap", "hand.tap.fill", "hourglass"]
        case .wait(.enter): names = ["hourglass.bottomhalf.filled", "hourglass"]
        case .wait(.time):  names = ["clock", "alarm"]
        case .ocr:          names = ["text.viewfinder"]
        case .script:       names = ["curlybraces", "chevron.left.forwardslash.chevron.right"]
        case .setURL:       names = ["globe"]
        case .openChrome:   names = ["plus.rectangle.on.rectangle", "rectangle.on.rectangle"]
        case .openBrowser:  names = ["safari", "globe", "macwindow"]
        case .windowFrame:  names = ["macwindow", "rectangle"]
        case .nextScenario: names = ["arrow.right.circle", "chevron.right.2", "arrow.right"]
        case .aiGen:        names = ["sparkles", "wand.and.stars", "brain"]
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
        case .drag:                 return "✋"
        case .key:                  return "⌨︎"
        case .wait(.click):         return "⏳"
        case .wait(.enter):         return "⏎⏳"
        case .wait(.time):          return "⏱"
        case .ocr:                  return "🔍"
        case .script:               return "📝"
        case .setURL:               return "🌐"
        case .openChrome:           return "🆕"
        case .openBrowser:          return "🌐🪟"
        case .windowFrame:          return "🪟"
        case .nextScenario:         return "➡️"
        case .aiGen:                return "🤖"
        }
    }

    static func label(for type: AutoAction.ActionType) -> String {
        switch type {
        case .click:                return L("Click")
        case .scroll:               return L("Scroll")
        case .drag:                 return L("Drag")
        case .key:                  return L("Key")
        case .wait(.click):         return L("Wait Click")
        case .wait(.enter):         return L("Wait Enter")
        case .wait(.time):          return L("Wait Time")
        case .ocr:                  return L("OCR Click")
        case .script:               return L("Run Script")
        case .setURL:               return L("URL Settings")
        case .openChrome:           return L("New Chrome Window")
        case .openBrowser:          return L("Browser")
        case .windowFrame:          return L("Window Frame")
        case .nextScenario:         return L("Go to Flow")
        case .aiGen:                return L("AI Generate")
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
        case .openBrowser(let url): return url
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

enum BrowserSizeAxis { case width, height }

/// Lightweight ESC-key watcher for picker / recorder sessions. Fires
/// `onCancel` once when the user presses ESC anywhere on the system —
/// or inside the app — then auto-stops. Caller MUST also invalidate via
/// `stop()` on the success path so the monitors are torn down whether
/// the session commits or cancels. Global keyDown monitoring piggybacks
/// on the Accessibility permission this app already holds for its
/// CGEventTap listeners, so no extra prompt is needed.
private final class EscCancelMonitor {
    var onCancel: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fired = false

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }   // kVK_Escape
            self?.fire()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.fire()
            return nil
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        stop()
        let cb = onCancel
        onCancel = nil
        DispatchQueue.main.async { cb?() }
    }
}

/// Live screen capture that follows the cursor for the duration of a
/// position-pick session. Used by non-OCR pickers (`pickPoint`,
/// `pickBrowserPosition`, `pickWindow`) to record a snapshot of the click
/// area and persist it via `OCRSnapshotStore` so the action's detail pane
/// can render a reference thumbnail. Mirrors the cursor-tracking + display-
/// crossing logic already used by the OCR picker.
private final class PickerCaptureSession {
    private let capturer = ScreenCapturer()
    private let size: CGSize
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDisplayID: CGDirectDisplayID?
    private(set) var lastImage: NSImage?

    init(size: CGSize) { self.size = size }

    func start() {
        let pt = NSEvent.mouseLocation
        capturer.showsCursor = true
        capturer.handler = { [weak self] img in
            if let img = img { self?.lastImage = img }
        }
        capturer.start(rect: rect(at: pt))
        lastDisplayID = displayID(at: pt)

        let updateForMove: () -> Void = { [weak self] in
            guard let self = self else { return }
            let pt = NSEvent.mouseLocation
            let r = self.rect(at: pt)
            let id = self.displayID(at: pt)
            if let id = id, id != self.lastDisplayID {
                self.capturer.stop()
                // stop() clears the handler, so re-attach.
                self.capturer.handler = { [weak self] img in
                    if let img = img { self?.lastImage = img }
                }
                self.capturer.showsCursor = true
                self.capturer.start(rect: r)
                self.lastDisplayID = id
            } else {
                self.capturer.updateCaptureRect(r)
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            DispatchQueue.main.async { updateForMove() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            updateForMove()
            return event
        }
    }

    @discardableResult
    func stop() -> NSImage? {
        capturer.stop()
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        return lastImage
    }

    private func rect(at pt: CGPoint) -> CGRect {
        let hw = size.width / 2
        let hh = size.height / 2
        return CGRect(x: pt.x - hw, y: pt.y - hh,
                      width: size.width, height: size.height)
    }

    private func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { $0.frame.contains(point) }?
            .deviceDescription[key] as? CGDirectDisplayID
    }
}

// MARK: - Drag-to-select-area (macOS Screenshot-style)

/// Covers every NSScreen with a borderless, non-activating panel so the user
/// can drag a rectangle that defines both the OCR scan position and size in
/// one gesture. Mouse-down on any panel starts the selection; subsequent
/// drags (even across displays) are routed back to the starting panel by
/// AppKit, so the controller only needs to convert events from that panel's
/// local space into global NSScreen coordinates. On mouseUp, the final rect
/// is converted to Quartz coords (Y-down) and handed back via `onFinish` —
/// nil means cancelled (ESC or zero-size click).
private final class AreaSelectionController: NSObject {
    private var panels: [AreaSelectionPanel] = []
    private var dragStartGlobalNS: CGPoint?
    private var globalSelectionNS: CGRect = .zero
    var onFinish: ((CGRect?) -> Void)?  // Quartz rect, or nil = cancelled

    /// Minimum dimension (in points) for the drag to count as a real
    /// selection — anything smaller is treated as a click and cancels.
    private let minDragSize: CGFloat = 5

    func start() {
        for screen in NSScreen.screens {
            let panel = AreaSelectionPanel(screen: screen)
            let view = AreaSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenOriginGlobalNS = screen.frame.origin
            view.onMouseDown = { [weak self] localPt in
                guard let self = self else { return }
                let global = CGPoint(x: localPt.x + screen.frame.origin.x,
                                     y: localPt.y + screen.frame.origin.y)
                self.dragStartGlobalNS = global
                self.globalSelectionNS = CGRect(origin: global, size: .zero)
                self.broadcast()
            }
            view.onMouseDragged = { [weak self] localPt in
                guard let self = self, let start = self.dragStartGlobalNS else { return }
                let global = CGPoint(x: localPt.x + screen.frame.origin.x,
                                     y: localPt.y + screen.frame.origin.y)
                self.globalSelectionNS = CGRect(
                    x: min(start.x, global.x),
                    y: min(start.y, global.y),
                    width: abs(global.x - start.x),
                    height: abs(global.y - start.y))
                self.broadcast()
            }
            view.onMouseUp = { [weak self] _ in self?.commit(cancelled: false) }
            view.onCancel  = { [weak self]    in self?.commit(cancelled: true) }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
        // Make one of the panels key so ESC and the initial click reach a
        // first responder without requiring the user to click twice.
        panels.first?.makeKey()
    }

    /// External cancel — e.g. from an `EscCancelMonitor` set up by the
    /// caller so ESC still works when the overlay panel hasn't become key
    /// (which can happen on multi-display setups before the first click).
    func cancel() { commit(cancelled: true) }

    private func broadcast() {
        for p in panels {
            (p.contentView as? AreaSelectionView)?.setGlobalSelectionNS(globalSelectionNS)
        }
    }

    private func tearDownPanels() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
    }

    private func commit(cancelled: Bool) {
        let result: CGRect?
        if cancelled
            || globalSelectionNS.width < minDragSize
            || globalSelectionNS.height < minDragSize {
            result = nil
        } else {
            // NSScreen (Y-up, origin at bottom-left of primary) →
            // Quartz (Y-down, origin at top-left of primary).
            let primaryH = NSScreen.main?.frame.height ?? globalSelectionNS.maxY
            result = CGRect(x: globalSelectionNS.minX,
                            y: primaryH - globalSelectionNS.maxY,
                            width: globalSelectionNS.width,
                            height: globalSelectionNS.height)
        }
        tearDownPanels()
        let cb = onFinish
        onFinish = nil
        cb?(result)
    }
}

/// Borderless `.nonactivatingPanel` filling a single NSScreen. Sits above
/// every other window so the dimmed overlay + rubber-band rectangle are
/// rendered on top of the user's desktop. The panel must be able to become
/// key so it receives ESC and mouse events without activating the app.
private final class AreaSelectionPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        setFrame(screen.frame, display: true)
    }
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

/// Renders the dim overlay + yellow rubber-band rectangle and forwards mouse
/// events back to the controller. Tracks the selection in global NSScreen
/// coordinates so all panels (in a multi-display setup) draw the same rect.
private final class AreaSelectionView: NSView {
    /// Origin of this view's screen in global NSScreen coords. Used to
    /// translate the controller's global selection into this view's local
    /// space when drawing.
    var screenOriginGlobalNS: CGPoint = .zero

    /// Current selection in global NSScreen coords. `.zero` ⇒ no selection
    /// yet (just dim everything).
    private var globalSelectionNS: CGRect = .zero

    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The picker arms by deactivating the app (see
    /// `armPickerVisuals` → `setMainWindowHidden`). When the overlay panel
    /// then appears it isn't key, so AppKit's default would swallow the
    /// first click as a "bring this window to the front" gesture and only
    /// deliver the *second* click as `mouseDown`. Returning true here
    /// promotes the very first click into a real `mouseDown` so the user
    /// can begin dragging without a preliminary click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setGlobalSelectionNS(_ rect: CGRect) {
        globalSelectionNS = rect
        needsDisplay = true
    }

    /// Selection translated into this view's local coords. Returns `.null`
    /// when nothing is selected so callers can skip rendering the rectangle.
    private var localSelection: CGRect {
        if globalSelectionNS == .zero { return .null }
        return globalSelectionNS.offsetBy(dx: -screenOriginGlobalNS.x,
                                          dy: -screenOriginGlobalNS.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let dimColor = NSColor(white: 0, alpha: 0.32).cgColor
        ctx.setFillColor(dimColor)

        let sel = localSelection
        if sel.isNull || sel.isEmpty {
            ctx.fill([bounds])
            return
        }

        // Dim everything except the selection (even-odd fill rule).
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(sel)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)

        // Yellow border on the selection rectangle.
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(sel)

        // Dimensions label hovering above the selection (falls back to
        // below the selection if it would clip off the top of the screen).
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        // `monospacedSystemFont` is bridged as IUO; embedding it directly in
        // an `Any` dict literal can leak `Optional.none` into the bridged
        // NSDictionary and crash `-initWithObjects:forKeys:count:`. Bind
        // through an optional first and fall back to the regular system font.
        let labelFont: NSFont =
            (NSFont.monospacedSystemFont(ofSize: 12, weight: .medium) as NSFont?)
            ?? NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let textSize = str.size()
        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let bgW = textSize.width + padX * 2
        let bgH = textSize.height + padY * 2
        var bgRect = CGRect(x: sel.minX,
                            y: sel.maxY + 4,
                            width: bgW, height: bgH)
        if bgRect.maxY > bounds.maxY {
            bgRect.origin.y = max(0, sel.minY - bgH - 4)
        }
        ctx.setFillColor(NSColor(white: 0, alpha: 0.75).cgColor)
        ctx.fill([bgRect])
        str.draw(at: NSPoint(x: bgRect.minX + padX, y: bgRect.minY + padY))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        onMouseUp?(convert(event.locationInWindow, from: nil))
    }
    override func keyDown(with event: NSEvent) {
        // kVK_Escape = 53 — matches `EscCancelMonitor`.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Popup bridge for one FlowMode-row in the `.nextScenario` card.
///
/// Menu item `representedObject` encodes the choice:
/// - `NSNull` → "Use default" (non-default modes only); writes `nil`
///   per-mode override so the runner falls back to the default mode.
/// - `""` (empty string) → "Next in list"; writes empty target for this
///   mode.
/// - scenario UUID → writes that UUID for this mode.
private final class NextScenarioPopupBridge: NSObject {
    private weak var action: AutoAction?
    private let popup: NSPopUpButton
    private let modeId: String
    private let defaultModeId: String
    private let isDefaultMode: Bool

    init(action: AutoAction,
         popup: NSPopUpButton,
         modeId: String,
         defaultModeId: String,
         isDefaultMode: Bool) {
        self.action = action
        self.popup = popup
        self.modeId = modeId
        self.defaultModeId = defaultModeId
        self.isDefaultMode = isDefaultMode
    }

    /// Rebuild the popup's items from the current `ScenarioStore` and
    /// restore selection from the action's per-mode target.
    func repopulate() {
        popup.removeAllItems()

        if !isDefaultMode {
            let useDefault = NSMenuItem(
                title: NSLocalizedString("Use default", comment: ""),
                action: nil, keyEquivalent: "")
            useDefault.representedObject = NSNull()
            popup.menu?.addItem(useDefault)
        }

        let nextInList = NSMenuItem(
            title: NSLocalizedString("Next in list", comment: ""),
            action: nil, keyEquivalent: "")
        nextInList.representedObject = ""
        popup.menu?.addItem(nextInList)

        for scenario in ScenarioStore.shared.scenarios {
            let item = NSMenuItem(title: scenario.name, action: nil, keyEquivalent: "")
            item.representedObject = scenario.id.uuidString
            popup.menu?.addItem(item)
        }

        // Resolve which item to select.
        // - Non-default modes: `nil` → "Use default"; explicit → that value.
        // - Default mode: show explicit if present, otherwise the legacy
        //   bare value (visual continuity for unmigrated actions),
        //   otherwise "Next in list" (`""`).
        let selection: Any  // String or NSNull
        if isDefaultMode {
            let p = action?.nextScenarioPayload
            if let explicit = p?.targets[modeId] {
                selection = explicit
            } else if let legacy = p?.legacyTarget {
                selection = legacy
            } else {
                selection = ""
            }
        } else if let explicit = action?.nextScenarioExplicitTarget(forModeId: modeId) {
            selection = explicit
        } else {
            selection = NSNull()
        }

        let idx = popup.menu?.items.firstIndex(where: { item in
            if selection is NSNull {
                return item.representedObject is NSNull
            }
            return (item.representedObject as? String) == (selection as? String)
        }) ?? 0
        popup.selectItem(at: idx)
    }

    @objc func changed(_ sender: NSPopUpButton) {
        let rep = sender.selectedItem?.representedObject
        let newTarget: String?
        if rep is NSNull {
            newTarget = nil
        } else {
            newTarget = (rep as? String) ?? ""
        }
        action?.setNextScenarioTarget(newTarget,
                                      forModeId: modeId,
                                      defaultModeId: defaultModeId)
    }
}

/// Popup bridge for the unified `.wait` card. Maps the selected popup
/// index back to a `WaitType`, mutates `action.type`, and notifies the
/// caller so the option row can swap in the new sub-editor.
private final class WaitTypeBridge: NSObject {
    private weak var action: AutoAction?
    private let waitTypes: [AutoAction.WaitType]
    private let onChange: () -> Void

    init(action: AutoAction,
         waitTypes: [AutoAction.WaitType],
         onChange: @escaping () -> Void) {
        self.action = action
        self.waitTypes = waitTypes
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard waitTypes.indices.contains(idx), let action = action else { return }
        action.type = .wait(type: waitTypes[idx])
        onChange()
    }
}

/// `target/action` shim for the `.scroll` direction segmented control.
/// Holds the segment-index → ScrollDirection mapping so the segmented
/// control can be reordered without rewiring the runtime semantics.
private final class ScrollDirectionBridge: NSObject {
    private weak var action: AutoAction?
    private let directions: [ScrollDirection]

    init(action: AutoAction, directions: [ScrollDirection]) {
        self.action = action
        self.directions = directions
    }

    @objc func changed(_ sender: NSSegmentedControl) {
        guard directions.indices.contains(sender.selectedSegment) else { return }
        action?.setScrollDirection(directions[sender.selectedSegment])
    }
}

/// Checkbox + delay-field shim for the `.scroll` "느린 간격" option.
/// Toggling the checkbox also enables/disables the field, since the
/// delay value is only meaningful while `slow == true`.
private final class ScrollSlowBridge: NSObject {
    private weak var action: AutoAction?
    let checkbox: NSButton
    weak var delayField: NSTextField?

    init(action: AutoAction, checkbox: NSButton, delayField: NSTextField) {
        self.action = action
        self.checkbox = checkbox
        self.delayField = delayField
    }

    @objc func toggled() {
        let on = checkbox.state == .on
        action?.setScrollSlow(on)
        delayField?.isEnabled = on
    }
}

/// `target/action` shim for the `.click` 좌/우 segmented control. Translates
/// the selected segment back into `action.text` via `setClickButton`.
private final class ClickButtonBridge: NSObject {
    private weak var action: AutoAction?
    init(action: AutoAction) { self.action = action }

    @objc func changed(_ sender: NSSegmentedControl) {
        action?.setClickButton(sender.selectedSegment == 1 ? .right : .left)
    }
}

/// `target/action` shim for one of the `.click` modifier checkboxes
/// (⌘ ⇧ ⌃ ⌥). Translates checkbox state into a single-bit update on
/// `action.clickConfig.modifiers` via `setClickModifier`.
private final class ClickModifierBridge: NSObject {
    private weak var action: AutoAction?
    let flag: NSEvent.ModifierFlags
    let checkbox: NSButton

    init(action: AutoAction, flag: NSEvent.ModifierFlags, checkbox: NSButton) {
        self.action = action
        self.flag = flag
        self.checkbox = checkbox
    }

    @objc func toggled() {
        action?.setClickModifier(flag, on: checkbox.state == .on)
    }
}

/// Slider/field bridge for one axis of the `.openBrowser` window size.
/// Keeps the slider and number field in sync, snaps to 50 px, and writes the
/// new dimension into the action's frame while preserving the other axis,
/// origin, and URL.
private final class BrowserSizeState: NSObject {
    private weak var action: AutoAction?
    private let axis: BrowserSizeAxis
    private let slider: NSSlider
    private let field: NSTextField

    init(action: AutoAction,
         axis: BrowserSizeAxis,
         slider: NSSlider,
         field: NSTextField) {
        self.action = action
        self.axis = axis
        self.slider = slider
        self.field = field
    }

    @objc func sliderChanged() {
        let v = Int(slider.doubleValue)
        field.stringValue = "\(v)"
        commit(v)
    }

    func fieldChanged() {
        let raw = Int(field.stringValue) ?? 1024
        let clamped = max(200, min(3000, raw))
        let snapped = Int(round(Double(clamped) / 50.0)) * 50
        slider.doubleValue = Double(snapped)
        if snapped != raw {
            field.stringValue = "\(snapped)"
        }
        commit(snapped)
    }

    private func commit(_ value: Int) {
        guard let action = action else { return }
        var frame = action.browserFrame
        switch axis {
        case .width:  frame.size.width = CGFloat(value)
        case .height: frame.size.height = CGFloat(value)
        }
        action.setBrowserFrame(frame)
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

/// Mirror of `TextFieldChangeDelegate` for `NSTextView`. Forwards every
/// edit through `onChange` so the underlying `AutoAction.text` stays in
/// sync with what the user types in the multiline editor.
final class TextViewChangeBridge: NSObject, NSTextViewDelegate {
    var onChange: (String) -> Void
    init(_ onChange: @escaping (String) -> Void) { self.onChange = onChange }

    func textDidChange(_ note: Notification) {
        guard let tv = note.object as? NSTextView else { return }
        onChange(tv.string)
    }
}
