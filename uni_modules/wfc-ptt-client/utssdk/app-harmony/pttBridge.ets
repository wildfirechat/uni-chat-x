/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

/**
 * 对讲插件（鸿蒙）的实现，index.uts 只做转发。
 *
 * ## 收消息
 *
 * SDK 在 init 时往 wfc.eventEmitter 上挂 EventType.ReceiveMessage 监听，但本项目的消息是 UTS 侧 wfc.uts 收到的：
 * wfc.uts → EventType.ReceiveProtoMessages → wfc/ptt/pttClient.uts → 插件 dispatchReceivedMessages()
 * → pttDispatchProtoMessages 解码后 emit 到 wfc.eventEmitter。
 * wfc.eventEmitter 是 @wfc/client 适配层自己的 emitter，不是 ability 的 eventHub，见 harmony-configs/wfcclient/README.md。
 *
 * ## 事件
 *
 * SDK 把谁开始/结束说话、收听音量 emit 到 init 时传入的 eventHub（这里给的是 UIAbility 的），
 * 在这里订阅后转成和 Android 插件一样的 (event, conversationJson, argsJson) 发给应用层。
 */

import { common } from '@kit.AbilityKit'
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl'
import { BusinessError } from '@kit.BasicServicesKit'
import audio from '@ohos.multimedia.audio'
import pttClient, { PttConfig, PttErrorCode, PttEventType, PttMessageContentType, TalkingCallback } from '@wfc/ptt'
import wfc from '@wfc/client'
import EventType from '@wfc/client/src/main/ets/wfc/client/wfcEvent'
import Conversation from '@wfc/client/src/main/ets/wfc/model/conversation'
import Message from '@wfc/client/src/main/ets/wfc/messages/message'

const TAG = 'wfc-ptt-harmony'

const MICROPHONE: Permissions = 'ohos.permission.MICROPHONE'

// SDK 一次收到超过这么多条消息，就认为是在同步历史、整批忽略（pttClient.ets 的 MAX_REALTIME_MESSAGE_COUNT）。
// 这里按原始条数先判断：既省掉解码，也避免滤掉其他消息之后，把本该整批忽略的对讲数据喂进去
const MAX_REALTIME_MESSAGE_COUNT = 10

export type PttEventListener = (event: string, conversationJson: string, argsJson: string) => void

interface ConversationJson {
    type: number
    target: string
    line: number
}

// 字段和 app-android/index.uts#initClient 一致；save 在鸿蒙 SDK 的 PttConfig 里叫 SEND
interface PttOptions {
    enableFullDuplex?: boolean
    enableGlobalPtt?: boolean
    enablePriorityMode?: boolean
    singleChatMaxSpeakerCount?: number
    groupChatMaxSpeakerCount?: number
    singleChatSaveVoiceMessage?: boolean
    groupChatSaveVoiceMessage?: boolean
    singleChatMaxSpeakTime?: number
    groupChatMaxSpeakTime?: number
}

let eventListener: PttEventListener | undefined = undefined
let initialized = false

function conversationOf(type: number, target: string, line: number): Conversation {
    return new Conversation(type, target, line)
}

function fireEvent(event: string, conversation: Conversation, args: Array<string | number>) {
    const listener = eventListener
    if (!listener) {
        return
    }
    const conv: ConversationJson = { type: conversation.type, target: conversation.target, line: conversation.line }
    listener(event, JSON.stringify(conv), JSON.stringify(args))
}

export function pttSetEventListener(listener: PttEventListener) {
    eventListener = listener
}

export function pttInit(optionsJson: string) {
    let options: PttOptions = {}
    try {
        options = JSON.parse(optionsJson) as PttOptions
    } catch (e) {
        console.error(TAG, 'parse options failed', optionsJson)
    }
    PttConfig.ENABLE_FULL_DUPLEX = options.enableFullDuplex ?? PttConfig.ENABLE_FULL_DUPLEX
    PttConfig.ENABLE_GLOBAL_PTT = options.enableGlobalPtt ?? PttConfig.ENABLE_GLOBAL_PTT
    PttConfig.ENABLE_PRIORITY_MODE = options.enablePriorityMode ?? PttConfig.ENABLE_PRIORITY_MODE
    PttConfig.SINGLE_CHAT_MAX_SPEAKER_COUNT = options.singleChatMaxSpeakerCount ?? PttConfig.SINGLE_CHAT_MAX_SPEAKER_COUNT
    PttConfig.GROUP_CHAT_MAX_SPEAKER_COUNT = options.groupChatMaxSpeakerCount ?? PttConfig.GROUP_CHAT_MAX_SPEAKER_COUNT
    PttConfig.SINGLE_CHAT_SEND_VOICE_MESSAGE =
        options.singleChatSaveVoiceMessage ?? PttConfig.SINGLE_CHAT_SEND_VOICE_MESSAGE
    PttConfig.GROUP_CHAT_SEND_VOICE_MESSAGE =
        options.groupChatSaveVoiceMessage ?? PttConfig.GROUP_CHAT_SEND_VOICE_MESSAGE
    PttConfig.SINGLE_CHAT_MAX_SPEAK_TIME = options.singleChatMaxSpeakTime ?? PttConfig.SINGLE_CHAT_MAX_SPEAK_TIME
    PttConfig.GROUP_CHAT_MAX_SPEAK_TIME = options.groupChatMaxSpeakTime ?? PttConfig.GROUP_CHAT_MAX_SPEAK_TIME
    if (initialized) {
        return
    }

    const context = getContext() as common.UIAbilityContext
    const eventHub = context.eventHub
    // context 用来取 cacheDir，留底语音消息的临时 amr 文件放在那里
    pttClient.init(context, eventHub)
    initialized = true

    eventHub.on(PttEventType.userStartTalking, (conversation: Conversation, userId: string) => {
        fireEvent('userStartTalking', conversation, [userId])
    })
    eventHub.on(PttEventType.userEndTalking, (conversation: Conversation, userId: string) => {
        fireEvent('userEndTalking', conversation, [userId])
    })
    eventHub.on(PttEventType.receiveData, (conversation: Conversation, userId: string, data: string) => {
        fireEvent('receiveData', conversation, [userId, data])
    })
    eventHub.on(PttEventType.userAmplitudeUpdate, (conversation: Conversation, userId: string, amplitude: number) => {
        fireEvent('userAmplitudeUpdate', conversation, [userId, amplitude])
    })
}

/**
 * @param messagesJson UTS 侧 wfc.uts 收到的原始 proto 消息，JSON 数组
 */
export function pttDispatchProtoMessages(messagesJson: string, hasMore: boolean) {
    if (!initialized || !messagesJson) {
        return
    }
    let arr: Record<string, Object>[]
    try {
        arr = JSON.parse(messagesJson) as Record<string, Object>[]
    } catch (e) {
        console.error(TAG, 'parse proto messages failed', JSON.stringify(e))
        return
    }
    if (!arr || arr.length === 0 || arr.length > MAX_REALTIME_MESSAGE_COUNT) {
        return
    }
    const msgs: Message[] = []
    for (const obj of arr) {
        const payload = obj.content as Record<string, Object>
        if (!payload) {
            continue
        }
        // 留底语音（23）是普通的存储消息，SDK 收听时不处理，由 UTS 侧当语音消息显示
        const type = payload.type as number
        if (type !== PttMessageContentType.Ptt_Sound_Data && type !== PttMessageContentType.Ptt_Start
            && type !== PttMessageContentType.Ptt_End) {
            continue
        }
        const msg = Message.fromProtoMessage(obj)
        if (msg) {
            msgs.push(msg)
        }
    }
    if (msgs.length > 0) {
        wfc.eventEmitter.emit(EventType.ReceiveMessage, msgs, hasMore)
    }
}

class BridgeTalkingCallback extends TalkingCallback {
    private priority: number
    private onStart: () => void
    private onEnd: (reason: number) => void
    private onFail: (errorCode: number) => void
    private onAmplitude: (amplitude: number) => void

    constructor(priority: number, onStart: () => void, onEnd: (reason: number) => void,
        onFail: (errorCode: number) => void, onAmplitude: (amplitude: number) => void) {
        super()
        this.priority = priority
        this.onStart = onStart
        this.onEnd = onEnd
        this.onFail = onFail
        this.onAmplitude = onAmplitude
    }

    talkingPriority(conversation: Conversation): number {
        return this.priority
    }

    onStartTalking(conversation: Conversation): void {
        this.onStart()
    }

    onTalkingEnd(conversation: Conversation, reason: number): void {
        this.onEnd(reason)
    }

    onRequestFail(conversation: Conversation, errorCode: number): void {
        this.onFail(errorCode)
    }

    onAmplitudeUpdate(conversation: Conversation, averageAmplitude: number): void {
        this.onAmplitude(averageAmplitude)
    }
}

export function pttRequestTalk(type: number, target: string, line: number, priority: number, onStart: () => void,
    onEnd: (reason: number) => void, onFail: (errorCode: number) => void, onAmplitude: (amplitude: number) => void) {
    if (!pttClient.isInitialized()) {
        // SDK 没初始化时 requestTalk 只打日志、不回调，界面会一直停在「正在请求」
        onFail(PttErrorCode.UNKNOWN)
        return
    }
    pttClient.requestTalk(conversationOf(type, target, line),
        new BridgeTalkingCallback(priority, onStart, onEnd, onFail, onAmplitude))
}

export function pttReleaseTalk(type: number, target: string, line: number) {
    pttClient.releaseTalk(conversationOf(type, target, line))
}

export function pttGetMaxSpeakCount(type: number, target: string, line: number): number {
    return pttClient.getMaxSpeakCount(conversationOf(type, target, line))
}

export function pttGetMaxSpeakTime(type: number, target: string, line: number): number {
    return pttClient.getMaxSpeakTime(conversationOf(type, target, line))
}

export function pttIsSaveVoiceMessage(type: number, target: string, line: number): boolean {
    return pttClient.isSendVoiceMessage(conversationOf(type, target, line))
}

export function pttSetSaveVoiceMessage(type: number, target: string, line: number, save: boolean, success: () => void,
    fail: (error: number) => void) {
    pttClient.setSendVoiceMessage(conversationOf(type, target, line), save, success, fail)
}

export function pttSetConversationMaxSpeakTime(type: number, target: string, line: number, duration: number,
    success: () => void, fail: (error: number) => void) {
    pttClient.setConversationMaxSpeakTime(conversationOf(type, target, line), duration, success, fail)
}

export function pttSetConversationMaxSpeakerCount(type: number, target: string, line: number, count: number,
    success: () => void, fail: (error: number) => void) {
    pttClient.setConversationMaxSpeakerCount(conversationOf(type, target, line), count, success, fail)
}

export function pttSetConversationPttSilent(type: number, target: string, line: number, silent: boolean,
    success: () => void, fail: (error: number) => void) {
    pttClient.setConversationPttSilent(conversationOf(type, target, line), silent, success, fail)
}

export function pttIsConversationPttSilent(type: number, target: string, line: number): boolean {
    return pttClient.isConversationPttSilent(conversationOf(type, target, line))
}

export function pttGetTalkingStartTime(): number {
    return pttClient.getTalkingStartTime()
}

/**
 * @returns 正在说话的用户 ID，JSON 数组
 */
export function pttGetTalkingMembers(type: number, target: string, line: number): string {
    return JSON.stringify(pttClient.getTalkingMembers(conversationOf(type, target, line)))
}

export function pttGetTalkingMemberCount(type: number, target: string, line: number): number {
    return pttClient.getTalkingMemberCount(conversationOf(type, target, line))
}

export function pttSetEnablePtt(type: number, target: string, line: number, enable: boolean) {
    pttClient.setEnablePtt(conversationOf(type, target, line), enable)
}

// region 麦克风权限，和 wfc-voice-input 插件一致

export function pttIsRecordPermissionGranted(): boolean {
    try {
        const context = getContext() as common.UIAbilityContext
        const status = abilityAccessCtrl.createAtManager()
            .checkAccessTokenSync(context.applicationInfo.accessTokenId, MICROPHONE)
        return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    } catch (e) {
        const err = e as BusinessError
        console.error(TAG, `checkAccessTokenSync failed, code ${err.code}, message ${err.message}`)
        return false
    }
}

/**
 * 申请麦克风权限。之前被拒绝过、系统不再弹授权框时，引导到设置页打开
 */
export function pttRequestRecordPermission(success: () => void, fail: () => void) {
    requestMicrophonePermission(getContext() as common.UIAbilityContext).then((granted: boolean) => {
        if (granted) {
            success()
        } else {
            fail()
        }
    })
}

async function requestMicrophonePermission(context: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager()
    try {
        const result = await atManager.requestPermissionsFromUser(context, [MICROPHONE])
        if (result.authResults.length > 0 && result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
            return true
        }
        const shown = result.dialogShownResults
        if (shown && shown.length > 0 && shown[0] === false) {
            const statusList = await atManager.requestPermissionOnSetting(context, [MICROPHONE])
            return statusList.length > 0 && statusList[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
        }
        return false
    } catch (e) {
        const err = e as BusinessError
        console.error(TAG, `request microphone permission failed, code ${err.code}, message ${err.message}`)
        return false
    }
}

// endregion

// region 扬声器。SDK 播放用的是 STREAM_USAGE_VOICE_COMMUNICATION，走通话设备路由

export function pttIsSpeakerEnable(): boolean {
    try {
        return audio.getAudioManager().getRoutingManager()
            .isCommunicationDeviceActiveSync(audio.CommunicationDeviceType.SPEAKER)
    } catch (e) {
        const err = e as BusinessError
        console.error(TAG, `isCommunicationDeviceActiveSync failed, code ${err.code}, message ${err.message}`)
        return false
    }
}

export function pttEnableSpeaker() {
    audio.getAudioManager().getRoutingManager()
        .setCommunicationDevice(audio.CommunicationDeviceType.SPEAKER, true)
        .catch((err: BusinessError) => {
            console.error(TAG, 'setCommunicationDevice failed', err.code, err.message)
        })
}

// endregion
