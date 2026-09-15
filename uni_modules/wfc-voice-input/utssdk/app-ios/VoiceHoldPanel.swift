//
//  VoiceHoldPanel.swift
//  wfc-voice-input 插件 iOS 端
//
//  按住说话，交互参考微信，状态流转移植自 ../android-chat 的 audio/AudioRecorderPanel.java（三端一致），
//  浮层上的控件移植自 ../ios-chat 的 WFCUVoiceInputView.m：
//  - 按住按钮开始录音，松开发送语音
//  - 手指滑到左上方的「取消」后松开，不发送
//  - 开启转文字时，手指滑到右上方的「转文字」，边说边显示识别出的文字；松开后可以编辑文字再发送，也可以发送原语音
//  录音采集 16kHz PCM，发送语音时再编码成 AMR；转文字识别的是从开始录音算起的全部音频。
//
//  和 ios-chat 的区别，都是因为跑在 uts 插件里、按钮是 uvue 页面里的节点（和鸿蒙端、Android 端的处理一致）：
//  - 触摸由应用层的「按住说话」按钮转发进来（onTouchDown / onTouchMove / onTouchUp），坐标是屏幕坐标（pt）。
//    浮层加在 key window 上，录音时 hitTest 返回 nil 不接管触摸；UIKit 把一次触摸始终投递给按下时命中的视图，
//    所以浮层弹出后手势仍然归 uvue 的按钮；
//  - 按钮上边缘也由应用层随按下一起传进来，操作区按整个浮层宽度布局（手机上本来就是整屏）；
//  - 文案、气泡颜色来自应用层的配置；没有录音权限时在这里申请，授权之后要重新按一次；发送音效由应用层播放。
//
//  浮层的创建、布局、气泡形变、编辑文字在 VoiceHoldPanelOverlay.swift（同一个类的 extension）。
//

import AVFoundation
import UIKit

@available(iOS 13.0, *)
final class VoiceHoldPanel: NSObject, UITextViewDelegate {

    struct Listener {
        /// 录音完成，audioFile 是 AMR 文件，duration 单位是秒
        let onRecordSuccess: (String, Int) -> Void
        /// 录音失败，用户主动取消时 reason 是 reasonUserCanceled
        let onRecordFail: (String) -> Void
        /// 语音转成文字后，用户确认发送文字
        let onSendText: (String) -> Void
        /// 没有麦克风权限，申请也被拒绝了
        let onPermissionDenied: () -> Void
    }

    /// 用户取消时 onRecordFail 的 reason
    static let reasonUserCanceled = "user canceled"

    enum Stage {
        case idle
        // 按住录音中
        case recording
        // 在「转文字」上松手后，编辑识别出的文字
        case editing
        // 浮层正在退出
        case dismissing
    }

    /// 气泡形态：松开发送、取消、转文字、编辑文字、没有识别到文字、说话时间太短
    enum BubbleState {
        case send
        case cancel
        case text
        case edit
        case noText
        case tooShort
    }

    static let maxDuration: TimeInterval = 60
    static let minDuration: TimeInterval = 1
    /// 录音剩余多少时间时开始倒计时
    static let countDownDuration: TimeInterval = 10

    let listener: Listener

    // 配置，每次按下时从 VoiceInputContext 取
    var speechToTextEnabled = false
    // 气泡使用 app 主色调，气泡上的文字和声波根据主色调的深浅用白色或深色
    var bubbleColor = VoiceInputContext.bubbleColor
    var bubbleContentColor = UIColor.white
    var texts = VoiceInputTexts()

    var stage = Stage.idle
    // 每次录音加 1，用来丢弃上一次录音延迟到达的回调
    var recordSession = 0
    // 手指和按钮上边缘的屏幕坐标，pt
    var touchScreenPoint = CGPoint.zero
    var buttonTopScreen: CGFloat = 0
    var recorder: VoicePcmRecorder?
    var pcmBuffer: Data?
    var recordedPcm: Data?
    var startTime: CFTimeInterval = 0
    var recordDuration: TimeInterval = 0
    var tickTimer: Timer?
    var dismissWorkItem: DispatchWorkItem?

    var asrManager: VoiceAsrManager?
    var asrStarted = false
    var asrFinished = false
    var asrFailed = false

    // 浮层，创建一次反复使用，每次按下加到 key window 上
    let overlay = VoiceInputOverlayView(frame: .zero)
    let backgroundView = VoiceInputBackgroundView(frame: .zero)
    let bottomView = VoiceRecordBottomView(frame: .zero)
    let countDownLabel = UILabel()
    let bubbleView = VoiceBubbleView(frame: .zero)
    let waveView = VoiceWaveView(frame: .zero)
    let textView = VoiceEditTextView(frame: .zero, textContainer: nil)
    let placeholderLabel = UILabel()
    let hintLabel = UILabel()
    let editActionsView = UIView()
    let cancelActionView = UIView()
    let sendVoiceActionView = UIView()
    let cancelButton = UIButton(type: .custom)
    let sendVoiceButton = UIButton(type: .custom)
    let cancelLabel = UILabel()
    let sendVoiceLabel = UILabel()
    let sendTextButton = UIButton(type: .custom)

    // 浮层完成布局、各部分的位置已经计算好
    var layoutReady = false
    var stageLeft: CGFloat = 0
    var stageWidth: CGFloat = 0
    var bubbleBottomMargin: CGFloat = 0
    var editActionsBottomMargin: CGFloat = 0
    // 编辑文字时软键盘把气泡和按钮顶起的高度
    var keyboardShift: CGFloat = 0
    var keyboardObserver: NSObjectProtocol?
    var bubbleState = BubbleState.send
    var bubbleFrame = VoiceBubbleFrame()
    var bubbleFrom = VoiceBubbleFrame()
    var bubbleTo = VoiceBubbleFrame()
    var bubbleProgress = VoiceTween(1)
    var backgroundProgress = VoiceTween(0)
    var panelTop = VoiceTween(0)
    // 背景淡出结束后执行，用来在退出动画结束时关闭浮层
    var backgroundCompletion: (() -> Void)?
    var countDownShown = false
    lazy var panelLink = VoiceDisplayLink { [weak self] in
        self?.onFrame()
    }

    init(listener: Listener) {
        self.listener = listener
        super.init()
        setupOverlay()
    }

    /// 录音入口销毁时调用：立即关闭浮层，停止录音和识别，不回调
    func release() {
        dismissNow()
    }

    // MARK: - 触摸

    /// 手指按下「按住说话」
    /// - Parameters:
    ///   - screenPoint: 手指的屏幕坐标，pt
    ///   - buttonTop: 按钮上边缘的屏幕坐标，pt。底部弧形区域要盖住按钮
    func onTouchDown(_ screenPoint: CGPoint, buttonTop: CGFloat) {
        touchScreenPoint = screenPoint
        buttonTopScreen = buttonTop
        if stage == .dismissing {
            // 上一次录音的浮层还在退出，直接关闭
            dismissNow()
        }
        if stage != .idle {
            return
        }
        if !VoiceInputContext.isMicrophoneGranted() {
            VoiceInputContext.requestMicrophonePermission { [weak self] granted in
                if !granted {
                    self?.listener.onPermissionDenied()
                }
            }
            // 和鸿蒙端、Android 端一样，授权之后要重新按一次
            return
        }
        applyConfig()
        startRecord()
    }

    func onTouchMove(_ screenPoint: CGPoint) {
        touchScreenPoint = screenPoint
        if stage == .recording {
            updateZone()
        }
    }

    /// 手指抬起或手势被打断，都按手指当前所在的目标结束（和 android-chat 一致）
    func onTouchUp() {
        if stage == .recording {
            stopRecord(zone: bottomView.zone)
        }
    }

    // MARK: - 录音

    private func applyConfig() {
        speechToTextEnabled = VoiceInputContext.speechToTextEnabled
        bubbleColor = VoiceInputContext.bubbleColor
        bubbleContentColor = VoiceInputContext.contentColor(for: bubbleColor)
        texts = VoiceInputContext.texts
    }

    private func startRecord() {
        recordSession += 1
        let session = recordSession
        let newRecorder = VoicePcmRecorder()
        newRecorder.onData = { [weak self] pcm in
            // 在录音队列回调
            let level = VoiceHoldPanel.computeLevel(pcm)
            DispatchQueue.main.async {
                self?.handleAudioData(session, pcm, level)
            }
        }
        newRecorder.onError = { [weak self] message in
            self?.handleRecorderError(session, message)
        }
        if !newRecorder.start() {
            // 启动失败时会异步回调 onError，这次录音作废
            recordSession += 1
            listener.onRecordFail(texts.recordFailed)
            return
        }

        recorder = newRecorder
        pcmBuffer = Data()
        recordedPcm = nil
        startTime = CACurrentMediaTime()
        stage = .recording
        asrStarted = false
        asrFinished = false
        asrFailed = false
        showOverlay()
        startTick()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func handleAudioData(_ session: Int, _ pcm: Data, _ level: CGFloat) {
        if session != recordSession || pcmBuffer == nil {
            return
        }
        pcmBuffer?.append(pcm)
        if stage == .recording {
            waveView.setLevel(level)
        }
        asrManager?.feedAudioData(pcm)
    }

    private func handleRecorderError(_ session: Int, _ message: String) {
        if session != recordSession || stage != .recording {
            return
        }
        VoiceInputContext.log("录音失败: \(message)")
        if let buffer = pcmBuffer, !buffer.isEmpty {
            // 例如来电打断了录音，按手指当前的位置结束录音，保留已经录到的声音
            stopRecord(zone: bottomView.zone)
        } else {
            listener.onRecordFail(message)
            dismissOverlay()
        }
    }

    private func startTick() {
        stopTick()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.onTick()
        }
        // common 模式：手指按着拖动时主线程 run loop 在 tracking 模式，default 模式的定时器不走
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func onTick() {
        if stage != .recording {
            stopTick()
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        if elapsed >= VoiceHoldPanel.maxDuration {
            stopRecord(zone: bottomView.zone)
            return
        }
        if elapsed > VoiceHoldPanel.maxDuration - VoiceHoldPanel.countDownDuration {
            showCountDown(Int(ceil(VoiceHoldPanel.maxDuration - elapsed)))
        }
    }

    /// 结束录音
    /// - Parameter zone: 松手时手指所在的目标
    private func stopRecord(zone: VoiceInputZone) {
        if stage != .recording {
            return
        }
        stopTick()
        recordDuration = CACurrentMediaTime() - startTime
        stage = zone == .text ? .editing : .dismissing
        recorder?.stop()
        recorder = nil
        // 录音队列停止前投递到主队列的音频还没处理，处理完之后再继续
        let session = recordSession
        DispatchQueue.main.async { [weak self] in
            guard let self = self, session == self.recordSession else {
                return
            }
            self.onRecordStopped(zone: zone)
        }
    }

    private func onRecordStopped(zone: VoiceInputZone) {
        recordedPcm = pcmBuffer ?? Data()
        pcmBuffer = nil
        if zone == .text {
            enterEditing()
            return
        }
        cancelSpeechToText()
        if zone == .cancel {
            listener.onRecordFail(VoiceHoldPanel.reasonUserCanceled)
            dismissOverlay()
        } else if recordDuration < VoiceHoldPanel.minDuration {
            showTooShortTip()
        } else {
            sendVoice()
            dismissOverlay()
        }
    }

    /// 把录到的音频编码成 AMR 后回调 onRecordSuccess
    func sendVoice() {
        guard let pcm = recordedPcm, !pcm.isEmpty else {
            recordedPcm = nil
            return
        }
        recordedPcm = nil
        let duration = max(1, Int((Double(pcm.count) / Double(VoicePcmRecorder.bytesPerSecond)).rounded()))
        let audioFile = VoiceHoldPanel.genAudioFile()
        let failedText = texts.recordFailed
        let callback = listener
        VoiceAmrEncoder.queue.async {
            let success = VoiceAmrEncoder.encode(pcm: pcm, to: audioFile)
            DispatchQueue.main.async {
                if success {
                    callback.onRecordSuccess(audioFile, duration)
                } else {
                    callback.onRecordFail(failedText)
                }
            }
        }
    }

    private static func genAudioFile() -> String {
        // 和 ios-chat 一样放在缓存目录，发送时 SDK 上传本地文件
        let base = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("wfc-voice-input")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return (dir as NSString).appendingPathComponent("\(Int64(Date().timeIntervalSince1970 * 1000)).amr")
    }

    /// 停止录音和识别，丢弃录到的音频
    func releaseRecording() {
        stage = .idle
        recordSession += 1
        stopTick()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        recorder?.stop()
        recorder = nil
        cancelSpeechToText()
        pcmBuffer = nil
        recordedPcm = nil
    }

    /// 计算一段 PCM 的音量，0~1
    static func computeLevel(_ pcm: Data) -> CGFloat {
        let samples = pcm.count / 2
        if samples == 0 {
            return 0
        }
        var sum = 0.0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<samples {
                let sample = Double(Int16(littleEndian: raw.load(fromByteOffset: i * 2, as: Int16.self)))
                sum += sample * sample
            }
        }
        let db = 20 * log10(max(sqrt(sum / Double(samples)), 1) / 32768)
        // -50dB 以下视为安静，-15dB 以上视为最大音量
        return CGFloat(max(0, min(1, (db + 50) / 35)))
    }

    // MARK: - 转文字

    func startSpeechToText() {
        if asrStarted {
            return
        }
        asrStarted = true
        let manager = VoiceAsrManager()
        asrManager = manager
        manager.startRecognitionWithAudioFeed(VoiceAsrManager.Callbacks(
            onPartialResult: { [weak self, weak manager] text in
                guard let self = self, let manager = manager, self.asrManager === manager else {
                    return
                }
                self.onSpeechText(text, isFinal: false)
            },
            onFinalResult: { [weak self, weak manager] text in
                guard let self = self, let manager = manager, self.asrManager === manager else {
                    return
                }
                self.onSpeechText(text, isFinal: true)
            },
            onError: { [weak self, weak manager] message in
                guard let self = self, let manager = manager, self.asrManager === manager else {
                    return
                }
                self.onSpeechError(message)
            }
        ))
        // 转文字从开始录音时算起，先补上已经录到的音频
        if asrManager === manager, let buffer = pcmBuffer {
            var offset = 0
            while offset < buffer.count {
                let end = min(buffer.count, offset + VoicePcmRecorder.chunkSize)
                manager.feedAudioData(buffer.subdata(in: offset..<end))
                offset = end
            }
        }
    }

    private func onSpeechText(_ text: String, isFinal: Bool) {
        if isFinal {
            asrFinished = true
            asrManager = nil
        }
        setBubbleText(text)
        if isFinal && stage == .editing {
            onRecognitionDoneInEditing()
        }
    }

    private func onSpeechError(_ message: String) {
        VoiceInputContext.log("转文字失败: \(message)")
        // 已经识别出的文字保留，仍然可以编辑后发送
        asrFailed = textView.text.isEmpty
        asrFinished = true
        asrManager = nil
        updateTextHint()
        if stage == .editing {
            onRecognitionDoneInEditing()
        }
    }

    func cancelSpeechToText() {
        guard let manager = asrManager else {
            return
        }
        asrManager = nil
        manager.cancelRecognition()
    }
}
