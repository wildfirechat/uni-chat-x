/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

/**
 * 插件内共用的配置、事件出口、认证码请求和麦克风权限。
 *
 * 不依赖 AsrManager / AudioRecorderPanel，它们都 import 这里，避免循环引用。
 *
 * ## 认证码为什么绕到应用层去换
 *
 * 连 asr-api 要带 IM 的认证码（appId 'admin'、type 2），换码接口在 wfc-client 插件里。
 * 本插件不直接依赖 IM SDK，需要时发 authCodeRequired 事件，应用层用 wfc.getAuthCode 换到后
 * 调 provideAuthCode 送回来。认证码 1 分钟有效，所以每次连接前现换，不缓存。
 */

import { common } from '@kit.AbilityKit'
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl'
import { BusinessError } from '@kit.BasicServicesKit'

const TAG = 'wfc-voice-input'

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE'

export type VoiceInputEventListener = (event: string, argsJson: string) => void

/**
 * 浮层上的文案。默认中文，应用层 configVoiceInput 时按当前语言覆盖（插件读不到 App 的 i18n）
 */
export class VoiceInputTexts {
    voice: string = '语音'
    releaseToSend: string = '松开 发送'
    cancel: string = '取消'
    releaseToCancel: string = '松手 取消'
    slideToText: string = '滑到这里 转文字'
    releaseToEdit: string = '松手 编辑文字'
    sendVoice: string = '发送原语音'
    send: string = '发送'
    noText: string = '未识别到文字'
    recognizeFailed: string = '转文字失败'
    // %d 替换成剩余秒数
    countDown: string = '%d 秒后将停止录音'
    tooShort: string = '说话时间太短'
    recordFailed: string = '录音失败'
}

interface VoiceInputTextsOptions {
    voice?: string
    releaseToSend?: string
    cancel?: string
    releaseToCancel?: string
    slideToText?: string
    releaseToEdit?: string
    sendVoice?: string
    send?: string
    noText?: string
    recognizeFailed?: string
    countDown?: string
    tooShort?: string
    recordFailed?: string
}

interface VoiceInputOptions {
    asrServerUrl?: string
    asrPartialResult?: boolean
    userId?: string
    // #RRGGBB 或 #AARRGGBB
    bubbleColor?: string
    speechToTextEnabled?: boolean
    texts?: VoiceInputTextsOptions
}

export class VoiceInputConfig {
    // 实时语音识别地址，asr-api 的 wss://.../asr/api/stream，或内网直连 wf-voice
    asrServerUrl: string = ''
    // 是否边说边出字
    asrPartialResult: boolean = true
    // 当前用户 ID，拼 clientId 用
    userId: string = ''
    // 气泡颜色，ARGB
    bubbleColor: number = 0xFF1F64E4
    // 按住说话时是否可以滑到「转文字」
    speechToTextEnabled: boolean = false
    texts: VoiceInputTexts = new VoiceInputTexts()
}

export const voiceInputConfig: VoiceInputConfig = new VoiceInputConfig()

function parseColor(value: string | undefined, fallback: number): number {
    if (!value) {
        return fallback
    }
    let hex = value.startsWith('#') ? value.substring(1) : value
    if (hex.length === 6) {
        hex = 'FF' + hex
    }
    if (hex.length !== 8) {
        return fallback
    }
    let color = parseInt(hex, 16)
    return isNaN(color) ? fallback : (color >>> 0)
}

export function applyVoiceInputOptions(json: string) {
    let options: VoiceInputOptions
    try {
        options = JSON.parse(json) as VoiceInputOptions
    } catch (e) {
        console.error(TAG, 'parse options failed', json)
        return
    }
    let config = voiceInputConfig
    config.asrServerUrl = (options.asrServerUrl ?? config.asrServerUrl).trim()
    config.asrPartialResult = options.asrPartialResult ?? config.asrPartialResult
    config.userId = options.userId ?? config.userId
    config.bubbleColor = parseColor(options.bubbleColor, config.bubbleColor)
    config.speechToTextEnabled = options.speechToTextEnabled ?? config.speechToTextEnabled
    let texts = options.texts
    if (texts) {
        let t = new VoiceInputTexts()
        t.voice = texts.voice ?? t.voice
        t.releaseToSend = texts.releaseToSend ?? t.releaseToSend
        t.cancel = texts.cancel ?? t.cancel
        t.releaseToCancel = texts.releaseToCancel ?? t.releaseToCancel
        t.slideToText = texts.slideToText ?? t.slideToText
        t.releaseToEdit = texts.releaseToEdit ?? t.releaseToEdit
        t.sendVoice = texts.sendVoice ?? t.sendVoice
        t.send = texts.send ?? t.send
        t.noText = texts.noText ?? t.noText
        t.recognizeFailed = texts.recognizeFailed ?? t.recognizeFailed
        t.countDown = texts.countDown ?? t.countDown
        t.tooShort = texts.tooShort ?? t.tooShort
        t.recordFailed = texts.recordFailed ?? t.recordFailed
        config.texts = t
    }
}

// region 事件

let eventListener: VoiceInputEventListener | undefined = undefined

export function setVoiceInputEventListener(listener: VoiceInputEventListener) {
    eventListener = listener
}

/**
 * 发给应用层的事件。参数只放字符串和数字，序列化成 JSON 数组
 */
export function fireVoiceInputEvent(event: string, args: Array<string | number>) {
    let listener = eventListener
    if (!listener) {
        console.warn(TAG, 'no listener, drop event', event)
        return
    }
    let argsJson = '[]'
    try {
        argsJson = JSON.stringify(args)
    } catch (e) {
        console.error(TAG, 'stringify event args failed', event)
        return
    }
    listener(event, argsJson)
}

// endregion

// region 认证码

class AuthCodeRequest {
    success: (authCode: string) => void
    fail: (errorCode: number) => void

    constructor(success: (authCode: string) => void, fail: (errorCode: number) => void) {
        this.success = success
        this.fail = fail
    }
}

let authCodeRequestSeq = 0
const authCodeRequests: Map<number, AuthCodeRequest> = new Map<number, AuthCodeRequest>()

/**
 * 向应用层要一个认证码，回调在应用层 provideAuthCode 之后触发
 */
export function requestAuthCode(success: (authCode: string) => void, fail: (errorCode: number) => void) {
    if (!eventListener) {
        fail(-1)
        return
    }
    authCodeRequestSeq++
    let requestId = authCodeRequestSeq
    authCodeRequests.set(requestId, new AuthCodeRequest(success, fail))
    fireVoiceInputEvent('authCodeRequired', [requestId])
}

/**
 * @param authCode  换到的认证码，失败时传空串
 * @param errorCode 失败时的错误码
 */
export function onAuthCodeProvided(requestId: number, authCode: string, errorCode: number) {
    let request = authCodeRequests.get(requestId)
    if (!request) {
        return
    }
    authCodeRequests.delete(requestId)
    if (authCode.length > 0) {
        request.success(authCode)
    } else {
        request.fail(errorCode)
    }
}

// endregion

// region 麦克风权限

export function isMicrophoneGranted(context: common.Context): boolean {
    try {
        let tokenId = context.applicationInfo.accessTokenId
        let status = abilityAccessCtrl.createAtManager().checkAccessTokenSync(tokenId, MICROPHONE)
        return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    } catch (e) {
        let err = e as BusinessError
        console.error(TAG, `checkAccessTokenSync failed, code ${err.code}, message ${err.message}`)
        return false
    }
}

/**
 * 申请麦克风权限。之前被拒绝过、系统不再弹授权框时，引导到设置页打开
 */
export async function requestMicrophonePermission(context: common.UIAbilityContext): Promise<boolean> {
    let atManager = abilityAccessCtrl.createAtManager()
    try {
        let result = await atManager.requestPermissionsFromUser(context, [MICROPHONE])
        if (result.authResults.length > 0 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            return true
        }
        let shown = result.dialogShownResults
        if (shown && shown.length > 0 && shown[0] === false) {
            let statusList = await atManager.requestPermissionOnSetting(context, [MICROPHONE])
            return statusList.length > 0 && statusList[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
        }
        return false
    } catch (e) {
        let err = e as BusinessError
        console.error(TAG, `request microphone permission failed, code ${err.code}, message ${err.message}`)
        return false
    }
}

// endregion
