//
//  UIExtension.swift
//  AIMacro
//
//  Created by Kiyong Kim on 7/2/25.
//

import AppKit
import RxSwift
import RxCocoa

extension NSSwitch {
    // Target-Action용 ControlEvent
    public var rx_state: ControlEvent<Bool> {
        // 이벤트 스트림
        let source = self.rx.controlEvent
            .map { self.state == .on }

        return ControlEvent(events: source)
    }
}
