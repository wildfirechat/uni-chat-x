/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

/**
 * 实时语音识别 WebSocket 客户端，移植自 ../android-chat 的 asr/AsrWebSocketClient.java。
 *
 * 连接 asr-api 的 /api/stream，由 asr-api 鉴权后转发给 wf-voice；内网测试时也可以直连 wf-voice。
 * 协议详见 wf-voice 项目的 docs/server-api.md：
 * 1. 连接后发送的第一条文本消息是 clientId；需要边说边出字时，接着发送 partial
 * 2. 二进制消息发送 16kHz、16-bit、单声道 PCM
 * 3. 服务端每识别完一句，推送一条文本消息：[段开始毫秒时间戳+时长秒] 识别文本
 * 4. 发送过 partial 时，说话过程中还会推送正在说的这句的中间结果：[PARTIAL] 识别文本
 * 5. 说话结束时发送 eos，服务端推送完剩余识别结果后回复 [EOS]
 *
 * 每次识别使用一个新实例。连接成功之前就可以发送音频，音频先缓存，连接成功后跟在 clientId 后面发送。
 * 所有回调都在主线程，调用 [disconnect] 之后不再回调。
 *
 * 为什么不用 uni.connectSocket：鉴权的 authCode 要放在握手的 HTTP header 里，而录音线程要直接往连接里写音频，
 * 这两点在插件里用 OkHttp 最直接（鸿蒙端的 connectSocket 还不支持 header）。
 */
internal class AsrWebSocketClient(callback: Callback) {

    interface Callback {
        /** 连接成功，连接成功之前缓存的音频已经发送 */
        fun onConnected()

        /** 正在说的这句的中间结果，之后会被新的中间结果或这句的最终结果替换 */
        fun onPartialResult(text: String)

        /** 识别出一句的最终结果 */
        fun onResult(text: String)

        /** eos 之前的识别结果已全部返回 */
        fun onEos()

        /** 连接失败或连接被断开 */
        fun onError(error: String)
    }

    companion object {
        const val HEADER_AUTH_CODE = "authCode"

        private const val MESSAGE_EOS = "eos"
        private const val MESSAGE_PARTIAL = "partial"
        private const val MESSAGE_EOS_ACK = "[EOS]"
        private const val MESSAGE_PARTIAL_PREFIX = "[PARTIAL]"
        private const val MESSAGE_PONG = "pong"
        private const val MESSAGE_TRIAL_PREFIX = "[TRIAL]"

        // 发送 eos 前补发约 500ms 静音，让不支持 eos 的旧版本 wf-voice 也能通过 VAD 断句，识别出最后一句。
        // 静音和录音一样按 30ms（960 字节）一条消息发送，单条消息过大时 asr-api 或 wf-voice 会断开连接
        private const val SILENCE_FRAME_BYTES = 960
        private const val SILENCE_PADDING_FRAMES = 17

        private val OK_HTTP_CLIENT: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .pingInterval(30, TimeUnit.SECONDS)
                .build()
        }

        /**
         * 去掉识别结果的时间前缀，例如 "[1740992313000+2.35] 你好，世界，" 返回 "你好，世界，"
         */
        private fun parseResultText(message: String): String {
            var text = message
            if (text.startsWith("[")) {
                val end = text.indexOf(']')
                if (end > 0) {
                    text = text.substring(end + 1)
                }
            }
            return text.trim()
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var callback: Callback? = callback

    // 下面的字段在录音线程、OkHttp 线程也会访问，读写时要持有 lock
    private val lock = Any()
    private var webSocket: WebSocket? = null

    // 连接成功之前发送的音频，连接成功后发送
    private val pendingAudio = ArrayList<ByteString>()
    private var opened = false
    private var disconnected = false

    /**
     * 连接语音识别服务
     * @param url           WebSocket 地址，asr-api 或 wf-voice
     * @param clientId      客户端 ID，wf-voice 要求每个连接唯一
     * @param partialResult 是否边说边出字
     * @param authCode      连接 asr-api 时需要的认证码，直连 wf-voice 时传 null
     */
    fun connect(url: String, clientId: String, partialResult: Boolean, authCode: String?) {
        VoiceInputContext.log("正在连接语音识别服务: $url")
        val builder = try {
            Request.Builder().url(url)
        } catch (e: IllegalArgumentException) {
            VoiceInputContext.logError("语音识别服务地址无效: $url", e)
            postToMain { it.onError("语音识别服务地址无效") }
            return
        }
        if (!authCode.isNullOrEmpty()) {
            builder.header(HEADER_AUTH_CODE, authCode)
        }
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                onOpened(clientId, partialResult)
                postToMain { it.onConnected() }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                handleMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                VoiceInputContext.log("WebSocket 已关闭: code=$code, reason=$reason")
                postToMain { it.onError("连接已断开") }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                VoiceInputContext.logError("WebSocket 连接失败", t)
                val error = if (response != null && response.code == 401) "语音识别服务鉴权失败" else "连接失败: ${t.message}"
                postToMain { it.onError(error) }
            }
        }
        // 在锁内赋值，OkHttp 线程回调 onOpen 时 webSocket 一定已经赋值
        synchronized(lock) {
            if (disconnected) {
                return
            }
            webSocket = OK_HTTP_CLIENT.newWebSocket(builder.build(), listener)
        }
    }

    /**
     * 连接成功，先发送 clientId 等指令，再发送连接成功之前缓存的音频
     */
    private fun onOpened(clientId: String, partialResult: Boolean) {
        synchronized(lock) {
            val ws = webSocket
            if (disconnected || ws == null) {
                return
            }
            ws.send(clientId)
            if (partialResult) {
                ws.send(MESSAGE_PARTIAL)
            }
            var pendingBytes = 0L
            for (data in pendingAudio) {
                ws.send(data)
                pendingBytes += data.size
            }
            pendingAudio.clear()
            opened = true
            // 16kHz、16-bit 的音频每毫秒 32 字节
            VoiceInputContext.log("WebSocket 连接成功，发送连接前缓存的音频 ${pendingBytes / 32}ms")
        }
    }

    /**
     * 发送音频数据，可以在任意线程调用。还没连接成功时先缓存，连接成功后发送
     * @param pcmData 16kHz、16-bit、单声道 PCM，会复制一份，调用方可以继续复用
     */
    fun sendAudioData(pcmData: ByteArray) {
        synchronized(lock) {
            if (disconnected) {
                return
            }
            // toByteString 会复制数据
            val data = pcmData.toByteString(0, pcmData.size)
            val ws = webSocket
            if (!opened || ws == null) {
                pendingAudio.add(data)
            } else if (!ws.send(data)) {
                VoiceInputContext.log("发送音频数据失败")
            }
        }
    }

    /**
     * 通知服务端说话结束，服务端返回剩余识别结果后回调 [Callback.onEos]。需要在连接成功后调用
     */
    fun sendEos() {
        synchronized(lock) {
            val ws = webSocket
            if (!opened || disconnected || ws == null) {
                return
            }
            val silence = ByteArray(SILENCE_FRAME_BYTES)
            for (i in 0 until SILENCE_PADDING_FRAMES) {
                ws.send(silence.toByteString(0, silence.size))
            }
            ws.send(MESSAGE_EOS)
        }
    }

    /**
     * 断开连接，之后不再回调
     */
    fun disconnect() {
        callback = null
        synchronized(lock) {
            disconnected = true
            pendingAudio.clear()
            webSocket?.close(1000, null)
            webSocket = null
        }
    }

    private fun handleMessage(message: String) {
        if (MESSAGE_EOS_ACK == message) {
            VoiceInputContext.log("收到 [EOS]")
            postToMain { it.onEos() }
        } else if (message.startsWith(MESSAGE_PARTIAL_PREFIX)) {
            val text = message.substring(MESSAGE_PARTIAL_PREFIX.length).trim()
            if (text.isNotEmpty()) {
                postToMain { it.onPartialResult(text) }
            }
        } else if (message.startsWith(MESSAGE_TRIAL_PREFIX)) {
            // 体验版每个连接只识别前 30 秒音频
            VoiceInputContext.log(message)
        } else if (MESSAGE_PONG != message) {
            VoiceInputContext.log("收到识别结果: $message")
            val text = parseResultText(message)
            if (text.isNotEmpty()) {
                postToMain { it.onResult(text) }
            }
        }
    }

    /**
     * 切换到主线程执行回调，已断开连接时忽略
     */
    private fun postToMain(action: (Callback) -> Unit) {
        mainHandler.post {
            val cb = callback
            if (cb != null) {
                action(cb)
            }
        }
    }
}
