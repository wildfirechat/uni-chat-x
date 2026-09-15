//
//  VoiceAsrWebSocketClient.swift
//  wfc-voice-input 插件 iOS 端
//
//  实时语音识别 WebSocket 客户端，移植自 ../ios-chat 的 ASR/WFCUAsrWebSocketClient.m（Android 端是 AsrWebSocketClient.kt）。
//
//  连接 asr-api 的 /api/stream，由 asr-api 鉴权后转发给 wf-voice；内网测试时也可以直连 wf-voice。
//  协议详见 wf-voice 项目的 docs/server-api.md：
//  1. 连接后发送的第一条文本消息是 clientId；需要边说边出字时，接着发送 partial
//  2. 二进制消息发送 16kHz、16-bit、单声道 PCM
//  3. 服务端每识别完一句，推送一条文本消息：[段开始毫秒时间戳+时长秒] 识别文本
//  4. 发送过 partial 时，说话过程中还会推送正在说的这句的中间结果：[PARTIAL] 识别文本
//  5. 说话结束时发送 eos，服务端推送完剩余识别结果后回复 [EOS]
//
//  每次识别使用一个新实例。连接成功之前就可以发送音频，音频先缓存，连接成功后跟在 clientId 后面发送。
//  回调都在主线程，disconnect 之后不再回调。URLSessionWebSocketTask 要 iOS 13。
//

import Foundation

@available(iOS 13.0, *)
final class VoiceAsrWebSocketClient: NSObject {

    static let headerAuthCode = "authCode"

    private static let messageEos = "eos"
    private static let messagePartial = "partial"
    private static let messageEosAck = "[EOS]"
    private static let messagePartialPrefix = "[PARTIAL]"
    private static let messagePong = "pong"
    private static let messageTrialPrefix = "[TRIAL]"

    // 发送 eos 前补发约 500ms 静音，让不支持 eos 的旧版本 wf-voice 也能通过 VAD 断句，识别出最后一句。
    // 静音和录音一样按 30ms（960 字节）一条消息发送，单条消息过大时 asr-api 或 wf-voice 会断开连接
    private static let silenceFrameBytes = 960
    private static let silencePaddingFrames = 17

    // 心跳间隔，和 Android 端 OkHttp 的 pingInterval 一致
    private static let pingInterval: TimeInterval = 30

    /// 连接成功，连接成功之前缓存的音频已经发送
    var onConnected: (() -> Void)?
    /// 正在说的这句的中间结果，之后会被新的中间结果或这句的最终结果替换
    var onPartialResult: ((String) -> Void)?
    /// 识别出一句的最终结果
    var onResult: ((String) -> Void)?
    /// eos 之前的识别结果已全部返回
    var onEos: (() -> Void)?
    /// 连接失败或连接被断开
    var onError: ((String) -> Void)?

    // 下面的字段在录音队列、URLSession 回调队列也会访问，读写时要持有 lock
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    // 连接成功之前发送的音频。获取认证码、建立连接期间录音已经在产生音频，connect 之前就要能缓存
    private var pendingAudio: [Data] = []
    private var opened = false
    private var disconnected = false

    // 只在主线程访问
    private var pingTimer: Timer?

    /// 连接语音识别服务
    /// - Parameters:
    ///   - url: WebSocket 地址，asr-api 或 wf-voice
    ///   - clientId: 客户端 ID，wf-voice 要求每个连接唯一
    ///   - partialResult: 是否边说边出字
    ///   - authCode: 连接 asr-api 时需要的认证码，直连 wf-voice 时传 nil
    func connect(url: String, clientId: String, partialResult: Bool, authCode: String?) {
        VoiceInputContext.log("正在连接语音识别服务: \(url)")
        guard let requestUrl = URL(string: url) else {
            notifyError("语音识别服务地址无效")
            return
        }
        var request = URLRequest(url: requestUrl)
        if let authCode = authCode, !authCode.isEmpty {
            request.setValue(authCode, forHTTPHeaderField: VoiceAsrWebSocketClient.headerAuthCode)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let newSession = URLSession(configuration: config)
        let newTask = newSession.webSocketTask(with: request)

        lock.lock()
        if disconnected {
            lock.unlock()
            newSession.invalidateAndCancel()
            return
        }
        session = newSession
        task = newTask
        lock.unlock()

        newTask.resume()
        receiveNextMessage(newTask)
        // 连接后发送的第一条文本消息是 clientId，发送成功说明连接已经建立
        newTask.send(.string(clientId)) { [weak self] error in
            guard let self = self else {
                return
            }
            if let error = error {
                self.handleFailure(error, task: newTask)
                return
            }
            self.onOpened(newTask, partialResult: partialResult)
        }
        startPing()
    }

    /// 发送音频数据，可以在任意线程调用。还没连接成功时先缓存，连接成功后发送
    /// - Parameter pcm: 16kHz、16-bit、单声道 PCM
    func sendAudioData(_ pcm: Data) {
        if pcm.isEmpty {
            return
        }
        lock.lock()
        defer {
            lock.unlock()
        }
        if disconnected {
            return
        }
        guard opened, let currentTask = task else {
            pendingAudio.append(pcm)
            return
        }
        currentTask.send(.data(pcm)) { error in
            if let error = error {
                VoiceInputContext.log("发送音频数据失败: \(error.localizedDescription)")
            }
        }
    }

    /// 通知服务端说话结束，服务端返回剩余识别结果后回调 onEos。需要在连接成功后调用
    func sendEos() {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard opened, !disconnected, let currentTask = task else {
            return
        }
        let silence = Data(count: VoiceAsrWebSocketClient.silenceFrameBytes)
        for _ in 0..<VoiceAsrWebSocketClient.silencePaddingFrames {
            currentTask.send(.data(silence)) { _ in }
        }
        currentTask.send(.string(VoiceAsrWebSocketClient.messageEos)) { _ in }
    }

    /// 断开连接，之后不再回调。在主线程调用
    func disconnect() {
        lock.lock()
        if disconnected {
            lock.unlock()
            return
        }
        disconnected = true
        pendingAudio.removeAll()
        let currentTask = task
        let currentSession = session
        task = nil
        session = nil
        lock.unlock()

        onConnected = nil
        onPartialResult = nil
        onResult = nil
        onEos = nil
        onError = nil
        pingTimer?.invalidate()
        pingTimer = nil
        currentTask?.cancel(with: .normalClosure, reason: nil)
        currentSession?.invalidateAndCancel()
    }

    // MARK: - 私有方法

    private func isDisconnected() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return disconnected
    }

    /// 连接成功，先发送 partial 等指令，再发送连接成功之前缓存的音频
    private func onOpened(_ openedTask: URLSessionWebSocketTask, partialResult: Bool) {
        lock.lock()
        if disconnected || task !== openedTask {
            lock.unlock()
            return
        }
        if partialResult {
            openedTask.send(.string(VoiceAsrWebSocketClient.messagePartial)) { _ in }
        }
        var pendingBytes = 0
        for data in pendingAudio {
            pendingBytes += data.count
            openedTask.send(.data(data)) { _ in }
        }
        pendingAudio.removeAll()
        opened = true
        lock.unlock()
        // 16kHz、16-bit 的音频每毫秒 32 字节
        VoiceInputContext.log("WebSocket 连接成功，发送连接前缓存的音频 \(pendingBytes / 32)ms")
        postToMain { client in
            client.onConnected?()
        }
    }

    private func receiveNextMessage(_ receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self] result in
            guard let self = self, !self.isDisconnected() else {
                return
            }
            switch result {
            case .failure(let error):
                self.handleFailure(error, task: receivingTask)
            case .success(let message):
                if case .string(let text) = message, !text.isEmpty {
                    self.handleText(text)
                }
                self.receiveNextMessage(receivingTask)
            }
        }
    }

    private func startPing() {
        VoiceInputContext.runOnMain { [weak self] in
            guard let self = self, !self.isDisconnected(), self.pingTimer == nil else {
                return
            }
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: VoiceAsrWebSocketClient.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func sendPing() {
        lock.lock()
        let currentTask = disconnected ? nil : task
        lock.unlock()
        currentTask?.sendPing { error in
            if let error = error {
                VoiceInputContext.log("ping 失败: \(error.localizedDescription)")
            }
        }
    }

    private func handleText(_ message: String) {
        if message == VoiceAsrWebSocketClient.messageEosAck {
            VoiceInputContext.log("收到 [EOS]")
            postToMain { client in
                client.onEos?()
            }
        } else if message.hasPrefix(VoiceAsrWebSocketClient.messagePartialPrefix) {
            let text = String(message.dropFirst(VoiceAsrWebSocketClient.messagePartialPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                postToMain { client in
                    client.onPartialResult?(text)
                }
            }
        } else if message.hasPrefix(VoiceAsrWebSocketClient.messageTrialPrefix) {
            // 体验版每个连接只识别前 30 秒音频
            VoiceInputContext.log(message)
        } else if message != VoiceAsrWebSocketClient.messagePong {
            VoiceInputContext.log("收到识别结果: \(message)")
            let text = VoiceAsrWebSocketClient.parseResultText(message)
            if !text.isEmpty {
                postToMain { client in
                    client.onResult?(text)
                }
            }
        }
    }

    private func handleFailure(_ error: Error, task failedTask: URLSessionWebSocketTask) {
        lock.lock()
        let stale = disconnected || task !== failedTask
        lock.unlock()
        if stale {
            return
        }
        let statusCode = (failedTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let nsError = error as NSError
        if statusCode != 401 && nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        VoiceInputContext.log("WebSocket 连接失败 status=\(statusCode) error=\(error.localizedDescription)")
        notifyError(statusCode == 401 ? "语音识别服务鉴权失败" : "连接失败: \(error.localizedDescription)")
    }

    private func notifyError(_ message: String) {
        postToMain { client in
            client.onError?(message)
        }
    }

    /// 切换到主线程执行回调，已断开连接时忽略
    private func postToMain(_ action: @escaping (VoiceAsrWebSocketClient) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDisconnected() else {
                return
            }
            action(self)
        }
    }

    /// 去掉识别结果的时间前缀，例如 "[1740992313000+2.35] 你好，世界，" 返回 "你好，世界，"
    private static func parseResultText(_ message: String) -> String {
        var text = message
        if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
            text = String(text[text.index(after: end)...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
