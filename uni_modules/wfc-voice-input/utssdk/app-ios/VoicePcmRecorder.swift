//
//  VoicePcmRecorder.swift
//  wfc-voice-input 插件 iOS 端
//
//  PCM 录音，移植自 ../ios-chat 的 ASR/WFCUPcmAudioRecorder.m：
//  采集 16kHz、16-bit、单声道 PCM（与 wf-voice 要求一致），按 960 字节（30ms）一帧回调。
//
//  和 ios-chat 的区别：
//  - 录音前记下音频会话原来的 category / mode，停止后还原。插件不知道 App 别处怎么用音频会话，
//    留着 record 类别不还原的话，之后播放语音消息可能没声音；
//  - 监听音频会话被打断（例如来电），按录音失败回调，和 Android 端失去音频焦点一致。
//

import AVFoundation
import Foundation

final class VoicePcmRecorder {
    static let sampleRate: Double = 16000
    static let bytesPerSecond = 32000
    static let chunkSize = 960

    /// 在内部串行队列回调，每次 chunkSize 字节
    var onData: ((Data) -> Void)?
    /// 在主线程回调
    var onError: ((String) -> Void)?

    private let audioQueue = DispatchQueue(label: "wfc-voice-input.recorder")
    private let recordingFlag = VoiceAtomicFlag()
    private var engine: AVAudioEngine?
    // 只在 audioQueue 上访问
    private var pendingData = Data()
    private var interruptionObserver: NSObjectProtocol?
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode = .default
    private var previousOptions: AVAudioSession.CategoryOptions = []

    var isRecording: Bool {
        return recordingFlag.value
    }

    /// 开始录音，调用前需要已获得录音权限。在主线程调用
    /// - Returns: 是否成功开始录音，失败时会异步回调 onError
    @discardableResult
    func start() -> Bool {
        if isRecording {
            return true
        }
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions
        do {
            // 和 ios-chat 一样用 record + measurement：关掉系统的自动增益等处理，识别更准
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            restoreSession()
            notifyError("设置音频会话失败: \(error.localizedDescription)")
            return false
        }

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoicePcmRecorder.sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            deactivateSession()
            notifyError("不支持此音频配置")
            return false
        }

        engine = newEngine
        audioQueue.async { [weak self] in
            self?.pendingData = Data()
        }
        recordingFlag.value = true
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else {
                return
            }
            let pcm = VoicePcmRecorder.convert(buffer, converter: converter)
            if pcm.isEmpty {
                return
            }
            self.audioQueue.async { [weak self] in
                guard let self = self, self.isRecording else {
                    return
                }
                self.emit(pcm)
            }
        }
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            engine = nil
            recordingFlag.value = false
            deactivateSession()
            notifyError("启动录音失败: \(error.localizedDescription)")
            return false
        }
        observeInterruption()
        VoiceInputContext.log("录音已开始: 16000Hz, 16-bit, 单声道")
        return true
    }

    /// 停止录音。在主线程调用
    func stop() {
        if !isRecording {
            return
        }
        recordingFlag.value = false
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let currentEngine = engine {
            currentEngine.inputNode.removeTap(onBus: 0)
            currentEngine.stop()
        }
        engine = nil
        deactivateSession()
        VoiceInputContext.log("录音已停止")
    }

    // MARK: - 私有方法

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        restoreSession()
    }

    private func restoreSession() {
        guard let category = previousCategory else {
            return
        }
        previousCategory = nil
        try? AVAudioSession.sharedInstance().setCategory(category, mode: previousMode, options: previousOptions)
    }

    private func observeInterruption() {
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.isRecording,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else {
                return
            }
            // 例如来电：和 Android 失去音频焦点一样按录音失败回调，由调用方决定要不要保留已经录到的声音
            VoiceInputContext.log("录音被打断")
            self.stop()
            self.onError?("录音被打断")
        }
    }

    private func notifyError(_ message: String) {
        VoiceInputContext.log(message)
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    /// 按 960 字节（30ms）一帧回调，不足一帧的先缓存。在 audioQueue 上调用
    private func emit(_ data: Data) {
        pendingData.append(data)
        let chunk = VoicePcmRecorder.chunkSize
        while pendingData.count >= chunk {
            let frame = Data(pendingData.prefix(chunk))
            pendingData.removeFirst(chunk)
            onData?(frame)
        }
    }

    /// 把硬件的 Float32 音频转换成 16kHz、16-bit、单声道 PCM
    private static func convert(_ input: AVAudioPCMBuffer, converter: AVAudioConverter) -> Data {
        if input.frameLength == 0 {
            return Data()
        }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return Data()
        }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return input
        }
        if let error = error {
            VoiceInputContext.log("音频转换失败: \(error.localizedDescription)")
            return Data()
        }
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0, let channel = output.int16ChannelData else {
            return Data()
        }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
