/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

/*
 * 移植自 ../hm-chat uikit/src/main/ets/asr/AsrManager.ets，两处按 ../android-chat 的 AsrManager.java 对齐：
 * 1. 自己录音时，点完立即开始录音，换认证码、连接期间的音频先缓存，连上后补发（hm-chat 是连上才开始录，
 *    头一两秒说的话会丢）；
 * 2. 等待剩余识别结果的超时用 android 最新的值（10s / 15s / 60s，见 android-chat 31fae307）。
 * 另外去掉了没有任何入口开启的 "Over" 热词。服务地址、边说边出字、userId 从 VoiceInputContext 读，
 * 认证码由应用层提供。
 */

import { util } from '@kit.ArkTS'
import url from '@ohos.url'
import AsrWebSocketClient from './AsrWebSocketClient'
import PcmAudioRecorder from './PcmAudioRecorder'
import { requestAuthCode, voiceInputConfig } from './VoiceInputContext'

const TAG = 'AsrManager'

const MAX_RECORDING_DURATION_MS = 60 * 1000  // 最长录音时长：60秒
const WAIT_EOS_TIMEOUT_MS = 10 * 1000        // 停止录音后等待剩余识别结果的最长时间：10秒
// 停止录音后服务端一直没有推送消息，认为已经识别完。服务端不支持 eos 指令时不会回复 [EOS]，靠它结束识别
const WAIT_EOS_IDLE_TIMEOUT_MS = 15 * 1000
// 停止录音后收到过识别结果，之后这么久没有新消息，认为已经识别完
const WAIT_EOS_IDLE_AFTER_RESULT_MS = 60 * 1000

// wf-voice 会把句号替换成逗号，识别结束时去掉结尾多余的逗号
const TRAILING_COMMA_PATTERN = new RegExp('[，,]+$')
const ASCII_VISIBLE_PATTERN = new RegExp('[\\x21-\\x7e]')
const ASCII_ALNUM_PATTERN = new RegExp('[A-Za-z0-9]')

enum State {
    IDLE,       // 空闲
    CONNECTING, // 连接中，已经开始录音或接收调用方提供的音频，音频先缓存
    RECORDING,  // 已连接，录音中
    FINISHING   // 已停止录音，等待剩余识别结果
}

/**
 * 识别回调
 */
export interface RecognitionCallback {
    // 识别文本有更新：识别出新的一句，或者正在说的这句有了新的中间结果。text 是本次识别到目前为止的全部文本
    onPartialResult: (text: string) => void
    // 识别完成，之后不再回调。text 是本次识别的全部文本，可能为空
    onFinalResult: (text: string) => void
    // 出错，之后不再回调
    onError: (message: string) => void
}

/**
 * 实时语音输入管理器
 *
 * 录音并实时推送到 wf-voice 识别（经过 asr-api 转发，内网测试时也可以直连）。wf-voice 每识别完一句返回这句的最终结果；
 * 开启边说边出字后，说话过程中还会返回正在说的这句的中间结果。
 */
export default class AsrManager {
    private audioRecorder?: PcmAudioRecorder
    private wsClient?: AsrWebSocketClient
    private callback?: RecognitionCallback
    private state: State = State.IDLE

    // 本次识别已确定的文本，即各句的最终结果
    private recognizedText: string = ''
    // 正在说的这句的中间结果，收到这句的最终结果后清空
    private partialText: string = ''

    // 音频由调用方通过 feedAudioData 提供，而不是自己录音
    private feedAudio: boolean = false
    // 连接识别服务期间的音频，连接成功后发送
    private pendingAudio: ArrayBuffer[] = []
    // 连接成功前已经停止录音或停止提供音频，发送完缓存的音频后结束识别
    private pendingStop: boolean = false
    // 调用方提供的音频字节数，用于估算等待剩余识别结果的时间
    private feedAudioBytes: number = 0

    private maxDurationTimer: number = -1
    private waitEosTimeoutTimer: number = -1
    private waitEosIdleTimer: number = -1

    /**
     * 开始语音识别，自己录音，调用前需要已获得麦克风权限
     */
    startRecognition(callback: RecognitionCallback) {
        this.start(callback, false)
    }

    /**
     * 开始语音识别，由调用方通过 feedAudioData 提供音频，提供完后调用 stopRecognition。
     * 连接识别服务期间提供的音频会先缓存，连接成功后再发送
     */
    startRecognitionWithAudioFeed(callback: RecognitionCallback) {
        this.start(callback, true)
    }

    private start(callback: RecognitionCallback, feedAudio: boolean) {
        if (this.state !== State.IDLE) {
            console.warn(TAG, '正在识别中，无需重复开始')
            return
        }
        const address: string = voiceInputConfig.asrServerUrl
        if (address.length === 0) {
            callback.onError('未配置语音识别服务地址')
            return
        }

        this.callback = callback
        this.feedAudio = feedAudio
        this.state = State.CONNECTING
        this.recognizedText = ''
        this.partialText = ''
        this.pendingAudio = []
        this.pendingStop = false
        this.feedAudioBytes = 0

        const client: AsrWebSocketClient = new AsrWebSocketClient({
            onConnected: () => {
                this.onConnected()
            },
            onPartialResult: (text: string) => {
                this.delayIdleFinish()
                this.partialText = text
                this.callback?.onPartialResult(this.getText())
            },
            onResult: (text: string) => {
                this.delayIdleFinish()
                this.handleSentenceResult(text)
            },
            onEos: () => {
                this.finishRecognition()
            },
            onError: (error: string) => {
                console.error(TAG, '语音识别服务错误: ' + error)
                if (this.state === State.FINISHING) {
                    // 已经停止录音，保留已识别出的文本
                    this.finishRecognition()
                } else {
                    this.failRecognition(error)
                }
            }
        })
        this.wsClient = client
        if (!feedAudio) {
            // 获取认证码、连接识别服务可能要一两秒，用户点完就开始说话。先开始录音，连接成功前的音频先缓存
            this.startAudioRecording()
        }
        // wf-voice 要求每个连接的 clientId 唯一，并会用作服务端录音文件名。连接 asr-api 时由 asr-api 重新生成
        const clientId: string = voiceInputConfig.userId + '-' + util.generateRandomUUID(false).split('-').join('')
        const partialResult: boolean = voiceInputConfig.asrPartialResult
        if (!AsrManager.isAsrApiUrl(address)) {
            // 直连 wf-voice，不需要鉴权
            client.connect(address, clientId, partialResult, null)
            return
        }
        requestAuthCode((authCode: string) => {
            // 获取认证码期间，识别可能已经停止或取消
            if (this.wsClient === client) {
                client.connect(address, clientId, partialResult, authCode)
            }
        }, (errorCode: number) => {
            if (this.wsClient === client) {
                this.failRecognition('获取认证码失败: ' + errorCode)
            }
        })
    }

    /**
     * 停止录音或停止提供音频，剩余识别结果返回后回调 onFinalResult
     */
    stopRecognition() {
        if (this.state === State.CONNECTING) {
            if (this.pendingStop) {
                return
            }
            let hasAudio = this.audioRecorder !== undefined || this.pendingAudio.length > 0
            this.stopAudioRecording()
            if (hasAudio) {
                // 连接成功后发送完缓存的音频再结束，一直连不上时超时
                console.log(TAG, '停止录音，连接成功后再结束识别')
                this.pendingStop = true
                this.clearTimer(this.maxDurationTimer)
                this.maxDurationTimer = -1
                this.clearTimer(this.waitEosTimeoutTimer)
                this.waitEosTimeoutTimer = setTimeout(() => {
                    this.onWaitEosTimeout()
                }, WAIT_EOS_TIMEOUT_MS)
            } else {
                // 还没有音频
                this.finishRecognition()
            }
        } else if (this.state === State.RECORDING) {
            console.log(TAG, '停止录音，等待剩余识别结果')
            this.state = State.FINISHING
            this.clearTimer(this.maxDurationTimer)
            this.maxDurationTimer = -1
            this.stopAudioRecording()
            this.wsClient?.sendEos()
            // 一次提供了较长的音频时，服务端需要更多时间识别。16kHz、16-bit 的音频每毫秒 32 字节，按音频时长增加等待时间
            let audioMs = this.feedAudioBytes / 32
            this.clearTimer(this.waitEosTimeoutTimer)
            this.waitEosTimeoutTimer = setTimeout(() => {
                this.onWaitEosTimeout()
            }, WAIT_EOS_TIMEOUT_MS + audioMs / 2)
            this.clearTimer(this.waitEosIdleTimer)
            this.waitEosIdleTimer = setTimeout(() => {
                this.onWaitEosIdle()
            }, WAIT_EOS_IDLE_TIMEOUT_MS + audioMs / 10)
        }
    }

    /**
     * 提供音频数据，只在 startRecognitionWithAudioFeed 之后有效
     * @param pcm 16kHz、16-bit、单声道 PCM，传入后不能再修改
     */
    feedAudioData(pcm: ArrayBuffer) {
        if (!this.feedAudio || this.pendingStop) {
            return
        }
        if (this.state === State.CONNECTING) {
            this.pendingAudio.push(pcm)
        } else if (this.state === State.RECORDING) {
            this.wsClient?.sendAudioData(pcm)
        } else {
            return
        }
        this.feedAudioBytes += pcm.byteLength
    }

    /**
     * 取消语音识别，丢弃还没返回的识别结果，之后不再回调
     */
    cancelRecognition() {
        if (this.state !== State.IDLE) {
            console.log(TAG, '取消识别')
            this.cleanup()
        }
    }

    /**
     * 是否正在识别，包括停止录音后等待剩余识别结果的阶段
     */
    isRecognizing(): boolean {
        return this.state !== State.IDLE
    }

    private onConnected() {
        if (this.state !== State.CONNECTING) {
            return
        }
        this.state = State.RECORDING
        let client = this.wsClient
        for (let data of this.pendingAudio) {
            client?.sendAudioData(data)
        }
        this.pendingAudio = []
        if (this.pendingStop) {
            this.pendingStop = false
            this.stopRecognition()
        }
    }

    private onWaitEosTimeout() {
        this.waitEosTimeoutTimer = -1
        if (this.state === State.CONNECTING) {
            console.warn(TAG, '连接语音识别服务超时')
            this.failRecognition('连接语音识别服务超时')
        } else {
            console.warn(TAG, '等待剩余识别结果超时，结束识别')
            this.finishRecognition()
        }
    }

    private onWaitEosIdle() {
        this.waitEosIdleTimer = -1
        console.warn(TAG, '没有收到 [EOS]，按已返回的识别结果结束识别')
        this.finishRecognition()
    }

    /**
     * 停止录音后又收到识别结果，重新计算没有新消息就结束识别的时间
     */
    private delayIdleFinish() {
        if (this.state === State.FINISHING) {
            this.clearTimer(this.waitEosIdleTimer)
            this.waitEosIdleTimer = setTimeout(() => {
                this.onWaitEosIdle()
            }, WAIT_EOS_IDLE_AFTER_RESULT_MS)
        }
    }

    private async startAudioRecording() {
        const client: AsrWebSocketClient | undefined = this.wsClient
        const recorder: PcmAudioRecorder = new PcmAudioRecorder()
        this.audioRecorder = recorder
        let success = await recorder.start({
            onAudioData: (pcm: ArrayBuffer) => {
                if (this.wsClient !== client) {
                    return
                }
                // 实时发送到服务端，还没连接成功时先缓存
                if (this.state === State.CONNECTING) {
                    if (!this.pendingStop) {
                        this.pendingAudio.push(pcm)
                    }
                } else if (this.state === State.RECORDING) {
                    client?.sendAudioData(pcm)
                }
            },
            onError: (message: string) => {
                // 忽略已结束的识别，以及已经停止的录音报的错误
                if (this.wsClient === client && this.audioRecorder === recorder) {
                    this.failRecognition('录音失败: ' + message)
                }
            }
        })
        // 启动失败时会回调 onError，由 onError 结束识别；启动期间识别可能已经停止或取消
        if (success && this.wsClient === client && this.audioRecorder === recorder) {
            console.log(TAG, '录音已开始')
            this.maxDurationTimer = setTimeout(() => {
                this.maxDurationTimer = -1
                console.log(TAG, '达到最大录音时长，自动停止')
                this.stopRecognition()
            }, MAX_RECORDING_DURATION_MS)
        } else if (success) {
            recorder.stop()
        }
    }

    private stopAudioRecording() {
        if (this.audioRecorder) {
            this.audioRecorder.stop()
            this.audioRecorder = undefined
        }
    }

    private handleSentenceResult(sentence: string) {
        this.partialText = ''
        this.recognizedText = AsrManager.join(this.recognizedText, sentence)
        this.callback?.onPartialResult(this.getText())
    }

    /**
     * 已确定的文本，加上正在说的这句的中间结果
     */
    private getText(): string {
        return AsrManager.join(this.recognizedText, this.partialText)
    }

    /**
     * 拼接两段识别文本，两段英文之间补一个空格
     */
    static join(text: string, sentence: string): string {
        if (text.length > 0 && sentence.length > 0) {
            let last = text.charAt(text.length - 1)
            let first = sentence.charAt(0)
            if (ASCII_VISIBLE_PATTERN.test(last) && ASCII_ALNUM_PATTERN.test(first)) {
                return text + ' ' + sentence
            }
        }
        return text + sentence
    }

    /**
     * 是否是 asr-api 的地址。asr-api 的接口都在 /api/ 路径下，直连 wf-voice 的地址没有路径
     */
    static isAsrApiUrl(address: string): boolean {
        try {
            return url.URL.parseURL(address).pathname.includes('/api/')
        } catch (e) {
            return false
        }
    }

    private finishRecognition() {
        if (this.state === State.IDLE) {
            return
        }
        let cb = this.callback
        let text = this.getText().replace(TRAILING_COMMA_PATTERN, '')
        this.cleanup()
        cb?.onFinalResult(text)
    }

    private failRecognition(message: string) {
        if (this.state === State.IDLE) {
            return
        }
        let cb = this.callback
        this.cleanup()
        cb?.onError(message)
    }

    private clearTimer(timer: number) {
        if (timer !== -1) {
            clearTimeout(timer)
        }
    }

    private cleanup() {
        this.state = State.IDLE
        this.callback = undefined
        this.clearTimer(this.maxDurationTimer)
        this.clearTimer(this.waitEosTimeoutTimer)
        this.clearTimer(this.waitEosIdleTimer)
        this.maxDurationTimer = -1
        this.waitEosTimeoutTimer = -1
        this.waitEosIdleTimer = -1
        this.stopAudioRecording()
        if (this.wsClient) {
            this.wsClient.disconnect()
            this.wsClient = undefined
        }
        this.recognizedText = ''
        this.partialText = ''
        this.feedAudio = false
        this.pendingAudio = []
        this.pendingStop = false
        this.feedAudioBytes = 0
    }
}
