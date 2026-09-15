/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import java.util.UUID

/**
 * 实时语音输入管理器，移植自 ../android-chat 的 asr/AsrManager.java（去掉了没用到的 Over 热词）。
 *
 * 录音并实时推送到 wf-voice 识别（经过 asr-api 转发，内网测试时也可以直连）。wf-voice 每识别完一句返回这句的最终结果；
 * 开启边说边出字后，说话过程中还会返回正在说的这句的中间结果。
 *
 * 停止后等待剩余结果的时间按 ../ios-chat 的 WFCUAsrManager.m 算，而不是 android-chat 的「10 秒 + 音频时长一半」：
 * 服务端按实时速度消费音频，先按住说了十几秒才滑到「转文字」时，之前录的音频是一次性补发过去的，
 * 要按实时速度消完才出结果，按一半估算会过早结束，表现为「说完滑到转文字，什么都没识别出来」。
 *
 * 所有方法都在主线程调用，回调也在主线程。
 */
internal class AsrManager(private val context: Context) {

    class Callback(
        /** 识别文本有更新，参数是本次识别到目前为止的全部文本 */
        val onPartialResult: (String) -> Unit,
        /** 识别完成，参数是本次识别的全部文本，可能为空；之后不再回调 */
        val onFinalResult: (String) -> Unit,
        /** 出错，之后不再回调 */
        val onError: (String) -> Unit
    )

    private enum class State {
        IDLE,       // 空闲
        CONNECTING, // 连接中，已经开始录音或接收调用方提供的音频，音频先缓存
        RECORDING,  // 已连接，录音中
        FINISHING   // 已停止录音，等待剩余识别结果
    }

    companion object {
        // 最长录音时长：60秒
        private const val MAX_RECORDING_DURATION_MS = 60 * 1000L

        // 停止录音后等待剩余识别结果的基础时间：8秒
        private const val WAIT_EOS_TIMEOUT_MS = 8 * 1000L

        // 停止录音后收到过识别结果，之后这么久没有新消息，认为已经识别完。服务端不支持 eos 指令时不会回复 [EOS]，靠它结束识别
        private const val WAIT_EOS_IDLE_AFTER_RESULT_MS = 10 * 1000L

        // 16kHz、16-bit 的音频每毫秒 32 字节
        private const val PCM_BYTES_PER_MS = 32L

        private val TRAILING_COMMAS = Regex("[，,]+$")

        /**
         * 是否是 asr-api 的地址。asr-api 的接口都在 /api/ 路径下，直连 wf-voice 的地址没有路径
         */
        fun isAsrApiUrl(url: String): Boolean {
            val path = try {
                Uri.parse(url).path
            } catch (e: Exception) {
                null
            }
            return path != null && path.contains("/api/")
        }

        /**
         * 拼接两段识别文本，两段英文之间补一个空格
         */
        private fun join(text: String, sentence: String): String {
            if (text.isNotEmpty() && sentence.isNotEmpty()) {
                val last = text[text.length - 1]
                val first = sentence[0]
                if (last.code < 128 && !Character.isWhitespace(last) && first.code < 128 && Character.isLetterOrDigit(first)) {
                    return "$text $sentence"
                }
            }
            return text + sentence
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioRecorder: PcmAudioRecorder? = null
    private var wsClient: AsrWebSocketClient? = null
    private var callback: Callback? = null

    // 应用层可能从 JS 线程读 isRecognizing
    @Volatile
    private var state = State.IDLE

    // 本次识别已确定的文本，即各句的最终结果
    private var recognizedText = ""

    // 正在说的这句的中间结果，收到这句的最终结果后清空
    private var partialText = ""

    // 音频由调用方通过 feedAudioData 提供，而不是自己录音
    private var feedAudio = false

    // 连接成功前已经停止录音或停止提供音频，连接成功后发送完缓存的音频再结束识别
    private var pendingStop = false

    // 调用方提供的音频字节数，用于估算等待剩余识别结果的时间
    private var feedAudioBytes = 0L

    private val maxDurationRunnable = Runnable {
        VoiceInputContext.log("达到最大录音时长，自动停止")
        stopRecognition()
    }

    private val waitEosTimeoutRunnable = Runnable {
        if (state == State.CONNECTING) {
            failRecognition("连接语音识别服务超时")
        } else {
            VoiceInputContext.log("等待剩余识别结果超时，结束识别")
            finishRecognition()
        }
    }

    private val waitEosIdleRunnable = Runnable {
        VoiceInputContext.log("没有收到 [EOS]，按已返回的识别结果结束识别")
        finishRecognition()
    }

    /**
     * 开始语音识别，调用前需要已获得录音权限。会立即开始录音，连接识别服务期间录到的音频先缓存，连接成功后再发送
     */
    fun startRecognition(callback: Callback) {
        start(callback, false)
    }

    /**
     * 开始语音识别，由调用方通过 [feedAudioData] 提供音频，提供完后调用 [stopRecognition]。
     * 连接识别服务期间提供的音频会先缓存，连接成功后再发送
     */
    fun startRecognitionWithAudioFeed(callback: Callback) {
        start(callback, true)
    }

    private fun start(callback: Callback, feedAudio: Boolean) {
        if (state != State.IDLE) {
            VoiceInputContext.log("正在识别中，无需重复开始")
            return
        }
        val url = VoiceInputContext.asrServerUrl
        if (url.isEmpty()) {
            callback.onError("未配置语音识别服务地址")
            return
        }

        this.callback = callback
        this.feedAudio = feedAudio
        state = State.CONNECTING
        recognizedText = ""
        partialText = ""
        pendingStop = false
        feedAudioBytes = 0

        val client = AsrWebSocketClient(object : AsrWebSocketClient.Callback {
            override fun onConnected() {
                state = State.RECORDING
                if (pendingStop) {
                    pendingStop = false
                    stopRecognition()
                }
            }

            override fun onPartialResult(text: String) {
                delayIdleFinish()
                partialText = text
                this@AsrManager.callback?.onPartialResult?.invoke(getText())
            }

            override fun onResult(text: String) {
                delayIdleFinish()
                handleSentenceResult(text)
            }

            override fun onEos() {
                finishRecognition()
            }

            override fun onError(error: String) {
                VoiceInputContext.logError("语音识别服务错误: $error")
                if (state == State.FINISHING) {
                    // 已经停止录音，保留已识别出的文本
                    finishRecognition()
                } else {
                    failRecognition(error)
                }
            }
        })
        wsClient = client
        if (!feedAudio) {
            // 获取认证码、连接识别服务可能要一两秒，用户点完就开始说话。先开始录音，音频由 client 缓存到连接成功后发送
            startAudioRecording()
        }
        // wf-voice 要求每个连接的 clientId 唯一，并会用作服务端录音文件名。连接 asr-api 时由 asr-api 重新生成
        val clientId = VoiceInputContext.userId + "-" + UUID.randomUUID().toString().replace("-", "")
        val partialResult = VoiceInputContext.asrPartialResult
        if (!isAsrApiUrl(url)) {
            // 直连 wf-voice，不需要鉴权
            client.connect(url, clientId, partialResult, null)
            return
        }
        VoiceInputContext.requestAuthCode({ authCode ->
            // 获取认证码期间，识别可能已经停止或取消
            if (wsClient === client) {
                client.connect(url, clientId, partialResult, authCode)
            }
        }, { errorCode ->
            if (wsClient === client) {
                failRecognition("获取认证码失败: $errorCode")
            }
        })
    }

    /**
     * 停止录音或停止提供音频，剩余识别结果返回后回调 onFinalResult
     */
    fun stopRecognition() {
        if (state == State.CONNECTING) {
            if (pendingStop) {
                return
            }
            val hasAudio = audioRecorder != null || feedAudioBytes > 0
            stopAudioRecording()
            if (hasAudio) {
                // 连接成功后发送完缓存的音频再结束，一直连不上时超时
                VoiceInputContext.log("停止录音，连接成功后再结束识别")
                pendingStop = true
                mainHandler.removeCallbacks(maxDurationRunnable)
                mainHandler.removeCallbacks(waitEosTimeoutRunnable)
                mainHandler.postDelayed(waitEosTimeoutRunnable, WAIT_EOS_TIMEOUT_MS)
            } else {
                // 还没有音频
                finishRecognition()
            }
        } else if (state == State.RECORDING) {
            state = State.FINISHING
            mainHandler.removeCallbacks(maxDurationRunnable)
            stopAudioRecording()
            wsClient?.sendEos()
            // 服务端按实时速度消费音频，积压的音频要消完才出结果：按 1.5 倍音频时长再加 8 秒基础时间留出余量（同 ios-chat）
            val audioMs = feedAudioBytes / PCM_BYTES_PER_MS
            val waitAfterEos = WAIT_EOS_TIMEOUT_MS + audioMs * 3 / 2
            VoiceInputContext.log("停止录音，等待剩余识别结果：音频约 ${audioMs}ms，最长等待 ${waitAfterEos}ms")
            mainHandler.removeCallbacks(waitEosTimeoutRunnable)
            mainHandler.postDelayed(waitEosTimeoutRunnable, waitAfterEos)
            // 收到第一条结果前不能提前结束，否则积压的音频还没识别完就放弃了
            mainHandler.removeCallbacks(waitEosIdleRunnable)
            mainHandler.postDelayed(waitEosIdleRunnable, waitAfterEos)
        }
    }

    /**
     * 停止录音后又收到识别结果，重新计算没有新消息就结束识别的时间
     */
    private fun delayIdleFinish() {
        if (state == State.FINISHING) {
            mainHandler.removeCallbacks(waitEosIdleRunnable)
            mainHandler.postDelayed(waitEosIdleRunnable, WAIT_EOS_IDLE_AFTER_RESULT_MS)
        }
    }

    /**
     * 提供音频数据，只在 [startRecognitionWithAudioFeed] 之后有效
     * @param pcmData 16kHz、16-bit、单声道 PCM
     */
    fun feedAudioData(pcmData: ByteArray) {
        if (!feedAudio || pendingStop || (state != State.CONNECTING && state != State.RECORDING)) {
            return
        }
        wsClient?.sendAudioData(pcmData)
        feedAudioBytes += pcmData.size
    }

    /**
     * 取消语音识别，丢弃还没返回的识别结果，之后不再回调
     */
    fun cancelRecognition() {
        if (state != State.IDLE) {
            VoiceInputContext.log("取消识别")
            cleanup()
        }
    }

    /**
     * 是否正在识别，包括停止录音后等待剩余识别结果的阶段
     */
    fun isRecognizing(): Boolean {
        return state != State.IDLE
    }

    private fun startAudioRecording() {
        val client = wsClient
        val recorder = PcmAudioRecorder(context)
        audioRecorder = recorder
        val success = recorder.startRecording(object : PcmAudioRecorder.Callback {
            override fun onAudioData(pcmData: ByteArray) {
                // 在录音线程回调，实时发送到服务端，还没连接成功时 client 会先缓存
                client?.sendAudioData(pcmData)
            }

            override fun onError(message: String) {
                // 可能在录音线程回调。忽略已经停止的录音报的错误，包括停止录音时录音线程退出前报的错误
                mainHandler.post {
                    if (audioRecorder === recorder) {
                        failRecognition("录音失败: $message")
                    }
                }
            }
        })
        // 启动失败时 PcmAudioRecorder 会回调 onError，由 onError 结束识别
        if (success) {
            mainHandler.postDelayed(maxDurationRunnable, MAX_RECORDING_DURATION_MS)
        }
    }

    private fun stopAudioRecording() {
        audioRecorder?.stopRecording()
        audioRecorder = null
    }

    private fun handleSentenceResult(sentence: String) {
        partialText = ""
        recognizedText = join(recognizedText, sentence)
        callback?.onPartialResult?.invoke(getText())
    }

    /**
     * 已确定的文本，加上正在说的这句的中间结果
     */
    private fun getText(): String {
        return join(recognizedText, partialText)
    }

    private fun finishRecognition() {
        if (state == State.IDLE) {
            return
        }
        val cb = callback
        // wf-voice 会把句号替换成逗号，去掉结尾多余的逗号
        val text = getText().replace(TRAILING_COMMAS, "")
        VoiceInputContext.log("识别结束，文本长度 ${text.length}")
        cleanup()
        cb?.onFinalResult?.invoke(text)
    }

    private fun failRecognition(message: String) {
        if (state == State.IDLE) {
            return
        }
        val cb = callback
        VoiceInputContext.logError("识别失败: $message")
        cleanup()
        cb?.onError?.invoke(message)
    }

    private fun cleanup() {
        state = State.IDLE
        callback = null
        mainHandler.removeCallbacks(maxDurationRunnable)
        mainHandler.removeCallbacks(waitEosTimeoutRunnable)
        mainHandler.removeCallbacks(waitEosIdleRunnable)
        stopAudioRecording()
        wsClient?.disconnect()
        wsClient = null
        recognizedText = ""
        partialText = ""
        feedAudio = false
        pendingStop = false
        feedAudioBytes = 0
    }
}
