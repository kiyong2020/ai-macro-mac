//
//  ActionListCellView.swift
//  AIMacro
//
//  Compact list cell shown in the left sidebar after the master-detail split:
//  [#] [icon] [name]. All editing has moved to the detail pane on the right,
//  so the cell no longer needs the XIB-based inline controls.
//

import Cocoa

final class ActionListCellView: NSTableCellView {
    let numberLabel = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = .right
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14,
                                                                   weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(numberLabel)
        addSubview(iconView)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(index: Int, image: NSImage?, name: String) {
        numberLabel.stringValue = "\(index + 1)"
        iconView.image = image
        nameLabel.stringValue = name
    }
}
