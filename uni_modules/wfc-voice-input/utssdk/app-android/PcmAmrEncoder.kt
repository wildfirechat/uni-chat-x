/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.media.MediaCodec
import android.media.MediaFormat
import java.io.FileOutputStream
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong
import kotlin.math.sin

/**
 * 把 16kHz、16-bit、单声道 PCM 编码成 AMR-NB 文件（12.2kbps，和其他端录的语音消息格式一致）。
 *
 * ## 为什么用系统 MediaCodec，而不是 android-chat 的 io.kvh AmrEncoder
 *
 * io.kvh 的 aar 已经被 wfc-ptt-client 插件以本地 aar 带进来了，本插件再带一份会 duplicate class；
 * 只 compileOnly 又要赌对讲插件一定在。AMR-NB 编码器是 Android 兼容性定义（CDD 5.1）要求有麦克风的设备必须提供的，
 * MediaRecorder 录 AMR 用的就是它，不需要任何依赖。
 *
 * 编码器输出的每帧已经带 1 字节帧头（IETF storage format，12.2kbps 是 0x3C），接在 "#!AMR\n" 文件头后面就是 .amr 文件
 * （AOSP 的 AMRWriter 也是这么写的）。降采样前的低通滤波和 android-chat 的 PcmAmrEncoder.java 一样。
 *
 * 编码是同步的，要在后台线程调用。
 */
internal object PcmAmrEncoder {
    private val AMR_HEADER = "#!AMR\n".toByteArray(Charsets.US_ASCII)
    private const val SAMPLE_RATE = 8000
    private const val BIT_RATE = 12200

    // AMR-NB 每帧 20ms，8kHz 下是 160 个采样
    private const val FRAME_SAMPLES = 160
    private const val TIMEOUT_US = 10_000L

    // 输入全部送完之后，连续这么多轮拿不到输出就结束，避免个别编码器不回 EOS 时死循环
    private const val MAX_IDLE_ROUNDS = 300

    // 12.2kbps 的帧头：IETF storage format 是 0x3C；万一编码器吐的是 WMF 格式（帧类型 7），换算过来
    private const val MR122_WMF_HEADER = 0x07
    private const val MR122_IETF_HEADER = 0x3C

    // 16kHz 降采样到 8kHz 前的低通滤波器，滤掉 4kHz 以上的声音，避免混叠
    private val LOW_PASS_FILTER = createHalfBandFilter(31)

    /**
     * @param pcm     16kHz、16-bit、小端、单声道 PCM
     * @param length  pcm 的有效字节数
     * @param outPath 输出的 AMR 文件
     * @return 是否编码成功
     */
    fun encode(pcm: ByteArray, length: Int, outPath: String): Boolean {
        val samples = downsample(pcm, length)
        var codec: MediaCodec? = null
        try {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AMR_NB, SAMPLE_RATE, 1)
            format.setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AMR_NB)
            codec = encoder
            // 编码器必须带 CONFIGURE_FLAG_ENCODE：Codec2 的编码器组件不带这个标志 configure 直接报 UNKNOWN_ERROR
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            FileOutputStream(outPath).use { out ->
                out.write(AMR_HEADER)
                val info = MediaCodec.BufferInfo()
                var inputOffset = 0
                var inputDone = false
                var idleRounds = 0
                var frames = 0
                while (true) {
                    if (!inputDone) {
                        val inputIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
                        if (inputIndex >= 0) {
                            val buffer = encoder.getInputBuffer(inputIndex)
                            val ptsUs = inputOffset * 1_000_000L / SAMPLE_RATE
                            if (buffer == null || inputOffset >= samples.size) {
                                encoder.queueInputBuffer(inputIndex, 0, 0, ptsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                buffer.clear()
                                buffer.order(ByteOrder.nativeOrder())
                                // 一个输入缓冲区放一帧，兼容只按整帧处理输入的老编码器
                                val count = min(FRAME_SAMPLES, min(samples.size - inputOffset, buffer.remaining() / 2))
                                for (i in 0 until count) {
                                    buffer.putShort(samples[inputOffset + i])
                                }
                                encoder.queueInputBuffer(inputIndex, 0, count * 2, ptsUs, 0)
                                inputOffset += count
                            }
                        }
                    }
                    val outputIndex = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
                    if (outputIndex >= 0) {
                        idleRounds = 0
                        val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val output = encoder.getOutputBuffer(outputIndex)
                        if (!config && info.size > 0 && output != null) {
                            val bytes = ByteArray(info.size)
                            output.position(info.offset)
                            output.limit(info.offset + info.size)
                            output.get(bytes)
                            if (bytes[0].toInt() == MR122_WMF_HEADER) {
                                bytes[0] = MR122_IETF_HEADER.toByte()
                            }
                            if (frames == 0) {
                                VoiceInputContext.log("AMR 编码器 ${encoder.name}，首帧 ${info.size} 字节，帧头 0x${Integer.toHexString(bytes[0].toInt() and 0xff)}")
                            }
                            frames++
                            out.write(bytes)
                        }
                        encoder.releaseOutputBuffer(outputIndex, false)
                        if (eos) {
                            break
                        }
                    } else if (inputDone && outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                        idleRounds++
                        if (idleRounds > MAX_IDLE_ROUNDS) {
                            VoiceInputContext.log("AMR 编码器没有回 EOS，按已编码的 $frames 帧结束")
                            break
                        }
                    }
                }
                if (frames == 0) {
                    throw IllegalStateException("AMR 编码器没有输出")
                }
            }
            return true
        } catch (e: Throwable) {
            VoiceInputContext.logError("编码 AMR 失败", e)
            return false
        } finally {
            try {
                codec?.stop()
            } catch (e: Exception) {
                // 没有 start 成功
            }
            try {
                codec?.release()
            } catch (e: Exception) {
                // 已经释放
            }
        }
    }

    /**
     * 滤波后每两个采样取一个，降到 8kHz；最后不足一帧的部分补静音
     */
    private fun downsample(pcm: ByteArray, length: Int): ShortArray {
        val inSamples = min(length, pcm.size) / 2
        val outSamples = (inSamples + 1) / 2
        val frames = max(1, (outSamples + FRAME_SAMPLES - 1) / FRAME_SAMPLES)
        val result = ShortArray(frames * FRAME_SAMPLES)
        val halfTaps = LOW_PASS_FILTER.size / 2
        var o = 0
        var i = 0
        while (i < inSamples) {
            var sum = 0.0
            for (k in LOW_PASS_FILTER.indices) {
                val index = min(max(i + k - halfTaps, 0), inSamples - 1)
                val sample = ((pcm[2 * index].toInt() and 0xff) or (pcm[2 * index + 1].toInt() shl 8)).toShort()
                sum += LOW_PASS_FILTER[k] * sample
            }
            result[o++] = clamp(sum)
            i += 2
        }
        return result
    }

    private fun clamp(value: Double): Short {
        return max(Short.MIN_VALUE.toLong(), min(Short.MAX_VALUE.toLong(), value.roundToLong())).toShort()
    }

    /**
     * 截止频率为采样率 1/4 的加窗（Hamming）半带低通滤波器
     */
    private fun createHalfBandFilter(taps: Int): DoubleArray {
        val filter = DoubleArray(taps)
        val center = taps / 2
        var sum = 0.0
        for (i in 0 until taps) {
            val n = i - center
            val sinc = if (n == 0) 0.5 else sin(PI * n / 2) / (PI * n)
            val window = 0.54 - 0.46 * cos(2 * PI * i / (taps - 1))
            filter[i] = sinc * window
            sum += filter[i]
        }
        for (i in 0 until taps) {
            filter[i] /= sum
        }
        return filter
    }
}
