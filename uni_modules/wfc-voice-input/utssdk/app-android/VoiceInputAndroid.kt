/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.app.Activity

/**
 * index.uts 调用的入口，把输入框语音输入（[AsrManager]）和按住说话（[AudioRecorderPanel]）的回调转成事件，
 * 对应鸿蒙端的 voiceInput.ets。
 *
 * 所有入口都先切到主线程（原因见 VoiceInputContext.kt 文件头）；
 * 只有 [isAsrRecognizing] 要同步返回，读的是 @Volatile 状态。
 */
object VoiceInputAndroid {

    fun setup(activityProvider: () -> Activity?, permissionRequester: ((Boolean) -> Unit) -> Unit, logger: (String) -> Unit) {
        VoiceInputContext.setup(activityProvider, permissionRequester, logger)
    }

    fun setListener(listener: (String, String) -> Unit) {
        VoiceInputContext.setEventListener(listener)
    }

    fun configure(optionsJson: String) {
        VoiceInputContext.applyOptions(optionsJson)
    }

    fun provideAuthCode(requestId: Number, authCode: String, errorCode: Number) {
        VoiceInputContext.onAuthCodeProvided(requestId.toInt(), authCode, errorCode.toInt())
    }

    // region 输入框语音输入

    @Volatile
    private var asrManager: AsrManager? = null

    // 正在申请麦克风权限
    @Volatile
    private var asrRequestingPermission = false

    // 每次开始 / 取消加 1，申请权限回来时据此判断期间是否已经取消
    private var asrStartToken = 0

    fun startAsr() {
        VoiceInputContext.runOnMain {
            startAsrOnMain()
        }
    }

    private fun startAsrOnMain() {
        if (isAsrRecognizing()) {
            return
        }
        val activity = VoiceInputContext.activity()
        if (activity == null) {
            VoiceInputContext.fireEvent("asrError", "no activity")
            return
        }
        asrStartToken++
        val token = asrStartToken
        if (VoiceInputContext.isMicrophoneGranted(activity)) {
            startAsrNow(activity)
            return
        }
        asrRequestingPermission = true
        VoiceInputContext.requestMicrophonePermission { granted ->
            // token 变了说明申请权限期间已经取消了
            if (token == asrStartToken) {
                asrRequestingPermission = false
                if (granted) {
                    startAsrNow(VoiceInputContext.activity() ?: activity)
                } else {
                    VoiceInputContext.fireEvent("asrPermissionDenied")
                }
            }
        }
    }

    private fun startAsrNow(activity: Activity) {
        val manager = asrManager ?: AsrManager(activity.applicationContext).also { asrManager = it }
        manager.startRecognition(AsrManager.Callback(
            onPartialResult = { text -> VoiceInputContext.fireEvent("asrPartial", text) },
            onFinalResult = { text -> VoiceInputContext.fireEvent("asrFinal", text) },
            onError = { message -> VoiceInputContext.fireEvent("asrError", message) }
        ))
    }

    fun stopAsr() {
        VoiceInputContext.runOnMain {
            if (asrRequestingPermission) {
                cancelAsrOnMain()
            } else {
                asrManager?.stopRecognition()
            }
        }
    }

    fun cancelAsr() {
        VoiceInputContext.runOnMain {
            cancelAsrOnMain()
        }
    }

    private fun cancelAsrOnMain() {
        asrStartToken++
        asrRequestingPermission = false
        asrManager?.cancelRecognition()
    }

    /**
     * 是否正在识别，包括申请权限、停止录音后等待剩余识别结果的阶段
     */
    fun isAsrRecognizing(): Boolean {
        return asrRequestingPermission || asrManager?.isRecognizing() == true
    }

    // endregion

    // region 按住说话

    private var panel: AudioRecorderPanel? = null

    private val holdListener = object : AudioRecorderPanel.Listener {
        override fun onRecordSuccess(audioFile: String, duration: Int) {
            VoiceInputContext.fireEvent("holdRecordSuccess", audioFile, duration)
        }

        override fun onRecordFail(reason: String) {
            VoiceInputContext.fireEvent("holdRecordFail", reason)
        }

        override fun onSendText(text: String) {
            VoiceInputContext.fireEvent("holdSendText", text)
        }

        override fun onPermissionDenied() {
            VoiceInputContext.fireEvent("holdPermissionDenied")
        }
    }

    /**
     * 按住说话按钮的触摸转发，坐标是**屏幕坐标**，单位 dp（uni-app x 的逻辑像素）
     */
    fun holdTouchDown(x: Number, y: Number, buttonTop: Number) {
        val touchX = x.toFloat()
        val touchY = y.toFloat()
        val top = buttonTop.toFloat()
        VoiceInputContext.runOnMain {
            val activity = VoiceInputContext.activity()
            if (activity == null) {
                VoiceInputContext.log("holdTouchDown: no activity")
            } else {
                var current = panel
                if (current == null || current.activity !== activity) {
                    // Activity 重建过：旧浮层挂在旧窗口上，换一个
                    current?.release()
                    current = AudioRecorderPanel(activity, holdListener)
                    panel = current
                }
                current.onTouchDown(touchX, touchY, top)
            }
        }
    }

    fun holdTouchMove(x: Number, y: Number) {
        val touchX = x.toFloat()
        val touchY = y.toFloat()
        VoiceInputContext.runOnMain {
            panel?.onTouchMove(touchX, touchY)
        }
    }

    fun holdTouchUp() {
        VoiceInputContext.runOnMain {
            panel?.onTouchUp()
        }
    }

    /**
     * 录音入口销毁时调用：立即关闭浮层，停止录音和识别，不回调
     */
    fun dismissHold() {
        VoiceInputContext.runOnMain {
            panel?.release()
        }
    }

    // endregion
}
