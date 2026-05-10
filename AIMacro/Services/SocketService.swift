//
//  SocketService.swift
//  AIMacro
//

import Foundation
import SocketIO
import RxSwift

class SocketService {
    static let shared = SocketService()

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?

    let isConnected = BehaviorSubject<Bool>(value: false)
    let receivedCode = BehaviorSubject<String>(value: "")

    private init() {
        // Drop a stale verification code if a fresh action sequence kicks off,
        // otherwise the previous run's code can leak into the new run's
        // wait(.code) handler and get auto-pasted before the new code arrives.
        NotificationCenter.default.addObserver(
            forName: .actionSequenceWillStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.receivedCode.onNext("")
        }
    }

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "serverURL") ?? Constants.defaultServerURL }
        set { UserDefaults.standard.set(newValue, forKey: "serverURL") }
    }

    var userName: String {
        get { UserDefaults.standard.string(forKey: "userName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "userName") }
    }

    func connect() {
        disconnect()
        guard !userName.isEmpty, let url = URL(string: serverURL) else {
            AppLogger.shared.log("[Socket] 연결 건너뜀 — 사용자 이름이 비어있거나 URL이 유효하지 않음")
            return
        }

        AppLogger.shared.log("[Socket] 연결 시도: \(serverURL) (이름: \(userName))")

        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .forceWebsockets(true),
            .connectParams(["name": userName]),
            .reconnects(true),
            .reconnectWait(3),
            .reconnectWaitMax(30),
            .reconnectAttempts(-1)
        ])
        socket = manager?.defaultSocket

        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            AppLogger.shared.log("[Socket] 연결됨")
            DispatchQueue.main.async { self?.isConnected.onNext(true) }
        }
        socket?.on(clientEvent: .disconnect) { [weak self] data, _ in
            AppLogger.shared.log("[Socket] 연결 끊김: \(data)")
            DispatchQueue.main.async { self?.isConnected.onNext(false) }
        }
        socket?.on(clientEvent: .error) { [weak self] data, _ in
            AppLogger.shared.log("[Socket] 오류: \(data)")
            DispatchQueue.main.async { self?.isConnected.onNext(false) }
        }
        socket?.on(clientEvent: .reconnect) { data, _ in
            AppLogger.shared.log("[Socket] 재연결 중: \(data)")
        }
        socket?.on("sms:code") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let code = dict["code"] as? String else { return }
            AppLogger.shared.log("[Socket] sms:code 수신: \(code)")
            DispatchQueue.main.async { self?.receivedCode.onNext(code) }
        }
        socket?.connect()
    }

    func disconnect() {
        AppLogger.shared.log("[Socket] 연결 해제")
        socket?.disconnect()
        socket = nil
        manager = nil
        isConnected.onNext(false)
    }
}
