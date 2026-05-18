//
//  ActionCellFactory.swift
//  AIMacro
//
//  Builds the row cells shown in the left-hand action list. After the
//  master-detail split (Step 3 of the redesign) every row is the same
//  compact `ActionListCellView` — actual editing lives in the right-hand
//  detail pane built by `ActionDetailBuilder`.
//

import Cocoa

final class ActionCellFactory {
    private let mouseListener: MouseListener

    init(mouseListener: MouseListener) {
        self.mouseListener = mouseListener
    }

    func cell(for action: AutoAction, at row: Int) -> NSView? {
        let cell = ActionListCellView()
        cell.configure(index: row,
                       image: ActionIcons.image(for: action.type),
                       name: action.name,
                       disabled: (try? action.disabled.value()) ?? false)
        return cell
    }
}
