/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import java.util.Arrays

/**
 * PCM 音频录制器，移植自 ../android-chat 的 audio/PcmAudioRecorder.java。
 * 采集 16kHz、16-bit、单声道 PCM（与 wf-voice 要求一致），每 30ms（960 字节）回调一次
 */
internal class PcmAudioRecorder(context: Context) : AudioManager.OnAudioFocusChangeListener {

    interface Callback {
        /** 在录音线程回调，pcmData 长度为 [CHUNK_SIZE]，会被复用 */
        fun onAudioData(pcmData: ByteArray)

        /** 可能在录音线程回调 */
        fun onError(message: String)
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val BYTES_PER_SECOND = SAMPLE_RATE * 2

        // 每次读取的字节数（对应 30ms 音频）
        const val CHUNK_SIZE = 960

        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private val context: Context = context.applicationContext
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null

    @Volatile
    private var isRecording = false

    @Volatile
    private var callback: Callback? = null

    /**
     * 开始录音，调用前需要已获得录音权限
     * @return 是否成功开始录音，失败时已经回调过 onError
     */
    @SuppressLint("MissingPermission")
    fun startRecording(callback: Callback): Boolean {
        this.callback = callback

        // 请求音频焦点
        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = manager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(this, Handler(Looper.getMainLooper()))
                .build()
            audioFocusRequest = request
            if (manager.requestAudioFocus(request) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                callback.onError("无法获取音频焦点")
                return false
            }
        } else {
            @Suppress("DEPRECATION")
            val result = manager.requestAudioFocus(this, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
            if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
                callback.onError("无法获取音频焦点")
                return false
            }
        }

        // 计算 AudioRecord 的最小缓冲区大小
        var bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (bufferSize == AudioRecord.ERROR || bufferSize == AudioRecord.ERROR_BAD_VALUE) {
            callback.onError("不支持此音频配置")
            releaseAudioFocus()
            return false
        }
        // 确保 bufferSize 至少是 CHUNK_SIZE 的两倍，避免缓冲区溢出
        if (bufferSize < CHUNK_SIZE * 2) {
            bufferSize = CHUNK_SIZE * 2
        }

        var record: AudioRecord? = null
        try {
            val created = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, bufferSize)
            record = created
            if (created.state != AudioRecord.STATE_INITIALIZED) {
                created.release()
                callback.onError("AudioRecord 初始化失败")
                releaseAudioFocus()
                return false
            }
            created.startRecording()
            audioRecord = created
            isRecording = true
            val thread = Thread({ readLoop(created) }, "$TAG-record")
            recordingThread = thread
            thread.start()
            VoiceInputContext.log("录音已开始: ${SAMPLE_RATE}Hz, 16-bit, 单声道")
            return true
        } catch (e: Exception) {
            VoiceInputContext.logError("启动录音失败", e)
            isRecording = false
            audioRecord = null
            try {
                record?.release()
            } catch (t: Exception) {
                // 已经释放
            }
            callback.onError("启动录音失败: ${e.message}")
            releaseAudioFocus()
            return false
        }
    }

    /**
     * 停止录音
     */
    fun stopRecording() {
        isRecording = false
        val record = audioRecord
        if (record != null) {
            try {
                record.stop()
            } catch (e: IllegalStateException) {
                VoiceInputContext.logError("停止录音失败", e)
            }
        }

        // 等待录音线程结束后再释放 AudioRecord，避免录音线程访问已释放的 AudioRecord
        val thread = recordingThread
        if (thread != null) {
            try {
                thread.join(500)
            } catch (e: InterruptedException) {
                VoiceInputContext.logError("等待录音线程结束被中断", e)
            }
            recordingThread = null
        }

        if (record != null) {
            record.release()
            audioRecord = null
        }
        releaseAudioFocus()
    }

    private fun releaseAudioFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest
            if (request != null) {
                manager.abandonAudioFocusRequest(request)
            }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(this)
        }
        audioManager = null
    }

    override fun onAudioFocusChange(focusChange: Int) {
        VoiceInputContext.log("音频焦点变化: $focusChange")
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS) {
            callback?.onError("失去音频焦点")
            stopRecording()
        }
    }

    /**
     * 录音线程，持续读取音频数据
     */
    private fun readLoop(record: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val buffer = ByteArray(CHUNK_SIZE)
        while (isRecording) {
            val readSize = record.read(buffer, 0, CHUNK_SIZE)
            if (readSize > 0) {
                if (readSize < CHUNK_SIZE) {
                    // 读取不足 CHUNK_SIZE，填充 0
                    Arrays.fill(buffer, readSize, CHUNK_SIZE, 0.toByte())
                }
                callback?.onAudioData(buffer)
            } else if (readSize == AudioRecord.ERROR_INVALID_OPERATION || readSize == AudioRecord.ERROR_BAD_VALUE || readSize == AudioRecord.ERROR_DEAD_OBJECT) {
                // 停止录音时 read 也会返回错误，那不算录音失败
                if (isRecording) {
                    VoiceInputContext.logError("AudioRecord 读取错误: $readSize")
                    callback?.onError("AudioRecord 读取错误")
                }
                break
            }
        }
    }
}
