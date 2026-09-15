/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.animation.ArgbEvaluator
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.Space
import android.widget.TextView
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.ceil
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * 按住说话，移植自 ../android-chat 的 audio/AudioRecorderPanel.java，交互参考微信：
 * - 按住按钮开始录音，松开发送语音
 * - 手指滑到左上方的「取消」后松开，不发送
 * - 开启转文字时，手指滑到右上方的「转文字」，边说边显示识别出的文字；松开后可以编辑文字再发送，也可以发送原语音
 *
 * 录音采集 16kHz PCM，发送语音时再编码成 AMR；转文字识别的是从开始录音算起的全部音频。
 *
 * 和 android-chat 的区别，都是因为跑在 uts 插件里、按钮是 uvue 页面里的节点（和鸿蒙端的处理一致）：
 * - 触摸事件由应用层的「按住说话」按钮转发进来（[onTouchDown] / [onTouchMove] / [onTouchUp]），坐标是**屏幕坐标**（dp）。
 *   浮层是 PopupWindow（单独的窗口），弹出后手势仍然归按钮所在的 Activity 窗口 —— Android 只把一次手势投递给按下时的窗口；
 * - 按钮上边缘也由应用层随按下一起传进来；拿不到会话界面的根 View，操作区按整个浮层宽度布局（手机上本来就是整屏）；
 * - 布局和图标都用代码写（插件的 res 只在自定义基座生效），文案和气泡颜色来自应用层的配置；
 * - 没有录音权限时在这里申请，授权之后要重新按一次（同鸿蒙端）；发送音效由应用层播放。
 */
internal class AudioRecorderPanel(val activity: Activity, private val listener: Listener) {

    interface Listener {
        /** 录音完成，audioFile 是 AMR 文件，duration 单位是秒 */
        fun onRecordSuccess(audioFile: String, duration: Int)

        /** 录音失败，用户主动取消时 reason 是 [REASON_USER_CANCELED] */
        fun onRecordFail(reason: String)

        /** 语音转成文字后，用户确认发送文字 */
        fun onSendText(text: String)

        /** 没有麦克风权限，申请也被拒绝了 */
        fun onPermissionDenied()
    }

    companion object {
        const val REASON_USER_CANCELED = "user canceled"

        private const val PCM_BYTES_PER_SECOND = PcmAudioRecorder.BYTES_PER_SECOND
        private const val PCM_FRAME_BYTES = PcmAudioRecorder.CHUNK_SIZE

        private const val STAGE_IDLE = 0

        // 按住录音中
        private const val STAGE_RECORDING = 1

        // 在「转文字」上松手后，编辑识别出的文字
        private const val STAGE_EDITING = 2

        // 浮层正在退出
        private const val STAGE_DISMISSING = 3

        // 气泡形态：松开发送、取消、转文字、编辑文字、没有识别到文字、说话时间太短
        private const val BUBBLE_SEND = 0
        private const val BUBBLE_CANCEL = 1
        private const val BUBBLE_TEXT = 2
        private const val BUBBLE_EDIT = 3
        private const val BUBBLE_NO_TEXT = 4
        private const val BUBBLE_TOO_SHORT = 5

        private val BUBBLE_COLOR_RED = 0xFFFA5151.toInt()

        private const val MAX_DURATION_MS = 60 * 1000L
        private const val MIN_DURATION_MS = 1000L

        // 录音剩余多少时间时开始倒计时
        private const val COUNT_DOWN_MS = 10 * 1000L

        /**
         * 计算一段 PCM 的音量，0~1
         */
        fun computeLevel(pcm: ByteArray): Float {
            val samples = pcm.size / 2
            if (samples == 0) {
                return 0f
            }
            var sum = 0.0
            for (i in 0 until samples) {
                val sample = ((pcm[2 * i].toInt() and 0xff) or (pcm[2 * i + 1].toInt() shl 8)).toShort().toDouble()
                sum += sample * sample
            }
            val db = 20 * log10(max(sqrt(sum / samples), 1.0) / 32768)
            // -50dB 以下视为安静，-15dB 以上视为最大音量
            return max(0.0, min(1.0, (db + 50) / 35)).toFloat()
        }

        /**
         * 和 androidx ColorUtils.calculateLuminance 一致，先把 sRGB 分量转成线性值再算亮度
         */
        private fun luminance(color: Int): Double {
            fun linear(component: Int): Double {
                val c = component / 255.0
                return if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * linear(Color.red(color)) + 0.7152 * linear(Color.green(color)) + 0.0722 * linear(Color.blue(color))
        }

        private fun setAlphaComponent(color: Int, alpha: Int): Int {
            return (color and 0x00FFFFFF) or (alpha shl 24)
        }

        private fun lerp(from: Float, to: Float, fraction: Float): Float {
            return from + (to - from) * fraction
        }
    }

    private val context: Context = activity
    private val handler = Handler(Looper.getMainLooper())
    private val density = activity.resources.displayMetrics.density
    private val vibrator = activity.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator

    private var speechToTextEnabled = false

    // 气泡使用 app 主色调，气泡上的文字和声波根据主色调的深浅用白色或深色
    private var bubbleColor = 0xFF1F64E4.toInt()
    private var bubbleContentColor = Color.WHITE
    private var texts = VoiceInputTexts()

    private var stage = STAGE_IDLE

    // 每次录音加 1，用来丢弃上一次录音延迟到达的回调
    private var recordSession = 0

    // 手指和按钮上边缘的屏幕坐标，px
    private var touchRawX = 0f
    private var touchRawY = 0f
    private var buttonTopRaw = 0f
    private var recorder: PcmAudioRecorder? = null
    private var pcmBuffer: ByteArrayOutputStream? = null
    private var recordedPcm: ByteArray? = null
    private var startTime = 0L
    private var recordDuration = 0L

    private var asrManager: AsrManager? = null
    private var asrStarted = false
    private var asrFinished = false
    private var asrFailed = false

    // 浮层
    private var popupWindow: PopupWindow? = null
    private lateinit var popupRootLayout: FrameLayout
    private lateinit var backgroundDrawable: VoiceInputBackground
    private var backgroundProgress = 0f
    private var backgroundAnimator: ValueAnimator? = null
    private var panelAnimator: ValueAnimator? = null
    private lateinit var bottomView: VoiceRecordBottomView
    private lateinit var countDownTextView: TextView
    private lateinit var bubbleLayout: VoiceBubbleLayout
    private lateinit var waveView: VoiceWaveView
    private lateinit var textEditText: EditText
    private lateinit var hintTextView: TextView
    private lateinit var hintIcon: VoiceIconDrawable
    private lateinit var editActionsLayout: LinearLayout
    private lateinit var cancelLabelView: TextView
    private lateinit var sendVoiceLayout: View
    private lateinit var sendVoiceImageView: ImageView
    private lateinit var sendVoiceLabelView: TextView
    private lateinit var sendTextButton: TextView
    private val popupLocation = IntArray(2)

    // 浮层完成布局、各控件的位置已经计算好
    private var layoutReady = false
    private var stageLeft = 0f
    private var stageWidth = 0f
    private var bubbleBottomMargin = 0f
    private var editActionsBottomMargin = 0f
    private var bubbleState = BUBBLE_SEND
    private val bubbleFrame = BubbleFrame()
    private var bubbleAnimator: ValueAnimator? = null
    private var shakeAnimator: ObjectAnimator? = null
    private val argbEvaluator = ArgbEvaluator()
    private val dismissRunnable = Runnable { dismissPopup() }

    /**
     * 录音入口销毁时调用：立即关闭浮层，停止录音和识别，不回调
     */
    fun release() {
        dismissNow()
    }

    // region 触摸

    /**
     * 手指按下「按住说话」
     * @param x         手指的屏幕坐标，dp
     * @param y         手指的屏幕坐标，dp
     * @param buttonTop 按钮上边缘的屏幕坐标，dp。底部弧形区域要盖住按钮
     */
    fun onTouchDown(x: Float, y: Float, buttonTop: Float) {
        touchRawX = x * density
        touchRawY = y * density
        buttonTopRaw = buttonTop * density
        if (stage == STAGE_DISMISSING) {
            // 上一次录音的浮层还在退出，直接关闭
            dismissNow()
        }
        if (stage != STAGE_IDLE) {
            return
        }
        if (!VoiceInputContext.isMicrophoneGranted(activity)) {
            VoiceInputContext.requestMicrophonePermission { granted ->
                if (!granted) {
                    listener.onPermissionDenied()
                }
            }
            // 和鸿蒙端一样，授权之后要重新按一次
            return
        }
        applyConfig()
        startRecord()
    }

    fun onTouchMove(x: Float, y: Float) {
        touchRawX = x * density
        touchRawY = y * density
        if (stage == STAGE_RECORDING) {
            updateZone()
        }
    }

    /**
     * 手指抬起或手势被打断，都按手指当前所在的目标结束（和 android-chat 一致）
     */
    fun onTouchUp() {
        if (stage == STAGE_RECORDING) {
            stopRecord(bottomView.currentZone())
        }
    }

    // endregion

    // region 录音

    private fun applyConfig() {
        speechToTextEnabled = VoiceInputContext.speechToTextEnabled
        bubbleColor = VoiceInputContext.bubbleColor
        bubbleContentColor = if (luminance(bubbleColor) > 0.3) 0xFF191919.toInt() else Color.WHITE
        texts = VoiceInputContext.texts
    }

    private fun startRecord() {
        val session = ++recordSession
        val audioRecorder = PcmAudioRecorder(context)
        val success = audioRecorder.startRecording(object : PcmAudioRecorder.Callback {
            override fun onAudioData(pcmData: ByteArray) {
                // 在录音线程回调，pcmData 会被复用
                val data = pcmData.clone()
                val level = computeLevel(data)
                handler.post { handleAudioData(session, data, level) }
            }

            override fun onError(message: String) {
                handler.post { handleRecorderError(session, message) }
            }
        })
        if (!success) {
            // 启动失败时已经回调过 onError，这次录音作废
            recordSession++
            listener.onRecordFail(texts.recordFailed)
            return
        }

        recorder = audioRecorder
        pcmBuffer = ByteArrayOutputStream(PCM_BYTES_PER_SECOND * 5)
        recordedPcm = null
        startTime = SystemClock.elapsedRealtime()
        stage = STAGE_RECORDING
        asrStarted = false
        asrFinished = false
        asrFailed = false
        showPopup()
        handler.postDelayed(tickRunnable, 100)
        vibrate(40)
    }

    private fun handleAudioData(session: Int, data: ByteArray, level: Float) {
        val buffer = pcmBuffer
        if (session != recordSession || buffer == null) {
            return
        }
        buffer.write(data, 0, data.size)
        if (stage == STAGE_RECORDING) {
            waveView.setLevel(level)
        }
        asrManager?.feedAudioData(data)
    }

    private fun handleRecorderError(session: Int, message: String) {
        if (session != recordSession || stage != STAGE_RECORDING) {
            return
        }
        VoiceInputContext.logError("录音失败: $message")
        val buffer = pcmBuffer
        if (buffer != null && buffer.size() > 0) {
            // 例如来电抢走了音频焦点，按手指当前的位置结束录音，保留已经录到的声音
            stopRecord(bottomView.currentZone())
        } else {
            listener.onRecordFail(message)
            dismissPopup()
        }
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (stage != STAGE_RECORDING) {
                return
            }
            val elapsed = SystemClock.elapsedRealtime() - startTime
            if (elapsed >= MAX_DURATION_MS) {
                stopRecord(bottomView.currentZone())
                return
            }
            if (elapsed > MAX_DURATION_MS - COUNT_DOWN_MS) {
                showCountDown(ceil((MAX_DURATION_MS - elapsed) / 1000.0).toInt())
            }
            handler.postDelayed(this, 100)
        }
    }

    /**
     * 结束录音
     *
     * @param zone 松手时手指所在的目标
     */
    private fun stopRecord(zone: Int) {
        if (stage != STAGE_RECORDING) {
            return
        }
        handler.removeCallbacks(tickRunnable)
        recordDuration = SystemClock.elapsedRealtime() - startTime
        stage = if (zone == ZONE_TEXT) STAGE_EDITING else STAGE_DISMISSING
        recorder?.stopRecording()
        recorder = null
        // 录音线程停止前投递的音频还在消息队列中，处理完之后再继续
        val session = recordSession
        handler.post {
            if (session == recordSession) {
                onRecordStopped(zone)
            }
        }
    }

    private fun onRecordStopped(zone: Int) {
        recordedPcm = pcmBuffer?.toByteArray() ?: ByteArray(0)
        pcmBuffer = null
        if (zone == ZONE_TEXT) {
            enterEditing()
            return
        }
        cancelSpeechToText()
        if (zone == ZONE_CANCEL) {
            listener.onRecordFail(REASON_USER_CANCELED)
            dismissPopup()
        } else if (recordDuration < MIN_DURATION_MS) {
            showTooShortTip()
        } else {
            sendVoice()
            dismissPopup()
        }
    }

    /**
     * 把录到的音频编码成 AMR 后回调 onRecordSuccess
     */
    private fun sendVoice() {
        val pcm = recordedPcm
        recordedPcm = null
        if (pcm == null || pcm.isEmpty()) {
            return
        }
        val duration = max(1, (pcm.size.toFloat() / PCM_BYTES_PER_SECOND).roundToInt())
        val audioFile = genAudioFile()
        val failedText = texts.recordFailed
        val callback = listener
        VoiceInputContext.runInBackground {
            val success = PcmAmrEncoder.encode(pcm, pcm.size, audioFile)
            handler.post {
                if (success) {
                    callback.onRecordSuccess(audioFile, duration)
                } else {
                    callback.onRecordFail(failedText)
                }
            }
        }
    }

    private fun genAudioFile(): String {
        val dir = File(context.filesDir, "voice-input")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return File(dir, "${System.currentTimeMillis()}.amr").absolutePath
    }

    /**
     * 停止录音和识别，丢弃录到的音频
     */
    private fun releaseRecording() {
        stage = STAGE_IDLE
        recordSession++
        handler.removeCallbacks(tickRunnable)
        handler.removeCallbacks(dismissRunnable)
        recorder?.stopRecording()
        recorder = null
        cancelSpeechToText()
        pcmBuffer = null
        recordedPcm = null
    }

    private fun vibrate(milliseconds: Long) {
        val v = vibrator ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !v.hasVibrator()) {
            return
        }
        try {
            v.vibrate(VibrationEffect.createOneShot(milliseconds, VibrationEffect.DEFAULT_AMPLITUDE))
        } catch (e: Exception) {
            // 没有振动权限
        }
    }

    // endregion

    // region 转文字

    private fun startSpeechToText() {
        if (asrStarted) {
            return
        }
        asrStarted = true
        val manager = AsrManager(context.applicationContext)
        asrManager = manager
        manager.startRecognitionWithAudioFeed(AsrManager.Callback(
            onPartialResult = { text ->
                if (asrManager === manager) {
                    onSpeechText(text, false)
                }
            },
            onFinalResult = { text ->
                if (asrManager === manager) {
                    onSpeechText(text, true)
                }
            },
            onError = { message ->
                if (asrManager === manager) {
                    onSpeechError(message)
                }
            }
        ))
        // 转文字从开始录音时算起，先补上已经录到的音频
        val buffer = pcmBuffer
        if (asrManager === manager && buffer != null) {
            val recorded = buffer.toByteArray()
            var offset = 0
            while (offset < recorded.size) {
                manager.feedAudioData(recorded.copyOfRange(offset, min(recorded.size, offset + PCM_FRAME_BYTES)))
                offset += PCM_FRAME_BYTES
            }
        }
    }

    private fun onSpeechText(text: String, isFinal: Boolean) {
        if (isFinal) {
            asrFinished = true
            asrManager = null
        }
        setBubbleText(text)
        if (isFinal && stage == STAGE_EDITING) {
            onRecognitionDoneInEditing()
        }
    }

    private fun onSpeechError(message: String) {
        VoiceInputContext.logError("转文字失败: $message")
        // 已经识别出的文字保留，仍然可以编辑后发送
        asrFailed = popupWindow == null || textEditText.length() == 0
        asrFinished = true
        asrManager = null
        updateTextHint()
        if (stage == STAGE_EDITING) {
            onRecognitionDoneInEditing()
        }
    }

    private fun cancelSpeechToText() {
        val manager = asrManager ?: return
        asrManager = null
        manager.cancelRecognition()
    }

    // endregion

    // region 浮层

    private val preDrawListener = object : ViewTreeObserver.OnPreDrawListener {
        override fun onPreDraw(): Boolean {
            popupRootLayout.viewTreeObserver.removeOnPreDrawListener(this)
            if (stage == STAGE_IDLE) {
                return true
            }
            onPopupLaidOut()
            // 控件位置变了，跳过这一帧，下一帧按新位置绘制
            return false
        }
    }

    private fun showPopup() {
        if (popupWindow == null) {
            createPopup()
        }
        val popup = popupWindow ?: return
        resetPopupViews()
        layoutReady = false
        popup.isFocusable = false
        try {
            popup.showAtLocation(activity.window.decorView, Gravity.TOP or Gravity.START, 0, 0)
        } catch (e: Exception) {
            // Activity 正在销毁等
            VoiceInputContext.logError("show popup failed", e)
            return
        }
        // 浮层完成布局、拿到尺寸后再计算各控件的位置，在这之前所有控件都是透明的
        popupRootLayout.viewTreeObserver.addOnPreDrawListener(preDrawListener)
    }

    private fun createPopup() {
        val root = FrameLayout(context)
        root.clipChildren = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 浮层本身按深色设计，不让系统的强制深色模式反转浮层的颜色
            root.isForceDarkAllowed = false
        }
        val backgroundDrawable = VoiceInputBackground(dpf(130f))
        root.background = backgroundDrawable
        this.backgroundDrawable = backgroundDrawable
        popupRootLayout = root

        val bottom = VoiceRecordBottomView(context)
        root.addView(bottom, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        bottomView = bottom

        val countDown = TextView(context)
        countDown.gravity = Gravity.CENTER
        countDown.setTextColor(0xCCFFFFFF.toInt())
        countDown.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        countDown.visibility = View.INVISIBLE
        root.addView(countDown, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
        countDownTextView = countDown

        // paddingBottom 包含气泡底部 8dp 高的尖角
        val bubble = VoiceBubbleLayout(context)
        bubble.setPadding(dp(20f), dp(18f), dp(20f), dp(26f))
        root.addView(bubble, FrameLayout.LayoutParams(dp(180f), dp(86f), Gravity.BOTTOM or Gravity.START))
        bubbleLayout = bubble

        val editText = EditText(context)
        editText.background = null
        editText.isFocusable = false
        editText.gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            editText.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        // inputType 要在 maxLines 之前设：设多行 inputType 时 TextView 会把 maxLines 重置成不限
        editText.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        editText.maxLines = 6
        editText.minHeight = dp(30f)
        editText.setPadding(0, 0, 0, 0)
        editText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
        bubble.addView(editText, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        textEditText = editText

        val icon = VoiceIconDrawable(context, VoiceIconDrawable.WARNING)
        val hint = TextView(context)
        hint.alpha = 0f
        hint.setCompoundDrawablesRelativeWithIntrinsicBounds(icon, null, null, null)
        hint.compoundDrawablePadding = dp(6f)
        hint.gravity = Gravity.CENTER_VERTICAL
        hint.maxLines = 2
        hint.setTextColor(Color.WHITE)
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
        bubble.addView(hint, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        hintIcon = icon
        hintTextView = hint

        val wave = VoiceWaveView(context)
        bubble.addView(wave, FrameLayout.LayoutParams(dp(82f), dp(20f), Gravity.TOP or Gravity.START))
        waveView = wave

        // 编辑文字时的底部按钮：取消、发送原语音、发送
        val actions = LinearLayout(context)
        actions.orientation = LinearLayout.HORIZONTAL
        actions.setPaddingRelative(dp(16f), 0, dp(24f), 0)
        actions.visibility = View.INVISIBLE
        root.addView(actions, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
        editActionsLayout = actions

        val cancelImage = createCircleButton(VoiceIconDrawable.CLOSE, dp(21f))
        val cancelLabel = createActionLabel()
        actions.addView(createActionLayout(cancelImage, cancelLabel), LinearLayout.LayoutParams(dp(96f), ViewGroup.LayoutParams.WRAP_CONTENT))
        cancelLabelView = cancelLabel

        val sendVoiceImage = createCircleButton(VoiceIconDrawable.SOUND, dp(20f))
        val sendVoiceLabel = createActionLabel()
        val sendVoice = createActionLayout(sendVoiceImage, sendVoiceLabel)
        val sendVoiceParams = LinearLayout.LayoutParams(dp(96f), ViewGroup.LayoutParams.WRAP_CONTENT)
        sendVoiceParams.marginStart = dp(10f)
        actions.addView(sendVoice, sendVoiceParams)
        sendVoiceImageView = sendVoiceImage
        sendVoiceLabelView = sendVoiceLabel
        sendVoiceLayout = sendVoice

        actions.addView(Space(context), LinearLayout.LayoutParams(0, 0, 1f))

        val sendText = TextView(context)
        sendText.background = createSendButtonBackground()
        sendText.gravity = Gravity.CENTER
        sendText.setTextColor(ColorStateList(
            arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
            intArrayOf(0xFF737373.toInt(), 0xFF111111.toInt())
        ))
        sendText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
        actions.addView(sendText, LinearLayout.LayoutParams(dp(124f), dp(74f)))
        sendTextButton = sendText

        cancelImage.setOnClickListener { onEditCancelClick() }
        sendVoiceImage.setOnClickListener { onSendVoiceClick() }
        sendText.setOnClickListener { onSendTextClick() }
        editText.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {
            }

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
            }

            override fun afterTextChanged(s: Editable?) {
                if (stage == STAGE_EDITING && asrFinished && bubbleState == BUBBLE_EDIT) {
                    updateEditActions()
                    animateBubbleTo(BUBBLE_EDIT)
                }
            }
        })
        // 编辑文字时弹出软键盘，把气泡和按钮顶到软键盘上方
        root.setOnApplyWindowInsetsListener { v, insets ->
            val imeBottom = imeBottom(insets)
            val padding = if (stage == STAGE_EDITING && imeBottom > 0) max(0, imeBottom - editActionsBottomMargin.roundToInt() + dp(12f)) else 0
            if (v.paddingBottom != padding) {
                v.setPadding(0, 0, 0, padding)
                if (stage == STAGE_EDITING && layoutReady) {
                    // 深灰背景跟着气泡移动
                    panelAnimator?.cancel()
                    backgroundDrawable.panelTop = getEditPanelTop()
                }
            }
            insets
        }

        val popup = PopupWindow(root, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        popup.isTouchable = true
        popup.isOutsideTouchable = false
        // 让浮层延伸到状态栏
        popup.isClippingEnabled = false
        popup.animationStyle = 0
        popup.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or WindowManager.LayoutParams.SOFT_INPUT_STATE_HIDDEN
        popup.setOnDismissListener { onPopupDismissed() }
        popupWindow = popup
    }

    private fun createCircleButton(iconType: Int, padding: Int): ImageView {
        val background = StateListDrawable()
        background.addState(intArrayOf(android.R.attr.state_pressed), createShape(GradientDrawable.OVAL, 0xFF6A6A6A.toInt()))
        background.addState(intArrayOf(), createShape(GradientDrawable.OVAL, 0xFF575757.toInt()))
        val view = ImageView(context)
        view.background = background
        view.setPadding(padding, padding, padding, padding)
        view.scaleType = ImageView.ScaleType.FIT_CENTER
        view.setImageDrawable(VoiceIconDrawable(context, iconType))
        return view
    }

    private fun createActionLabel(): TextView {
        val label = TextView(context)
        label.maxLines = 1
        label.setTextColor(0xFFBDBDBD.toInt())
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        return label
    }

    private fun createActionLayout(button: View, label: TextView): LinearLayout {
        val layout = LinearLayout(context)
        layout.orientation = LinearLayout.VERTICAL
        layout.gravity = Gravity.CENTER_HORIZONTAL
        layout.addView(button, LinearLayout.LayoutParams(dp(66f), dp(66f)))
        val labelParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        labelParams.topMargin = dp(10f)
        layout.addView(label, labelParams)
        return layout
    }

    private fun createSendButtonBackground(): StateListDrawable {
        val background = StateListDrawable()
        background.addState(intArrayOf(-android.R.attr.state_enabled), createShape(GradientDrawable.RECTANGLE, 0xFF4E4E4E.toInt()))
        background.addState(intArrayOf(android.R.attr.state_pressed), createShape(GradientDrawable.RECTANGLE, 0xFFBDBDBD.toInt()))
        background.addState(intArrayOf(), createShape(GradientDrawable.RECTANGLE, 0xFFDADADA.toInt()))
        return background
    }

    private fun createShape(shape: Int, color: Int): GradientDrawable {
        val drawable = GradientDrawable()
        drawable.shape = shape
        drawable.setColor(color)
        if (shape == GradientDrawable.RECTANGLE) {
            drawable.cornerRadius = dpf(100f)
        }
        return drawable
    }

    private fun resetPopupViews() {
        cancelPopupAnimations()
        backgroundProgress = 0f
        backgroundDrawable.setProgress(0f)
        popupRootLayout.setPadding(0, 0, 0, 0)
        bottomView.reset()
        bottomView.setSpeechToTextEnabled(speechToTextEnabled)
        val t = texts
        bottomView.setLabels(t.voice, t.releaseToSend, t.cancel, t.releaseToCancel, t.slideToText, t.releaseToEdit)
        cancelLabelView.text = t.cancel
        sendVoiceLabelView.text = t.sendVoice
        sendTextButton.text = t.send
        textEditText.setTextColor(bubbleContentColor)
        textEditText.setHintTextColor(setAlphaComponent(bubbleContentColor, 0x99))
        textEditText.highlightColor = setAlphaComponent(bubbleContentColor, 0x4D)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val cursor = GradientDrawable()
            cursor.setColor(bubbleContentColor)
            cursor.setSize(dp(2f), 0)
            textEditText.textCursorDrawable = cursor
        }
        countDownTextView.visibility = View.INVISIBLE
        bubbleLayout.alpha = 0f
        bubbleLayout.scaleX = 1f
        bubbleLayout.scaleY = 1f
        bubbleLayout.translationX = 0f
        bubbleLayout.translationY = 0f
        hintTextView.alpha = 0f
        waveView.setLoading(false)
        waveView.setLevel(0f)
        textEditText.isFocusable = false
        textEditText.isFocusableInTouchMode = false
        textEditText.setText("")
        textEditText.hint = null
        editActionsLayout.alpha = 1f
        editActionsLayout.visibility = View.INVISIBLE
        bubbleState = BUBBLE_SEND
    }

    private fun cancelPopupAnimations() {
        backgroundAnimator?.cancel()
        panelAnimator?.cancel()
        bubbleAnimator?.cancel()
        shakeAnimator?.cancel()
        bubbleLayout.animate().cancel()
        countDownTextView.animate().cancel()
        editActionsLayout.animate().cancel()
        for (i in 0 until editActionsLayout.childCount) {
            editActionsLayout.getChildAt(i).animate().cancel()
        }
    }

    private fun onPopupLaidOut() {
        val width = popupRootLayout.width
        val height = popupRootLayout.height
        popupRootLayout.getLocationOnScreen(popupLocation)
        // 手机上操作区就是整个浮层
        stageLeft = 0f
        stageWidth = width.toFloat()
        // 底部弧形区域要盖住按住说话的按钮，手指按下时就在「松开 发送」区域内
        val buttonTop = buttonTopRaw - popupLocation[1]
        val arcTop = min(height - dpf(110f), buttonTop - dpf(16f))
        // 排查坐标用：正常时 touch 的 y 接近屏幕高度（height / density）减去 60 左右，buttonTop 比它小十几
        VoiceInputContext.log("popup laid out, size ${width}x$height px, location ${popupLocation[0]},${popupLocation[1]}, density $density, " +
            "touch ${touchRawX / density},${touchRawY / density} dp, buttonTop ${buttonTopRaw / density} dp")
        bottomView.setStage(stageLeft, stageLeft + stageWidth, arcTop)
        // 录音时深灰背景从弧形按钮处开始，编辑文字时再升到气泡下方
        backgroundDrawable.setStage(stageLeft, stageLeft + stageWidth)
        backgroundDrawable.panelTop = bottomView.pillTop() + dpf(18f)

        // 气泡的尖角固定在按钮上方，内容变多时向上长高
        bubbleBottomMargin = height - max(dpf(160f), bottomView.pillTop() - dpf(141f))
        editActionsBottomMargin = max(dpf(16f), height - arcTop - dpf(20f))

        var lp = countDownTextView.layoutParams as FrameLayout.LayoutParams
        lp.leftMargin = stageLeft.roundToInt()
        lp.width = stageWidth.roundToInt()
        lp.bottomMargin = (bubbleBottomMargin - dpf(44f)).roundToInt()
        countDownTextView.layoutParams = lp

        lp = editActionsLayout.layoutParams as FrameLayout.LayoutParams
        lp.leftMargin = stageLeft.roundToInt()
        lp.width = stageWidth.roundToInt()
        lp.bottomMargin = editActionsBottomMargin.roundToInt()
        editActionsLayout.layoutParams = lp

        layoutReady = true
        val frame = BubbleFrame()
        computeBubbleFrame(bubbleState, frame)
        applyBubbleFrame(frame, frame, 1f)
        playEnterAnimation()
        // 手指在浮层布局好之前可能已经滑到别的目标上了
        updateZone()
    }

    private fun playEnterAnimation() {
        animateBackground(1f, 200, null)
        bottomView.show()
        bubbleLayout.alpha = 0f
        bubbleLayout.scaleX = 0.6f
        bubbleLayout.scaleY = 0.6f
        bubbleLayout.translationY = dpf(24f)
        bubbleLayout.animate()
            .alpha(1f)
            .scaleX(1f)
            .scaleY(1f)
            .translationY(0f)
            .setStartDelay(40)
            .setDuration(340)
            .setInterpolator(OvershootInterpolator(1.2f))
            .start()
    }

    private fun updateZone() {
        if (!layoutReady || stage != STAGE_RECORDING) {
            return
        }
        val zone = bottomView.zoneAt(touchRawX - popupLocation[0], touchRawY - popupLocation[1])
        if (zone == bottomView.currentZone()) {
            return
        }
        bottomView.selectZone(zone)
        bottomView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        when (zone) {
            ZONE_CANCEL -> animateBubbleTo(BUBBLE_CANCEL)
            ZONE_TEXT -> {
                startSpeechToText()
                animateBubbleTo(BUBBLE_TEXT)
            }
            else -> animateBubbleTo(BUBBLE_SEND)
        }
    }

    /**
     * 气泡从当前的位置、大小、颜色平滑过渡到目标形态；内容变化时用同一个形态再调用一次，气泡会平滑地改变高度
     */
    private fun animateBubbleTo(state: Int) {
        val changed = bubbleState != state
        bubbleState = state
        if (!layoutReady) {
            return
        }
        val from = bubbleFrame.copy()
        val to = BubbleFrame()
        computeBubbleFrame(state, to)
        bubbleAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(0f, 1f)
        animator.duration = if (changed) 320L else 180L
        animator.interpolator = PathInterpolator(0.2f, 0f, 0f, 1f)
        animator.addUpdateListener { animation -> applyBubbleFrame(from, to, animation.animatedValue as Float) }
        bubbleAnimator = animator
        animator.start()
    }

    private fun computeBubbleFrame(state: Int, frame: BubbleFrame) {
        val tailHeight = bubbleLayout.tailHeight
        val maxWidth = stageWidth - dpf(32f)
        val sendWidth = min(maxWidth, max(dpf(160f), stageWidth * 0.475f))
        val tailTargetX: Float
        frame.waveColor = bubbleContentColor
        frame.textAlpha = 0f
        frame.hintAlpha = 0f
        frame.textBottomMargin = dpf(20f)
        when (state) {
            BUBBLE_CANCEL -> {
                // 缩成红色的小方块，移到「取消」上方
                frame.width = dpf(78f)
                frame.height = dpf(78f) + tailHeight
                tailTargetX = bottomView.cancelCenterX()
                frame.left = max(stageLeft + dpf(16f), tailTargetX - frame.width / 2)
                frame.color = BUBBLE_COLOR_RED
                frame.waveColor = Color.WHITE
                frame.waveWidth = dpf(34f)
                frame.waveHeight = dpf(16f)
                frame.waveCenterX = frame.width / 2
                frame.waveCenterY = (frame.height - tailHeight) / 2
                frame.waveAlpha = 1f
            }
            BUBBLE_TEXT, BUBBLE_EDIT, BUBBLE_NO_TEXT -> {
                // 展开成整行宽度显示文字，声波缩小到右下角，识别完成后消失；没有识别到文字时变成红色的提示
                val noText = state == BUBBLE_NO_TEXT
                val showWave = state == BUBBLE_TEXT || (state == BUBBLE_EDIT && !asrFinished)
                frame.left = stageLeft + dpf(16f)
                frame.width = maxWidth
                frame.textBottomMargin = if (showWave) dpf(20f) else 0f
                frame.height = measureBubbleHeight(frame.width, frame.textBottomMargin)
                frame.color = if (noText) BUBBLE_COLOR_RED else bubbleColor
                frame.waveColor = if (noText) Color.WHITE else bubbleContentColor
                frame.waveWidth = dpf(34f)
                frame.waveHeight = dpf(16f)
                frame.waveCenterX = frame.width - dpf(20f) - frame.waveWidth / 2
                frame.waveCenterY = frame.height - tailHeight - dpf(18f)
                frame.waveAlpha = if (showWave) 1f else 0f
                frame.textAlpha = if (noText) 0f else 1f
                frame.hintAlpha = if (noText) 1f else 0f
                // 和微信一样，整行宽度的气泡尖角固定在同一个位置，转文字、编辑、没有识别到文字之间切换时不动
                tailTargetX = stageLeft + stageWidth * 0.755f
            }
            BUBBLE_TOO_SHORT -> {
                // 保持松开发送时的样子，声波换成提示，提示放不下时加宽
                frame.width = min(maxWidth, max(sendWidth, measureHintWidth(maxWidth)))
                frame.height = dpf(78f) + tailHeight
                frame.left = stageLeft + (stageWidth - frame.width) / 2
                frame.color = bubbleColor
                frame.waveWidth = sendWidth * 0.46f
                frame.waveHeight = dpf(20f)
                frame.waveCenterX = frame.width / 2
                frame.waveCenterY = (frame.height - tailHeight) / 2
                frame.waveAlpha = 0f
                frame.hintAlpha = 1f
                tailTargetX = frame.left + frame.width / 2
            }
            else -> {
                frame.width = sendWidth
                frame.height = dpf(78f) + tailHeight
                frame.left = stageLeft + (stageWidth - frame.width) / 2
                frame.color = bubbleColor
                frame.waveWidth = frame.width * 0.46f
                frame.waveHeight = dpf(20f)
                frame.waveCenterX = frame.width / 2
                frame.waveCenterY = (frame.height - tailHeight) / 2
                frame.waveAlpha = 1f
                tailTargetX = frame.left + frame.width / 2
            }
        }
        frame.tailX = tailTargetX - frame.left
    }

    private fun applyBubbleFrame(from: BubbleFrame, to: BubbleFrame, fraction: Float) {
        val frame = bubbleFrame
        frame.left = lerp(from.left, to.left, fraction)
        frame.width = lerp(from.width, to.width, fraction)
        frame.height = lerp(from.height, to.height, fraction)
        frame.tailX = lerp(from.tailX, to.tailX, fraction)
        frame.color = argbEvaluator.evaluate(fraction, from.color, to.color) as Int
        frame.waveColor = argbEvaluator.evaluate(fraction, from.waveColor, to.waveColor) as Int
        frame.waveWidth = lerp(from.waveWidth, to.waveWidth, fraction)
        frame.waveHeight = lerp(from.waveHeight, to.waveHeight, fraction)
        frame.waveCenterX = lerp(from.waveCenterX, to.waveCenterX, fraction)
        frame.waveCenterY = lerp(from.waveCenterY, to.waveCenterY, fraction)
        frame.waveAlpha = lerp(from.waveAlpha, to.waveAlpha, fraction)
        frame.textAlpha = lerp(from.textAlpha, to.textAlpha, fraction)
        frame.hintAlpha = lerp(from.hintAlpha, to.hintAlpha, fraction)
        frame.textBottomMargin = lerp(from.textBottomMargin, to.textBottomMargin, fraction)

        val lp = bubbleLayout.layoutParams as FrameLayout.LayoutParams
        lp.leftMargin = frame.left.roundToInt()
        lp.width = frame.width.roundToInt()
        lp.height = frame.height.roundToInt()
        lp.bottomMargin = bubbleBottomMargin.roundToInt()
        bubbleLayout.layoutParams = lp
        bubbleLayout.pivotX = frame.width / 2
        bubbleLayout.pivotY = frame.height
        bubbleLayout.setBubbleColor(frame.color)
        bubbleLayout.setTailX(frame.tailX)

        val waveLp = waveView.layoutParams as FrameLayout.LayoutParams
        waveLp.width = frame.waveWidth.roundToInt()
        waveLp.height = frame.waveHeight.roundToInt()
        waveView.layoutParams = waveLp
        waveView.translationX = frame.waveCenterX - frame.waveWidth / 2 - bubbleLayout.paddingLeft
        waveView.translationY = frame.waveCenterY - frame.waveHeight / 2 - bubbleLayout.paddingTop
        waveView.setBarColor(frame.waveColor)
        waveView.alpha = frame.waveAlpha

        val textLp = textEditText.layoutParams as FrameLayout.LayoutParams
        textLp.bottomMargin = frame.textBottomMargin.roundToInt()
        textEditText.layoutParams = textLp
        textEditText.alpha = frame.textAlpha
        // 提示淡入时轻微上浮
        hintTextView.alpha = frame.hintAlpha
        hintTextView.translationY = (1 - frame.hintAlpha) * dpf(6f)
    }

    /**
     * 气泡按指定宽度显示当前文字时的高度
     */
    private fun measureBubbleHeight(width: Float, textBottomMargin: Float): Float {
        val lp = textEditText.layoutParams as FrameLayout.LayoutParams
        val bottomMargin = lp.bottomMargin
        lp.bottomMargin = textBottomMargin.roundToInt()
        bubbleLayout.measure(View.MeasureSpec.makeMeasureSpec(width.roundToInt(), View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        lp.bottomMargin = bottomMargin
        return bubbleLayout.measuredHeight.toFloat()
    }

    /**
     * 气泡完整显示提示所需的宽度
     */
    private fun measureHintWidth(maxWidth: Float): Float {
        val horizontalPadding = bubbleLayout.paddingLeft + bubbleLayout.paddingRight
        hintTextView.measure(View.MeasureSpec.makeMeasureSpec(max(0, maxWidth.roundToInt() - horizontalPadding), View.MeasureSpec.AT_MOST),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        return (hintTextView.measuredWidth + horizontalPadding).toFloat()
    }

    private fun setBubbleText(text: String) {
        if (popupWindow == null) {
            return
        }
        if (!TextUtils.equals(textEditText.text, text)) {
            textEditText.setText(text)
            textEditText.setSelection(text.length)
            if (bubbleState == BUBBLE_TEXT || bubbleState == BUBBLE_EDIT) {
                animateBubbleTo(bubbleState)
                textEditText.post { scrollTextToEnd() }
            }
        }
        updateTextHint()
    }

    /**
     * 文字超过最大行数时，滚动到最新识别出的文字
     */
    private fun scrollTextToEnd() {
        val layout = textEditText.layout ?: return
        val visibleHeight = textEditText.height - textEditText.totalPaddingTop - textEditText.totalPaddingBottom
        textEditText.scrollTo(0, max(0, layout.height - visibleHeight))
    }

    private fun updateTextHint() {
        if (popupWindow == null) {
            return
        }
        // 按住转文字时出错，在气泡里提示；松手后没有文字时换成红色的提示气泡
        textEditText.hint = if (asrFailed && stage == STAGE_RECORDING) texts.recognizeFailed else null
    }

    private fun showTooShortTip() {
        showHint(texts.tooShort, bubbleContentColor)
        animateBubbleTo(BUBBLE_TOO_SHORT)
        val shake = ObjectAnimator.ofFloat(bubbleLayout, View.TRANSLATION_X,
            0f, -dpf(10f), dpf(10f), -dpf(7f), dpf(7f), -dpf(3f), dpf(3f), 0f)
        shake.duration = 420
        shake.startDelay = 100
        shakeAnimator = shake
        shake.start()
        handler.postDelayed(dismissRunnable, 1000)
    }

    /**
     * 设置气泡里的提示，图标和文字同色
     */
    private fun showHint(text: String, color: Int) {
        hintTextView.text = text
        hintTextView.setTextColor(color)
        hintIcon.setColor(color)
    }

    private fun showCountDown(seconds: Int) {
        countDownTextView.text = texts.countDown.replace("%d", seconds.toString())
        if (countDownTextView.visibility != View.VISIBLE) {
            countDownTextView.alpha = 0f
            countDownTextView.visibility = View.VISIBLE
            countDownTextView.animate().alpha(1f).setDuration(200).start()
        }
    }

    /**
     * 在「转文字」上松手：底部按钮落下，换成取消、发送原语音、发送；识别结果全部返回后可以编辑文字
     */
    private fun enterEditing() {
        countDownTextView.animate().alpha(0f).setDuration(150).start()
        bottomView.hide(null)
        animatePanelTop(getEditPanelTop(), 360)
        // 浮层获取焦点后才能编辑文字
        val popup = popupWindow
        if (popup != null && popup.isShowing) {
            popup.isFocusable = true
            popup.update()
        }
        updateTextHint()
        updateEditActions()
        showEditActions()
        val manager = asrManager
        if (manager != null) {
            // 录音已经停止，声波换成等待动画，剩余识别结果返回后回调 onFinalResult
            waveView.setLoading(true)
            animateBubbleTo(BUBBLE_EDIT)
            manager.stopRecognition()
        } else {
            // 识别已经结束，或者出错了
            asrFinished = true
            onRecognitionDoneInEditing()
        }
    }

    private fun onRecognitionDoneInEditing() {
        waveView.setLoading(false)
        updateTextHint()
        updateEditActions()
        if (textEditText.length() == 0) {
            // 没有识别到文字：红色提示，只能取消或者发送原语音
            showHint(if (asrFailed) texts.recognizeFailed else texts.noText, Color.WHITE)
            animateBubbleTo(BUBBLE_NO_TEXT)
            return
        }
        textEditText.isFocusableInTouchMode = true
        textEditText.requestFocus()
        textEditText.setSelection(textEditText.length())
        animateBubbleTo(BUBBLE_EDIT)
    }

    private fun isVoiceAvailable(): Boolean {
        val pcm = recordedPcm
        return pcm != null && pcm.isNotEmpty() && recordDuration >= MIN_DURATION_MS
    }

    private fun updateEditActions() {
        sendTextButton.isEnabled = asrFinished && textEditText.text.toString().trim().isNotEmpty()
        sendVoiceImageView.isEnabled = isVoiceAvailable()
    }

    private fun showEditActions() {
        editActionsLayout.alpha = 1f
        editActionsLayout.visibility = View.VISIBLE
        for (i in 0 until editActionsLayout.childCount) {
            val child = editActionsLayout.getChildAt(i)
            val alpha = if (child === sendVoiceLayout && !isVoiceAvailable()) 0.4f else 1f
            child.alpha = 0f
            child.translationY = dpf(28f)
            // 等弧形按钮大部分落下后再升起，两组按钮不在同一时间重叠
            child.animate()
                .alpha(alpha)
                .translationY(0f)
                .setStartDelay(140 + i * 40L)
                .setDuration(300)
                .setInterpolator(DecelerateInterpolator(2f))
                .start()
        }
    }

    private fun onEditCancelClick() {
        if (stage != STAGE_EDITING) {
            return
        }
        cancelSpeechToText()
        listener.onRecordFail(REASON_USER_CANCELED)
        dismissPopup()
    }

    private fun onSendVoiceClick() {
        if (stage != STAGE_EDITING || !isVoiceAvailable()) {
            return
        }
        cancelSpeechToText()
        sendVoice()
        dismissPopup()
    }

    private fun onSendTextClick() {
        if (stage != STAGE_EDITING) {
            return
        }
        val text = textEditText.text.toString().trim()
        if (text.isEmpty()) {
            return
        }
        listener.onSendText(text)
        dismissPopup()
    }

    /**
     * 播放退出动画后关闭浮层
     */
    private fun dismissPopup() {
        handler.removeCallbacks(dismissRunnable)
        val popup = popupWindow
        if (popup == null || !popup.isShowing) {
            releaseRecording()
            return
        }
        stage = STAGE_DISMISSING
        hideKeyboard()
        bubbleAnimator?.cancel()
        bottomView.hide(null)
        bubbleLayout.animate()
            .alpha(0f)
            .scaleX(0.85f)
            .scaleY(0.85f)
            .translationY(0f)
            .setStartDelay(0)
            .setDuration(180)
            .setInterpolator(AccelerateInterpolator())
            .start()
        countDownTextView.animate().alpha(0f).setDuration(150).start()
        editActionsLayout.animate().alpha(0f).setDuration(150).start()
        animateBackground(0f, 240) { dismissNow() }
    }

    /**
     * 立即关闭浮层，停止录音和识别，不回调
     */
    private fun dismissNow() {
        handler.removeCallbacks(dismissRunnable)
        if (popupWindow != null) {
            popupRootLayout.viewTreeObserver.removeOnPreDrawListener(preDrawListener)
            cancelPopupAnimations()
        }
        // 先置为空闲，关闭浮层时不再当作用户取消
        releaseRecording()
        layoutReady = false
        val popup = popupWindow
        if (popup != null && popup.isShowing) {
            hideKeyboard()
            try {
                popup.dismiss()
            } catch (e: Exception) {
                // 窗口已经随 Activity 销毁
                VoiceInputContext.logError("dismiss popup failed", e)
            }
        }
    }

    private fun onPopupDismissed() {
        if (stage == STAGE_IDLE) {
            return
        }
        // 编辑文字时按返回键关闭浮层，等同于取消
        if (stage == STAGE_EDITING) {
            listener.onRecordFail(REASON_USER_CANCELED)
        }
        popupRootLayout.viewTreeObserver.removeOnPreDrawListener(preDrawListener)
        cancelPopupAnimations()
        releaseRecording()
        layoutReady = false
    }

    private fun hideKeyboard() {
        if (popupWindow == null) {
            return
        }
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager ?: return
        imm.hideSoftInputFromWindow(textEditText.windowToken, 0)
    }

    private fun animateBackground(progress: Float, duration: Long, endAction: (() -> Unit)?) {
        backgroundAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(backgroundProgress, progress)
        animator.duration = duration
        animator.addUpdateListener { animation ->
            backgroundProgress = animation.animatedValue as Float
            backgroundDrawable.setProgress(backgroundProgress)
        }
        animator.addListener(EndListener(endAction))
        backgroundAnimator = animator
        animator.start()
    }

    /**
     * 深灰背景的上边缘平滑移动到指定位置
     */
    private fun animatePanelTop(panelTop: Float, duration: Long) {
        panelAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(backgroundDrawable.panelTop, panelTop)
        animator.duration = duration
        animator.interpolator = PathInterpolator(0.2f, 0f, 0f, 1f)
        animator.addUpdateListener { animation -> backgroundDrawable.panelTop = animation.animatedValue as Float }
        panelAnimator = animator
        animator.start()
    }

    /**
     * 编辑文字时深灰背景完全不透明处，在气泡下边缘稍上方
     */
    private fun getEditPanelTop(): Float {
        return popupRootLayout.height - popupRootLayout.paddingBottom - bubbleBottomMargin - bubbleLayout.tailHeight - dpf(5f)
    }

    private fun imeBottom(insets: WindowInsets): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return insets.getInsets(WindowInsets.Type.ime()).bottom
        }
        // 老系统拿不到单独的软键盘高度：系统窗口底部减去稳定的底部（导航栏），剩下的就是软键盘
        @Suppress("DEPRECATION")
        val bottom = insets.systemWindowInsetBottom - insets.stableInsetBottom
        return max(0, bottom)
    }

    private fun dp(value: Float): Int {
        return (value * density).roundToInt()
    }

    private fun dpf(value: Float): Float {
        return value * density
    }

    // endregion

    /**
     * 气泡某一形态的位置、大小和内容，坐标相对于浮层，声波和尖角的坐标相对于气泡
     */
    private class BubbleFrame {
        var left = 0f
        var width = 0f
        var height = 0f
        var tailX = 0f
        var color = 0
        var waveColor = 0
        var waveWidth = 0f
        var waveHeight = 0f
        var waveCenterX = 0f
        var waveCenterY = 0f
        var waveAlpha = 0f
        var textAlpha = 0f
        var hintAlpha = 0f
        var textBottomMargin = 0f

        fun copy(): BubbleFrame {
            val frame = BubbleFrame()
            frame.left = left
            frame.width = width
            frame.height = height
            frame.tailX = tailX
            frame.color = color
            frame.waveColor = waveColor
            frame.waveWidth = waveWidth
            frame.waveHeight = waveHeight
            frame.waveCenterX = waveCenterX
            frame.waveCenterY = waveCenterY
            frame.waveAlpha = waveAlpha
            frame.textAlpha = textAlpha
            frame.hintAlpha = hintAlpha
            frame.textBottomMargin = textBottomMargin
            return frame
        }
    }
}
