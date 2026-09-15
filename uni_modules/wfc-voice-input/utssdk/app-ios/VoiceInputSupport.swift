//
//  VoiceInputSupport.swift
//  wfc-voice-input 插件 iOS 端（UTS 原生混编）
//
//  插件内共用的配置、事件出口、认证码请求、麦克风权限、线程、日志和几个动画小工具，
//  对应鸿蒙端的 VoiceInputContext.ets、Android 端的 VoiceInputContext.kt。
//
//  ---- 为什么这些 .swift 不 import DCloudUTSFoundation ----
//  混编的 Swift 在 HBuilderX 里没有语法检查，写错了要等整个 App 编译才知道。不依赖 uts 基础库，
//  就能在本地直接用 swiftc -typecheck 对着 iOS SDK 检查；往 HBuilderX 控制台打日志要用 uts 的 console，
//  由 index.uts 以闭包注入（VoiceInputIOS.setup）。
//
//  ---- 线程 ----
//  vapor 模式下应用层从 JS 线程调进插件（wfc-av-client 的 index.uts 里一律 DispatchQueue.main.async 也是这个原因），
//  而 UIKit、AVAudioSession、定时器都要在主线程：入口一律切到主线程，发给应用层的事件也在主线程回调。
//
//  ---- 认证码为什么绕到应用层去换 ----
//  连 asr-api 要带 IM 的认证码，换码接口在 wfc-client 插件里：需要时发 authCodeRequired 事件，
//  应用层用 wfc.getAuthCode 换到后调 provideAuthCode 送回来。认证码 1 分钟有效，每次连接前现换。
//

import AVFoundation
import Foundation
import UIKit

/// 浮层上的文案。默认中文，应用层 configVoiceInput 时按当前语言覆盖（插件读不到 App 的 i18n）
final class VoiceInputTexts {
    var voice = "语音"
    var releaseToSend = "松开 发送"
    var cancel = "取消"
    var releaseToCancel = "松手 取消"
    var slideToText = "滑到这里 转文字"
    var releaseToEdit = "松手 编辑文字"
    var sendVoice = "发送原语音"
    var send = "发送"
    var noText = "未识别到文字"
    var recognizeFailed = "转文字失败"
    /// %d 替换成剩余秒数
    var countDown = "%d 秒后将停止录音"
    var tooShort = "说话时间太短"
    var recordFailed = "录音失败"
}

enum VoiceInputContext {
    private static let tag = "[wfc-voice-input]"

    // MARK: - 日志

    /// index.uts 注入，打印到 HBuilderX 控制台
    static var logger: ((String) -> Void)?

    static func log(_ message: String) {
        NSLog("%@ %@", tag, message)
        logger?("\(tag) \(message)")
    }

    // MARK: - 线程

    static func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - 配置（只在主线程读写）

    /// 实时语音识别地址，asr-api 的 wss://.../asr/api/stream，或内网直连 wf-voice
    static var asrServerUrl = ""
    /// 是否边说边出字
    static var asrPartialResult = true
    /// 当前用户 ID，拼 clientId 用
    static var userId = ""
    /// 气泡颜色，App 主色调
    static var bubbleColor = argbColor(0xFF1F64E4)
    /// 按住说话时是否可以滑到「转文字」
    static var speechToTextEnabled = false
    static var texts = VoiceInputTexts()

    static func applyOptions(_ json: String) {
        guard let data = json.data(using: .utf8),
              let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("parse options failed: \(json)")
            return
        }
        if let value = options["asrServerUrl"] as? String {
            asrServerUrl = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = options["asrPartialResult"] as? Bool {
            asrPartialResult = value
        }
        if let value = options["userId"] as? String {
            userId = value
        }
        if let value = options["bubbleColor"] as? String, let color = parseColor(value) {
            bubbleColor = color
        }
        if let value = options["speechToTextEnabled"] as? Bool {
            speechToTextEnabled = value
        }
        guard let t = options["texts"] as? [String: Any] else {
            return
        }
        func text(_ key: String, _ fallback: String) -> String {
            return t[key] as? String ?? fallback
        }
        let newTexts = VoiceInputTexts()
        newTexts.voice = text("voice", newTexts.voice)
        newTexts.releaseToSend = text("releaseToSend", newTexts.releaseToSend)
        newTexts.cancel = text("cancel", newTexts.cancel)
        newTexts.releaseToCancel = text("releaseToCancel", newTexts.releaseToCancel)
        newTexts.slideToText = text("slideToText", newTexts.slideToText)
        newTexts.releaseToEdit = text("releaseToEdit", newTexts.releaseToEdit)
        newTexts.sendVoice = text("sendVoice", newTexts.sendVoice)
        newTexts.send = text("send", newTexts.send)
        newTexts.noText = text("noText", newTexts.noText)
        newTexts.recognizeFailed = text("recognizeFailed", newTexts.recognizeFailed)
        newTexts.countDown = text("countDown", newTexts.countDown)
        newTexts.tooShort = text("tooShort", newTexts.tooShort)
        newTexts.recordFailed = text("recordFailed", newTexts.recordFailed)
        texts = newTexts
    }

    // MARK: - 事件

    /// 只在主线程读写
    static var eventListener: ((String, String) -> Void)?

    /// 发给应用层的事件。参数只放字符串和数字，序列化成 JSON 数组；在主线程回调
    static func fireEvent(_ event: String, _ args: [Any] = []) {
        runOnMain {
            guard let listener = eventListener else {
                log("no listener, drop event \(event)")
                return
            }
            var argsJson = "[]"
            if let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) {
                argsJson = json
            }
            listener(event, argsJson)
        }
    }

    // MARK: - 认证码

    private static var authCodeRequestSeq = 0
    private static var authCodeRequests: [Int: (success: (String) -> Void, fail: (Int) -> Void)] = [:]

    /// 向应用层要一个认证码。在主线程调用，回调在应用层 provideAuthCode 之后、也在主线程
    static func requestAuthCode(success: @escaping (String) -> Void, fail: @escaping (Int) -> Void) {
        if eventListener == nil {
            fail(-1)
            return
        }
        authCodeRequestSeq += 1
        let requestId = authCodeRequestSeq
        authCodeRequests[requestId] = (success: success, fail: fail)
        fireEvent("authCodeRequired", [requestId])
    }

    /// - Parameters:
    ///   - authCode: 换到的认证码，失败时传空串
    ///   - errorCode: 失败时的错误码
    static func onAuthCodeProvided(_ requestId: Int, _ authCode: String, _ errorCode: Int) {
        runOnMain {
            guard let request = authCodeRequests.removeValue(forKey: requestId) else {
                return
            }
            if authCode.isEmpty {
                request.fail(errorCode)
            } else {
                request.success(authCode)
            }
        }
    }

    // MARK: - 麦克风权限

    static func isMicrophoneGranted() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// 申请麦克风权限，回调在主线程。之前被拒绝过、系统不再弹授权框时，和鸿蒙端一样引导到设置页打开
    static func requestMicrophonePermission(_ callback: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            callback(true)
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            callback(false)
        default:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    callback(granted)
                }
            }
        }
    }

    // MARK: - 窗口

    /// 浮层加在 key window 上：uni-app x 的页面是 window 里的普通视图，窗口级的浮层才能盖住整屏（含导航栏、底部安全区）
    static func keyWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes where scene.activationState == .foregroundActive {
                if let window = scene.windows.first(where: { $0.isKeyWindow }) {
                    return window
                }
            }
            for scene in scenes {
                if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                    return window
                }
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
    }

    // MARK: - 颜色

    static func argbColor(_ argb: UInt32) -> UIColor {
        return UIColor(red: CGFloat((argb >> 16) & 0xFF) / 255,
                       green: CGFloat((argb >> 8) & 0xFF) / 255,
                       blue: CGFloat(argb & 0xFF) / 255,
                       alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    }

    /// #RRGGBB 或 #AARRGGBB，和鸿蒙端一致
    static func parseColor(_ value: String) -> UIColor? {
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 6 {
            hex = "FF" + hex
        }
        guard hex.count == 8, let argb = UInt32(hex, radix: 16) else {
            return nil
        }
        return argbColor(argb)
    }

    /// 气泡上的文字和声波：主色调偏亮用深色，否则用白色（和 Android 的 ColorUtils.calculateLuminance 一致）
    static func contentColor(for color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return .white
        }
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.3 ? argbColor(0xFF191919) : .white
    }

    static func blend(_ from: UIColor, _ to: UIColor, _ fraction: CGFloat) -> UIColor {
        let f = max(0, min(1, fraction))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard from.getRed(&r1, green: &g1, blue: &b1, alpha: &a1), to.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return f < 0.5 ? from : to
        }
        return UIColor(red: r1 + (r2 - r1) * f, green: g1 + (g2 - g1) * f, blue: b1 + (b2 - b1) * f, alpha: a1 + (a2 - a1) * f)
    }
}

// MARK: - 动画小工具

/// 线程安全的布尔值：应用层可能从 JS 线程同步问「是否正在识别」，而状态在主线程改
final class VoiceAtomicFlag {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }
}

/// CADisplayLink 会强引用 target：用一个弱引用的中转对象，持有它的视图释放时不会被拽住
final class VoiceDisplayLink {
    private var link: CADisplayLink?
    private let tick: () -> Void

    /// tick 里要用 [weak self]，否则视图 → VoiceDisplayLink → 闭包 → 视图成环
    init(_ tick: @escaping () -> Void) {
        self.tick = tick
    }

    deinit {
        link?.invalidate()
    }

    func start() {
        if link == nil {
            let newLink = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.onTick))
            newLink.add(to: .main, forMode: .common)
            link = newLink
        }
        link?.isPaused = false
    }

    func pause() {
        link?.isPaused = true
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    private final class Proxy: NSObject {
        weak var owner: VoiceDisplayLink?

        init(_ owner: VoiceDisplayLink) {
            self.owner = owner
        }

        @objc func onTick() {
            owner?.tick()
        }
    }
}

/// 缓动曲线，和 Android 端用的插值器对应
enum VoiceEasing {
    static func linear(_ t: CGFloat) -> CGFloat {
        return t
    }

    /// DecelerateInterpolator(factor)
    static func decelerate(_ factor: CGFloat) -> (CGFloat) -> CGFloat {
        return { t in 1 - pow(1 - t, 2 * factor) }
    }

    /// AccelerateInterpolator(factor)
    static func accelerate(_ factor: CGFloat) -> (CGFloat) -> CGFloat {
        return { t in pow(t, 2 * factor) }
    }

    /// OvershootInterpolator(tension)
    static func overshoot(_ tension: CGFloat) -> (CGFloat) -> CGFloat {
        return { t in
            let s = t - 1
            return s * s * ((tension + 1) * s + tension) + 1
        }
    }

    /// PathInterpolator(0.2, 0, 0, 1)，Material 的 fast-out-slow-in 加强版
    static func fastOutSlowIn(_ t: CGFloat) -> CGFloat {
        return cubicBezier(0.2, 0, 0, 1, t)
    }

    /// 三次贝塞尔缓动：先按 x 二分出参数，再求 y
    static func cubicBezier(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat) -> CGFloat {
        if x <= 0 {
            return 0
        }
        if x >= 1 {
            return 1
        }
        func bezier(_ p1: CGFloat, _ p2: CGFloat, _ s: CGFloat) -> CGFloat {
            let inv = 1 - s
            return 3 * inv * inv * s * p1 + 3 * inv * s * s * p2 + s * s * s
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        var s: CGFloat = x
        for _ in 0..<24 {
            let value = bezier(x1, x2, s)
            if abs(value - x) < 0.0005 {
                break
            }
            if value < x {
                low = s
            } else {
                high = s
            }
            s = (low + high) / 2
        }
        return bezier(y1, y2, s)
    }
}

/// 一个数值从当前值平滑过渡到目标值，由 display link 逐帧 update
struct VoiceTween {
    private(set) var value: CGFloat
    private(set) var running = false
    private var from: CGFloat = 0
    private var to: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var delay: CFTimeInterval = 0
    private var easing: (CGFloat) -> CGFloat = VoiceEasing.linear

    init(_ value: CGFloat) {
        self.value = value
    }

    mutating func set(_ newValue: CGFloat) {
        value = newValue
        running = false
    }

    mutating func animate(to target: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval = 0, easing: @escaping (CGFloat) -> CGFloat) {
        from = value
        to = target
        startTime = CACurrentMediaTime()
        self.duration = max(0.001, duration)
        self.delay = delay
        self.easing = easing
        running = true
    }

    /// - Returns: 这一帧是否还在动画中
    mutating func update(_ now: CFTimeInterval) -> Bool {
        if !running {
            return false
        }
        let elapsed = now - startTime - delay
        if elapsed < 0 {
            return true
        }
        let fraction = CGFloat(min(1, elapsed / duration))
        value = from + (to - from) * easing(fraction)
        if fraction >= 1 {
            value = to
            running = false
        }
        return true
    }
}
