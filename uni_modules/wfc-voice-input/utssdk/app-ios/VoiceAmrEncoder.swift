//
//  VoiceAmrEncoder.swift
//  wfc-voice-input 插件 iOS 端
//
//  把 16kHz、16-bit、单声道 PCM 编码成 AMR-NB 文件，格式和其他端录的语音消息一致。
//
//  iOS 没有系统的 AMR 编码器（AVAudioConverter 只能解码 AMR），借 IM SDK 里带的 opencore-amr：
//  先降采样写成 8kHz 的 wav，再用 WFCCSoundMessageContent 的 wav 转 amr —— ios-chat 的按住说话也是这么发语音的。
//  所以本插件带了一份 WFChatClient.xcframework（wfc-av-client、wfc-ptt-client 也是各带一份）。
//  降采样前的低通滤波和 Android 端 PcmAmrEncoder.kt 一样（ios-chat 是直接隔一个取一个，4kHz 以上的声音会混叠）。
//

import Foundation
import WFChatClient

enum VoiceAmrEncoder {
    /// 串行的编码队列：60 秒的语音滤波 + 编码要几百毫秒，不能放主线程
    static let queue = DispatchQueue(label: "wfc-voice-input.amr")

    // 16kHz 降采样到 8kHz 前的低通滤波器，滤掉 4kHz 以上的声音，避免混叠
    private static let lowPassFilter = createHalfBandFilter(31)

    /// 同步编码，要在后台线程调用
    /// - Returns: 是否编码成功
    static func encode(pcm: Data, to amrPath: String) -> Bool {
        let samples = downsample(pcm)
        if samples.isEmpty {
            return false
        }
        let fileManager = FileManager.default
        let wavPath = amrPath + ".wav"
        defer {
            try? fileManager.removeItem(atPath: wavPath)
        }
        guard writeWav(path: wavPath, samples: samples, sampleRate: 8000) else {
            VoiceInputContext.log("写 wav 失败: \(wavPath)")
            return false
        }
        try? fileManager.removeItem(atPath: amrPath)
        let duration = max(1, Int((Double(pcm.count) / Double(VoicePcmRecorder.bytesPerSecond)).rounded()))
        // 构造语音消息的同时会把 wav 转成 amr 写到 amrPath，消息对象本身用不上
        _ = WFCCSoundMessageContent(forWav: wavPath, destinationAmrPath: amrPath, duration: duration)
        let size = ((try? fileManager.attributesOfItem(atPath: amrPath))?[.size] as? NSNumber)?.intValue ?? 0
        // 只有 "#!AMR\n" 文件头，说明一帧也没编出来
        if size <= 6 {
            VoiceInputContext.log("wav 转 amr 失败，amr 文件 \(size) 字节")
            return false
        }
        return true
    }

    /// 滤波后每两个采样取一个，降到 8kHz
    private static func downsample(_ pcm: Data) -> [Int16] {
        let inSamples = pcm.count / 2
        if inSamples == 0 {
            return []
        }
        // 16-bit PCM 是小端，iOS 设备本来就是小端，直接按 Int16 拷
        var input = [Int16](repeating: 0, count: inSamples)
        _ = input.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        let halfTaps = lowPassFilter.count / 2
        var output = [Int16]()
        output.reserveCapacity((inSamples + 1) / 2)
        var i = 0
        while i < inSamples {
            var sum = 0.0
            for k in 0..<lowPassFilter.count {
                let index = min(max(i + k - halfTaps, 0), inSamples - 1)
                sum += lowPassFilter[k] * Double(input[index])
            }
            output.append(Int16(max(Double(Int16.min), min(Double(Int16.max), sum.rounded()))))
            i += 2
        }
        return output
    }

    private static func writeWav(path: String, samples: [Int16], sampleRate: UInt32) -> Bool {
        let dataSize = UInt32(samples.count * 2)
        var wav = Data(capacity: 44 + Int(dataSize))
        func appendValue<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8))
        appendValue((36 + dataSize).littleEndian)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        appendValue(UInt32(16).littleEndian)
        // PCM、单声道
        appendValue(UInt16(1).littleEndian)
        appendValue(UInt16(1).littleEndian)
        appendValue(sampleRate.littleEndian)
        // byteRate、blockAlign、bitsPerSample
        appendValue((sampleRate * 2).littleEndian)
        appendValue(UInt16(2).littleEndian)
        appendValue(UInt16(16).littleEndian)
        wav.append(contentsOf: Array("data".utf8))
        appendValue(dataSize.littleEndian)
        samples.withUnsafeBufferPointer { wav.append($0) }
        return FileManager.default.createFile(atPath: path, contents: wav)
    }

    /// 截止频率为采样率 1/4 的加窗（Hamming）半带低通滤波器
    private static func createHalfBandFilter(_ taps: Int) -> [Double] {
        var filter = [Double](repeating: 0, count: taps)
        let center = taps / 2
        var sum = 0.0
        for i in 0..<taps {
            let n = i - center
            let sinc = n == 0 ? 0.5 : sin(Double.pi * Double(n) / 2) / (Double.pi * Double(n))
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(taps - 1))
            filter[i] = sinc * window
            sum += filter[i]
        }
        return filter.map { $0 / sum }
    }
}
