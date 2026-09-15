//
//  VoiceAsrManager.swift
//  wfc-voice-input 插件 iOS 端
//
//  实时语音输入管理器，移植自 ../ios-chat 的 ASR/WFCUAsrManager.m（去掉了没用到的 Over 热词），Android 端是 AsrManager.kt。
//
//  录音并实时推送到 wf-voice 识别（经过 asr-api 转发，内网测试时也可以直连）。wf-voice 每识别完一句返回这句的最终结果；
//  开启边说边出字后，说话过程中还会返回正在说的这句的中间结果。
//  所有方法都在主线程调用，回调也在主线程（isRecognizing 除外，任意线程可读）。
//

import Foundation

@available(iOS 13.0, *)
final class VoiceAsrManager {

    struct Callbacks {
        /// 识别文本有更新，参数是本次识别到目前为止的全部文本
        let onPartialResult: (String) -> Void
        /// 识别完成，参数是本次识别的全部文本，可能为空；之后不再回调
        let onFinalResult: (String) -> Void
        /// 出错，之后不再回调
        let onError: (String) -> Void
    }

    private enum State {
        case idle       // 空闲
        case connecting // 连接中，已经开始录音或接收调用方提供的音频，音频先缓存
        case recording  // 已连接，录音中
        case finishing  // 已停止录音，等待剩余识别结果
    }

    // 最长录音时长：60秒
    private static let maxRecordingDuration: TimeInterval = 60
    // 停止录音后等待剩余识别结果的基础时间：8秒
    private static let waitEosTimeout: TimeInterval = 8
    // 停止录音后收到过识别结果，之后这么久没有新消息，认为已经识别完。
    // 服务端不支持 eos 指令或消息在转发中丢失时不会回复 [EOS]，靠它结束识别
    private static let waitEosIdleAfterResult: TimeInterval = 10
    // 16kHz、16-bit 的音频每毫秒 32 字节
    private static let pcmBytesPerMillisecond = 32

    private var state = State.idle {
        didSet {
            recognizing.value = state != .idle
        }
    }

    // 应用层可能从 JS 线程同步问是否正在识别
    private let recognizing = VoiceAtomicFlag()
    private var callbacks: Callbacks?
    private var audioRecorder: VoicePcmRecorder?
    private var wsClient: VoiceAsrWebSocketClient?
    // 本次识别已确定的文本，即各句的最终结果
    private var recognizedText = ""
    // 正在说的这句的中间结果，收到这句的最终结果后清空
    private var partialText = ""
    // 音频由调用方通过 feedAudioData 提供，而不是自己录音
    private var feedAudio = false
    // 连接成功前已经停止录音或停止提供音频，连接成功后发送完缓存的音频再结束识别
    private var pendingStop = false
    // 调用方提供的音频字节数，用于估算等待剩余识别结果的时间
    private var feedAudioBytes = 0

    private var maxDurationItem: DispatchWorkItem?
    private var waitEosTimeoutItem: DispatchWorkItem?
    private var waitEosIdleItem: DispatchWorkItem?

    /// 是否正在识别，包括停止录音后等待剩余识别结果的阶段。任意线程可读
    var isRecognizing: Bool {
        return recognizing.value
    }

    /// 开始语音识别，调用前需要已获得录音权限。会立即开始录音，连接识别服务期间录到的音频先缓存，连接成功后再发送
    func startRecognition(_ callbacks: Callbacks) {
        start(callbacks, feedAudio: false)
    }

    /// 开始语音识别，由调用方通过 feedAudioData 提供音频，提供完后调用 stopRecognition。
    /// 连接识别服务期间提供的音频会先缓存，连接成功后再发送
    func startRecognitionWithAudioFeed(_ callbacks: Callbacks) {
        start(callbacks, feedAudio: true)
    }

    private func start(_ callbacks: Callbacks, feedAudio: Bool) {
        if state != .idle {
            VoiceInputContext.log("正在识别中，无需重复开始")
            return
        }
        let url = VoiceInputContext.asrServerUrl
        if url.isEmpty {
            callbacks.onError("未配置语音识别服务地址")
            return
        }
        self.callbacks = callbacks
        self.feedAudio = feedAudio
        state = .connecting
        recognizedText = ""
        partialText = ""
        pendingStop = false
        feedAudioBytes = 0

        let client = VoiceAsrWebSocketClient()
        client.onConnected = { [weak self] in
            guard let self = self, self.state == .connecting else {
                return
            }
            self.state = .recording
            if self.pendingStop {
                self.pendingStop = false
                self.stopRecognition()
            }
        }
        client.onPartialResult = { [weak self] text in
            guard let self = self else {
                return
            }
            self.delayIdleFinish()
            self.partialText = text
            self.callbacks?.onPartialResult(self.currentText())
        }
        client.onResult = { [weak self] text in
            guard let self = self else {
                return
            }
            self.delayIdleFinish()
            self.handleSentenceResult(text)
        }
        client.onEos = { [weak self] in
            self?.finishRecognition()
        }
        client.onError = { [weak self] error in
            guard let self = self else {
                return
            }
            VoiceInputContext.log("语音识别服务错误: \(error)")
            if self.state == .finishing {
                // 已经停止录音，保留已识别出的文本
                self.finishRecognition()
            } else {
                self.failRecognition(error)
            }
        }
        wsClient = client
        if !feedAudio {
            // 获取认证码、连接识别服务可能要一两秒，用户点完就开始说话。先开始录音，音频由 client 缓存到连接成功后发送
            startAudioRecording()
        }
        // wf-voice 要求每个连接的 clientId 唯一，并会用作服务端录音文件名。连接 asr-api 时由 asr-api 重新生成
        let clientId = VoiceInputContext.userId + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let partialResult = VoiceInputContext.asrPartialResult
        if !VoiceAsrManager.isAsrApiUrl(url) {
            // 直连 wf-voice，不需要鉴权
            client.connect(url: url, clientId: clientId, partialResult: partialResult, authCode: nil)
            return
        }
        VoiceInputContext.requestAuthCode(success: { [weak self, weak client] authCode in
            // 获取认证码期间，识别可能已经停止或取消
            guard let self = self, let client = client, self.wsClient === client else {
                return
            }
            client.connect(url: url, clientId: clientId, partialResult: partialResult, authCode: authCode)
        }, fail: { [weak self, weak client] errorCode in
            guard let self = self, let client = client, self.wsClient === client else {
                return
            }
            self.failRecognition("获取认证码失败: \(errorCode)")
        })
    }

    /// 停止录音或停止提供音频，剩余识别结果返回后回调 onFinalResult
    func stopRecognition() {
        switch state {
        case .connecting:
            if pendingStop {
                return
            }
            let hasAudio = audioRecorder != nil || feedAudioBytes > 0
            stopAudioRecording()
            if hasAudio {
                // 连接成功后发送完缓存的音频再结束，一直连不上时超时
                VoiceInputContext.log("停止录音，连接成功后再结束识别")
                pendingStop = true
                maxDurationItem?.cancel()
                maxDurationItem = nil
                waitEosTimeoutItem?.cancel()
                waitEosTimeoutItem = schedule(VoiceAsrManager.waitEosTimeout) { [weak self] in
                    self?.onWaitEosTimeout()
                }
            } else {
                // 还没有音频
                finishRecognition()
            }
        case .recording:
            state = .finishing
            maxDurationItem?.cancel()
            maxDurationItem = nil
            stopAudioRecording()
            wsClient?.sendEos()
            // 服务端是按实时速度消费音频的：一次提供了较长的音频时（例如先按住说了十几秒才滑到「转文字」，
            // 之前录到的音频会一次性补发过去），要把积压的音频按实时速度消完才可能出结果，
            // 所以停止后的等待时间要加上音频时长本身（实测能到音频时长的 1.6 倍，按 1.5 倍再加 8 秒基础时间）
            let audioMs = feedAudioBytes / VoiceAsrManager.pcmBytesPerMillisecond
            let waitAfterEos = VoiceAsrManager.waitEosTimeout + Double(audioMs) * 1.5 / 1000
            VoiceInputContext.log("停止录音，等待剩余识别结果：音频约 \(audioMs)ms，最长等待 \(waitAfterEos) 秒")
            waitEosTimeoutItem?.cancel()
            waitEosTimeoutItem = schedule(waitAfterEos) { [weak self] in
                self?.onWaitEosTimeout()
            }
            // 收到第一条结果前不能提前结束，否则积压的音频还没识别完就放弃了
            waitEosIdleItem?.cancel()
            waitEosIdleItem = schedule(waitAfterEos) { [weak self] in
                self?.onWaitEosIdle()
            }
        default:
            break
        }
    }

    /// 提供音频数据，只在 startRecognitionWithAudioFeed 之后有效
    /// - Parameter pcm: 16kHz、16-bit、单声道 PCM
    func feedAudioData(_ pcm: Data) {
        if !feedAudio || pendingStop || (state != .connecting && state != .recording) {
            return
        }
        wsClient?.sendAudioData(pcm)
        feedAudioBytes += pcm.count
    }

    /// 取消语音识别，丢弃还没返回的识别结果，之后不再回调
    func cancelRecognition() {
        if state != .idle {
            VoiceInputContext.log("取消识别")
            cleanup()
        }
    }

    // MARK: - 超时

    private func onWaitEosTimeout() {
        if state == .connecting {
            failRecognition("连接语音识别服务超时")
        } else {
            VoiceInputContext.log("等待剩余识别结果超时，结束识别")
            finishRecognition()
        }
    }

    private func onWaitEosIdle() {
        VoiceInputContext.log("没有收到 [EOS]，按已返回的识别结果结束识别")
        finishRecognition()
    }

    /// 停止录音后又收到识别结果，重新计算没有新消息就结束识别的时间
    private func delayIdleFinish() {
        if state == .finishing {
            waitEosIdleItem?.cancel()
            waitEosIdleItem = schedule(VoiceAsrManager.waitEosIdleAfterResult) { [weak self] in
                self?.onWaitEosIdle()
            }
        }
    }

    private func schedule(_ delay: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    // MARK: - 录音

    private func startAudioRecording() {
        let client = wsClient
        let recorder = VoicePcmRecorder()
        audioRecorder = recorder
        recorder.onData = { pcm in
            // 在录音队列回调，实时发送到服务端，还没连接成功时 client 会先缓存
            client?.sendAudioData(pcm)
        }
        recorder.onError = { [weak self, weak recorder] message in
            // 忽略已经停止的录音报的错误
            guard let self = self, let recorder = recorder, self.audioRecorder === recorder else {
                return
            }
            self.failRecognition("录音失败: \(message)")
        }
        // 启动失败时 recorder 会回调 onError，由它结束识别
        if recorder.start() {
            maxDurationItem = schedule(VoiceAsrManager.maxRecordingDuration) { [weak self] in
                VoiceInputContext.log("达到最大录音时长，自动停止")
                self?.stopRecognition()
            }
        }
    }

    private func stopAudioRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
    }

    // MARK: - 结果

    private func handleSentenceResult(_ sentence: String) {
        partialText = ""
        recognizedText = VoiceAsrManager.join(recognizedText, sentence)
        callbacks?.onPartialResult(currentText())
    }

    /// 已确定的文本，加上正在说的这句的中间结果
    private func currentText() -> String {
        return VoiceAsrManager.join(recognizedText, partialText)
    }

    private func finishRecognition() {
        if state == .idle {
            return
        }
        let cb = callbacks
        // wf-voice 会把句号替换成逗号，去掉结尾多余的逗号
        let text = currentText().replacingOccurrences(of: "[，,]+$", with: "", options: .regularExpression)
        VoiceInputContext.log("识别结束，文本长度 \(text.count)")
        cleanup()
        cb?.onFinalResult(text)
    }

    private func failRecognition(_ message: String) {
        if state == .idle {
            return
        }
        let cb = callbacks
        VoiceInputContext.log("识别失败: \(message)")
        cleanup()
        cb?.onError(message)
    }

    private func cleanup() {
        state = .idle
        callbacks = nil
        maxDurationItem?.cancel()
        maxDurationItem = nil
        waitEosTimeoutItem?.cancel()
        waitEosTimeoutItem = nil
        waitEosIdleItem?.cancel()
        waitEosIdleItem = nil
        stopAudioRecording()
        wsClient?.disconnect()
        wsClient = nil
        recognizedText = ""
        partialText = ""
        feedAudio = false
        pendingStop = false
        feedAudioBytes = 0
    }

    // MARK: - 工具

    /// 是否是 asr-api 的地址。asr-api 的接口都在 /api/ 路径下，直连 wf-voice 的地址没有路径
    static func isAsrApiUrl(_ url: String) -> Bool {
        guard let path = URL(string: url)?.path else {
            return false
        }
        return path.contains("/api/")
    }

    /// 拼接两段识别文本，两段英文之间补一个空格
    private static func join(_ text: String, _ sentence: String) -> String {
        if let last = text.unicodeScalars.last, let first = sentence.unicodeScalars.first,
           last.value < 128, !CharacterSet.whitespacesAndNewlines.contains(last),
           first.value < 128, CharacterSet.alphanumerics.contains(first) {
            return text + " " + sentence
        }
        return text + sentence
    }
}
