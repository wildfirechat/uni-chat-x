/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

/**
 * index.uts 调用的入口，把输入框语音输入（AsrManager）和按住说话（AudioRecorderPanel）的回调转成事件。
 *
 * 为什么是 .ets：浮层要用 @Builder / @ComponentV2，AsrManager 等又是从 hm-chat 原样移植的 ArkTS，
 * 放在 .ets 里直接互相引用最省事；uts 可以直接调用同目录 .ets 里导出的函数（同 wfc-av-client 的 videoBuilder.ets）。
 */

import { common } from '@kit.AbilityKit'
import AsrManager from './AsrManager'
import AudioRecorderPanel from './AudioRecorderPanel'
import {
    applyVoiceInputOptions,
    fireVoiceInputEvent,
    isMicrophoneGranted,
    onAuthCodeProvided,
    requestMicrophonePermission,
    setVoiceInputEventListener,
    VoiceInputEventListener
} from './VoiceInputContext'

function abilityContext(): common.UIAbilityContext {
    return getContext() as common.UIAbilityContext
}

export function voiceInputSetListener(listener: VoiceInputEventListener) {
    setVoiceInputEventListener(listener)
}

export function voiceInputConfigure(optionsJson: string) {
    applyVoiceInputOptions(optionsJson)
}

export function voiceInputProvideAuthCode(requestId: number, authCode: string, errorCode: number) {
    onAuthCodeProvided(requestId, authCode, errorCode)
}

// region 输入框语音输入

let asrManager: AsrManager | undefined = undefined
// 正在申请麦克风权限
let asrRequestingPermission: boolean = false
// 每次开始 / 取消加 1，申请权限回来时据此判断期间是否已经取消
let asrStartToken: number = 0

function startAsrNow() {
    const manager: AsrManager = asrManager ?? new AsrManager()
    asrManager = manager
    manager.startRecognition({
        onPartialResult: (text: string) => {
            fireVoiceInputEvent('asrPartial', [text])
        },
        onFinalResult: (text: string) => {
            fireVoiceInputEvent('asrFinal', [text])
        },
        onError: (message: string) => {
            fireVoiceInputEvent('asrError', [message])
        }
    })
}

export function voiceInputStartAsr() {
    if (voiceInputIsAsrRecognizing()) {
        return
    }
    asrStartToken++
    const token: number = asrStartToken
    const context: common.UIAbilityContext = abilityContext()
    if (isMicrophoneGranted(context)) {
        startAsrNow()
        return
    }
    asrRequestingPermission = true
    requestMicrophonePermission(context).then((granted: boolean) => {
        if (token !== asrStartToken) {
            // 申请权限期间已经取消了
            return
        }
        asrRequestingPermission = false
        if (granted) {
            startAsrNow()
        } else {
            fireVoiceInputEvent('asrPermissionDenied', [])
        }
    })
}

export function voiceInputStopAsr() {
    if (asrRequestingPermission) {
        voiceInputCancelAsr()
        return
    }
    asrManager?.stopRecognition()
}

export function voiceInputCancelAsr() {
    asrStartToken++
    asrRequestingPermission = false
    asrManager?.cancelRecognition()
}

/**
 * 是否正在识别，包括申请权限、停止录音后等待剩余识别结果的阶段
 */
export function voiceInputIsAsrRecognizing(): boolean {
    return asrRequestingPermission || (asrManager !== undefined && asrManager.isRecognizing())
}

// endregion

// region 按住说话

let panel: AudioRecorderPanel | undefined = undefined

function ensurePanel(): AudioRecorderPanel {
    if (panel) {
        return panel
    }
    const created: AudioRecorderPanel = new AudioRecorderPanel(abilityContext(), {
        onRecordSuccess: (audioFile: string, duration: number) => {
            fireVoiceInputEvent('holdRecordSuccess', [audioFile, duration])
        },
        onRecordFail: (reason: string) => {
            fireVoiceInputEvent('holdRecordFail', [reason])
        },
        onSendText: (text: string) => {
            fireVoiceInputEvent('holdSendText', [text])
        },
        onPermissionDenied: () => {
            fireVoiceInputEvent('holdPermissionDenied', [])
        }
    })
    panel = created
    return created
}

export function voiceInputHoldTouchDown(x: number, y: number, buttonTop: number) {
    ensurePanel().onTouchDown(x, y, buttonTop)
}

export function voiceInputHoldTouchMove(x: number, y: number) {
    panel?.onTouchMove(x, y)
}

export function voiceInputHoldTouchUp() {
    panel?.onTouchUp()
}

/**
 * 录音入口销毁时调用：立即关闭浮层，停止录音和识别，不回调
 */
export function voiceInputDismissHold() {
    panel?.release()
}

// endregion
