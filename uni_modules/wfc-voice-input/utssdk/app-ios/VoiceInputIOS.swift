//
//  VoiceInputIOS.swift
//  wfc-voice-input 插件 iOS 端
//
//  index.uts 调用的入口，把输入框语音输入（VoiceAsrManager）和按住说话（VoiceHoldPanel）的回调转成事件，
//  对应鸿蒙端的 voiceInput.ets、Android 端的 VoiceInputAndroid.kt。
//
//  所有入口都先切到主线程（原因见 VoiceInputSupport.swift 文件头）；只有 isAsrRecognizing 要同步返回，读的是加锁的标志位。
//  uts 的 number 到了 Swift 是 NSNumber，参数就按 NSNumber 收。
//  这里的类名、方法名不要和 index.uts 里的函数重名：DCloud 的混编文档说符号冲突会编译不过。
//

import Foundation
import UIKit

public class VoiceInputIOS: NSObject {

    /// 实时识别用的 URLSessionWebSocketTask 要 iOS 13，更老的系统应用层回退到原来的录音交互
    public static func isSupported() -> Bool {
        if #available(iOS 13.0, *) {
            return true
        }
        return false
    }

    /// - Parameter logger: 打印到 HBuilderX 控制台（uts 的 console.log）
    public static func setup(_ logger: @escaping (String) -> Void) {
        VoiceInputContext.logger = logger
    }

    public static func setListener(_ listener: @escaping (String, String) -> Void) {
        VoiceInputContext.runOnMain {
            VoiceInputContext.eventListener = listener
        }
    }

    /// - Parameter optionsJson: { asrServerUrl, asrPartialResult, userId, bubbleColor, speechToTextEnabled, texts }
    public static func configure(_ optionsJson: String) {
        VoiceInputContext.runOnMain {
            VoiceInputContext.applyOptions(optionsJson)
        }
    }

    /// 回应 authCodeRequired 事件。换码失败时 authCode 传空串、errorCode 传错误码
    public static func provideAuthCode(_ requestId: NSNumber, _ authCode: String, _ errorCode: NSNumber) {
        VoiceInputContext.onAuthCodeProvided(requestId.intValue, authCode, errorCode.intValue)
    }

    // MARK: - 输入框语音输入

    public static func startAsr() {
        guard #available(iOS 13.0, *) else {
            VoiceInputContext.fireEvent("asrError", ["当前系统版本不支持实时语音识别"])
            return
        }
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.startAsr()
        }
    }

    public static func stopAsr() {
        guard #available(iOS 13.0, *) else {
            return
        }
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.stopAsr()
        }
    }

    public static func cancelAsr() {
        guard #available(iOS 13.0, *) else {
            return
        }
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.cancelAsr()
        }
    }

    /// 是否正在识别，包括申请权限、停止录音后等待剩余识别结果的阶段。可能在 JS 线程调用
    public static func isAsrRecognizing() -> Bool {
        guard #available(iOS 13.0, *) else {
            return false
        }
        return VoiceInputController.shared.isAsrRecognizing
    }

    // MARK: - 按住说话

    /// 按住说话按钮的触摸转发，坐标是屏幕坐标（pt，即 uni-app x 的逻辑像素）
    public static func holdTouchDown(_ x: NSNumber, _ y: NSNumber, _ buttonTop: NSNumber) {
        guard #available(iOS 13.0, *) else {
            return
        }
        let point = CGPoint(x: x.doubleValue, y: y.doubleValue)
        let top = CGFloat(buttonTop.doubleValue)
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.holdTouchDown(point, buttonTop: top)
        }
    }

    public static func holdTouchMove(_ x: NSNumber, _ y: NSNumber) {
        guard #available(iOS 13.0, *) else {
            return
        }
        let point = CGPoint(x: x.doubleValue, y: y.doubleValue)
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.holdTouchMove(point)
        }
    }

    public static func holdTouchUp() {
        guard #available(iOS 13.0, *) else {
            return
        }
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.holdTouchUp()
        }
    }

    /// 录音入口销毁时调用：立即关闭浮层，停止录音和识别，不回调
    public static func dismissHold() {
        guard #available(iOS 13.0, *) else {
            return
        }
        VoiceInputContext.runOnMain {
            VoiceInputController.shared.dismissHold()
        }
    }
}

@available(iOS 13.0, *)
final class VoiceInputController {
    static let shared = VoiceInputController()

    // 输入框语音输入只用这一个实例、不替换：isAsrRecognizing 会在 JS 线程读它
    private let asrManager = VoiceAsrManager()
    // 正在申请麦克风权限
    private let requestingPermission = VoiceAtomicFlag()
    // 每次开始 / 取消加 1，申请权限回来时据此判断期间是否已经取消
    private var asrStartToken = 0
    private var panel: VoiceHoldPanel?

    var isAsrRecognizing: Bool {
        return requestingPermission.value || asrManager.isRecognizing
    }

    // MARK: - 输入框语音输入

    func startAsr() {
        if isAsrRecognizing {
            return
        }
        asrStartToken += 1
        let token = asrStartToken
        if VoiceInputContext.isMicrophoneGranted() {
            startAsrNow()
            return
        }
        requestingPermission.value = true
        VoiceInputContext.requestMicrophonePermission { [weak self] granted in
            // token 变了说明申请权限期间已经取消了
            guard let self = self, token == self.asrStartToken else {
                return
            }
            self.requestingPermission.value = false
            if granted {
                self.startAsrNow()
            } else {
                VoiceInputContext.fireEvent("asrPermissionDenied")
            }
        }
    }

    private func startAsrNow() {
        asrManager.startRecognition(VoiceAsrManager.Callbacks(
            onPartialResult: { text in
                VoiceInputContext.fireEvent("asrPartial", [text])
            },
            onFinalResult: { text in
                VoiceInputContext.fireEvent("asrFinal", [text])
            },
            onError: { message in
                VoiceInputContext.fireEvent("asrError", [message])
            }
        ))
    }

    func stopAsr() {
        if requestingPermission.value {
            cancelAsr()
        } else {
            asrManager.stopRecognition()
        }
    }

    func cancelAsr() {
        asrStartToken += 1
        requestingPermission.value = false
        asrManager.cancelRecognition()
    }

    // MARK: - 按住说话

    func holdTouchDown(_ point: CGPoint, buttonTop: CGFloat) {
        holdPanel().onTouchDown(point, buttonTop: buttonTop)
    }

    func holdTouchMove(_ point: CGPoint) {
        panel?.onTouchMove(point)
    }

    func holdTouchUp() {
        panel?.onTouchUp()
    }

    func dismissHold() {
        panel?.release()
    }

    private func holdPanel() -> VoiceHoldPanel {
        if let existing = panel {
            return existing
        }
        let created = VoiceHoldPanel(listener: VoiceHoldPanel.Listener(
            onRecordSuccess: { audioFile, duration in
                VoiceInputContext.fireEvent("holdRecordSuccess", [audioFile, duration])
            },
            onRecordFail: { reason in
                VoiceInputContext.fireEvent("holdRecordFail", [reason])
            },
            onSendText: { text in
                VoiceInputContext.fireEvent("holdSendText", [text])
            },
            onPermissionDenied: {
                VoiceInputContext.fireEvent("holdPermissionDenied")
            }
        ))
        panel = created
        return created
    }
}
