/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/*
 * 插件内共用的配置、事件出口、认证码请求、麦克风权限和线程切换，对应鸿蒙端的 VoiceInputContext.ets。
 *
 * ## 为什么这些 .kt 里不 import 任何 io.dcloud.uts 的类
 *
 * 混编的 Kotlin 在 HBuilderX 里没有语法检查，写错了要等整个 App 编译才知道。不依赖 uts 运行时，
 * 就能在本地直接用 kotlinc 对着 android.jar + okhttp 编译检查。拿 Activity、申请权限、往 HBuilderX 控制台打日志
 * 这几件要用 UTSAndroid / console 的事，由 index.uts 通过 [VoiceInputContext.setup] 以函数的形式注入。
 *
 * ## 线程
 *
 * vapor 模式下应用层是从 JS 线程调进插件的（同 wfc-av-client 的 VoipFloatingWindow.uts），而 PopupWindow、
 * 录音回调的汇总、定时器都要在主线程。所以入口一律先切到主线程，发给应用层的事件也在主线程回调
 * （同 wfc-client 的 runOnMainThread：JS 回调里改响应式状态必须在主线程，否则页面不刷新）。
 *
 * ## 认证码为什么绕到应用层去换
 *
 * 连 asr-api 要带 IM 的认证码（appId 'admin'、type 2），换码接口在 wfc-client 插件里。本插件不依赖 IM SDK，
 * 需要时发 authCodeRequired 事件，应用层用 wfc.getAuthCode 换到后调 provideAuthCode 送回来。认证码 1 分钟有效，每次连接前现换。
 */

internal const val TAG = "wfc-voice-input"

/**
 * 浮层上的文案。默认中文，应用层 configVoiceInput 时按当前语言覆盖（插件读不到 App 的 i18n）
 */
internal class VoiceInputTexts {
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
    // %d 替换成剩余秒数
    var countDown = "%d 秒后将停止录音"
    var tooShort = "说话时间太短"
    var recordFailed = "录音失败"
}

internal object VoiceInputContext {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var workHandler: Handler? = null

    // region 应用层注入

    @Volatile
    private var activityProvider: (() -> Activity?)? = null

    @Volatile
    private var permissionRequester: (((Boolean) -> Unit) -> Unit)? = null

    @Volatile
    private var logger: ((String) -> Unit)? = null

    /**
     * @param activityProvider    当前的 Activity（UTSAndroid.getUniActivity）
     * @param permissionRequester 申请录音权限，结果通过参数里的回调返回（UTSAndroid.requestSystemPermission）
     * @param logger              打印到 HBuilderX 控制台（uts 的 console.log）
     */
    fun setup(activityProvider: () -> Activity?, permissionRequester: ((Boolean) -> Unit) -> Unit, logger: (String) -> Unit) {
        this.activityProvider = activityProvider
        this.permissionRequester = permissionRequester
        this.logger = logger
    }

    fun activity(): Activity? {
        return try {
            activityProvider?.invoke()
        } catch (e: Throwable) {
            logError("get activity failed", e)
            null
        }
    }

    fun log(message: String) {
        Log.i(TAG, message)
        val l = logger ?: return
        try {
            l("[$TAG] $message")
        } catch (e: Throwable) {
            // 控制台打不出来不影响功能
        }
    }

    fun logError(message: String, e: Throwable? = null) {
        Log.e(TAG, message, e)
        val l = logger ?: return
        try {
            l("[$TAG] $message" + (if (e != null) ": $e" else ""))
        } catch (t: Throwable) {
            // 控制台打不出来不影响功能
        }
    }

    // endregion

    // region 线程

    fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post { action() }
        }
    }

    /**
     * 串行的后台线程，编码 AMR 用
     */
    fun runInBackground(action: () -> Unit) {
        val handler = synchronized(this) {
            workHandler ?: HandlerThread(TAG).let { thread ->
                thread.start()
                Handler(thread.looper).also { workHandler = it }
            }
        }
        handler.post { action() }
    }

    // endregion

    // region 配置

    // 实时语音识别地址，asr-api 的 wss://.../asr/api/stream，或内网直连 wf-voice
    @Volatile
    var asrServerUrl: String = ""

    // 是否边说边出字
    @Volatile
    var asrPartialResult: Boolean = true

    // 当前用户 ID，拼 clientId 用
    @Volatile
    var userId: String = ""

    // 气泡颜色，ARGB
    @Volatile
    var bubbleColor: Int = 0xFF1F64E4.toInt()

    // 按住说话时是否可以滑到「转文字」
    @Volatile
    var speechToTextEnabled: Boolean = false

    @Volatile
    var texts: VoiceInputTexts = VoiceInputTexts()

    fun applyOptions(json: String) {
        val options = try {
            JSONObject(json)
        } catch (e: Exception) {
            logError("parse options failed: $json", e)
            return
        }
        asrServerUrl = options.optString("asrServerUrl", asrServerUrl).trim()
        asrPartialResult = options.optBoolean("asrPartialResult", asrPartialResult)
        userId = options.optString("userId", userId)
        bubbleColor = parseColor(options.optString("bubbleColor", ""), bubbleColor)
        speechToTextEnabled = options.optBoolean("speechToTextEnabled", speechToTextEnabled)
        val t = options.optJSONObject("texts") ?: return
        val texts = VoiceInputTexts()
        texts.voice = t.optString("voice", texts.voice)
        texts.releaseToSend = t.optString("releaseToSend", texts.releaseToSend)
        texts.cancel = t.optString("cancel", texts.cancel)
        texts.releaseToCancel = t.optString("releaseToCancel", texts.releaseToCancel)
        texts.slideToText = t.optString("slideToText", texts.slideToText)
        texts.releaseToEdit = t.optString("releaseToEdit", texts.releaseToEdit)
        texts.sendVoice = t.optString("sendVoice", texts.sendVoice)
        texts.send = t.optString("send", texts.send)
        texts.noText = t.optString("noText", texts.noText)
        texts.recognizeFailed = t.optString("recognizeFailed", texts.recognizeFailed)
        texts.countDown = t.optString("countDown", texts.countDown)
        texts.tooShort = t.optString("tooShort", texts.tooShort)
        texts.recordFailed = t.optString("recordFailed", texts.recordFailed)
        this.texts = texts
    }

    /**
     * #RRGGBB 或 #AARRGGBB，和鸿蒙端一致
     */
    private fun parseColor(value: String, fallback: Int): Int {
        if (value.isEmpty()) {
            return fallback
        }
        var hex = if (value.startsWith("#")) value.substring(1) else value
        if (hex.length == 6) {
            hex = "FF$hex"
        }
        if (hex.length != 8) {
            return fallback
        }
        return try {
            java.lang.Long.parseLong(hex, 16).toInt()
        } catch (e: NumberFormatException) {
            fallback
        }
    }

    // endregion

    // region 事件

    @Volatile
    private var eventListener: ((String, String) -> Unit)? = null

    fun setEventListener(listener: (String, String) -> Unit) {
        eventListener = listener
    }

    /**
     * 发给应用层的事件。参数只放字符串和数字，序列化成 JSON 数组；在主线程回调
     */
    fun fireEvent(event: String, vararg args: Any) {
        val listener = eventListener
        if (listener == null) {
            log("no listener, drop event $event")
            return
        }
        val array = JSONArray()
        for (arg in args) {
            array.put(arg)
        }
        val argsJson = array.toString()
        runOnMain {
            try {
                listener(event, argsJson)
            } catch (e: Throwable) {
                logError("dispatch event $event failed", e)
            }
        }
    }

    // endregion

    // region 认证码

    private class AuthCodeRequest(val success: (String) -> Unit, val fail: (Int) -> Unit)

    private var authCodeRequestSeq = 0
    private val authCodeRequests = HashMap<Int, AuthCodeRequest>()

    /**
     * 向应用层要一个认证码。在主线程调用，回调在应用层 provideAuthCode 之后、也在主线程
     */
    fun requestAuthCode(success: (String) -> Unit, fail: (Int) -> Unit) {
        if (eventListener == null) {
            fail(-1)
            return
        }
        authCodeRequestSeq++
        val requestId = authCodeRequestSeq
        authCodeRequests[requestId] = AuthCodeRequest(success, fail)
        fireEvent("authCodeRequired", requestId)
    }

    /**
     * @param authCode  换到的认证码，失败时传空串
     * @param errorCode 失败时的错误码
     */
    fun onAuthCodeProvided(requestId: Int, authCode: String, errorCode: Int) {
        runOnMain {
            val request = authCodeRequests.remove(requestId)
            if (request != null) {
                if (authCode.isNotEmpty()) {
                    request.success(authCode)
                } else {
                    request.fail(errorCode)
                }
            }
        }
    }

    // endregion

    // region 麦克风权限

    fun isMicrophoneGranted(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        return activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * 申请麦克风权限，回调在主线程、只回调一次
     */
    fun requestMicrophonePermission(callback: (Boolean) -> Unit) {
        val requester = permissionRequester
        if (requester == null) {
            callback(false)
            return
        }
        var answered = false
        val reply: (Boolean) -> Unit = { granted ->
            runOnMain {
                if (!answered) {
                    answered = true
                    callback(granted)
                }
            }
        }
        try {
            requester(reply)
        } catch (e: Throwable) {
            logError("request microphone permission failed", e)
            reply(false)
        }
    }

    // endregion
}
