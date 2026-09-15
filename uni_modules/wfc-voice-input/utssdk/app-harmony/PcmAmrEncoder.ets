/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

// 移植自 ../hm-chat uikit/src/main/ets/pages/conversation/audio/PcmAmrEncoder.ets。
// hm-chat 直接 import 'libpttamr.so'，要在工程里另外声明 .so 的类型包；uts 插件的 oh-package 只能写 dependencies，
// 类型包是源码目录、解析不到。这里改用 ptt.har 自己封装好的 AmrEncoder：.so 的解析发生在 har 内部，
// 插件只需要依赖 har。编码参数和 hm-chat 一致：12.2kbps（AmrEncoder 内部固定 MR122）。
// ptt.har 和 wfc-ptt-client 共用，声明在工程根 harmony-configs/oh-package.json5 里（har 在 harmony-configs/libs/）。

import fs from '@ohos.file.fs'
import { AmrEncoder } from '@wfc/ptt/src/main/ets/ptt/internal/amrCodec'

const TAG = 'PcmAmrEncoder'

const AMR_HEADER: number[] = [0x23, 0x21, 0x41, 0x4D, 0x52, 0x0A] // "#!AMR\n"
// AMR-NB 每帧 20ms，8kHz 下是 160 个采样
const FRAME_SAMPLES = 160
// 每次编码的帧数，编码在主线程分片进行，每片 0.5 秒音频，避免卡住界面
const FRAMES_PER_SLICE = 25
const FILTER_TAPS = 31

/**
 * 截止频率为采样率 1/4 的加窗（Hamming）半带低通滤波器，16kHz 降采样到 8kHz 前滤掉 4kHz 以上的声音，避免混叠
 */
function createHalfBandFilter(taps: number): number[] {
    let filter: number[] = []
    let center = Math.floor(taps / 2)
    let sum = 0
    for (let i = 0; i < taps; i++) {
        let n = i - center
        let sinc = n === 0 ? 0.5 : Math.sin(Math.PI * n / 2) / (Math.PI * n)
        let window = 0.54 - 0.46 * Math.cos(2 * Math.PI * i / (taps - 1))
        filter.push(sinc * window)
        sum += sinc * window
    }
    return filter.map((value: number) => value / sum)
}

const LOW_PASS_FILTER = createHalfBandFilter(FILTER_TAPS)

/**
 * 把 16kHz、16-bit、单声道 PCM 编码成 AMR-NB 文件，和 android / hm-chat 录制的语音消息格式一致
 *
 * @param pcm     16kHz、16-bit、小端、单声道 PCM
 * @param outPath 输出的 AMR 文件
 * @param gain    音量放大倍数，1 表示不放大
 * @returns 是否编码成功
 */
export function encodePcmToAmr(pcm: ArrayBuffer, outPath: string, gain: number = 1): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
        const encoder: AmrEncoder = new AmrEncoder()
        if (!encoder.isValid()) {
            encoder.release()
            resolve(false)
            return
        }
        let file: fs.File | undefined = undefined
        try {
            file = fs.openSync(outPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
            fs.writeSync(file.fd, new Uint8Array(AMR_HEADER).buffer as ArrayBuffer)
        } catch (e) {
            console.error(TAG, 'open file failed', e)
            encoder.release()
            resolve(false)
            return
        }
        const outFile: fs.File = file

        let input = new Int16Array(pcm, 0, Math.floor(pcm.byteLength / 2))
        let inSamples = input.length
        let halfTaps = Math.floor(FILTER_TAPS / 2)
        // 降采样后的输出位置，每两个输入采样取一个
        let inputIndex = 0

        let finish = (success: boolean) => {
            try {
                encoder.release()
                fs.closeSync(outFile)
            } catch (e) {
                console.error(TAG, 'release failed', e)
            }
            resolve(success)
        }

        let encodeSlice = () => {
            try {
                let frames = new Int16Array(FRAME_SAMPLES * FRAMES_PER_SLICE)
                let count = 0
                // 滤波后每两个采样取一个，降到 8kHz
                while (count < frames.length && inputIndex < inSamples) {
                    let sum = 0
                    for (let k = 0; k < FILTER_TAPS; k++) {
                        let coefficient = LOW_PASS_FILTER[k]
                        if (coefficient !== 0) {
                            let index = Math.min(Math.max(inputIndex + k - halfTaps, 0), inSamples - 1)
                            sum += coefficient * input[index]
                        }
                    }
                    frames[count++] = Math.max(-32768, Math.min(32767, Math.round(sum * gain)))
                    inputIndex += 2
                }
                let done = inputIndex >= inSamples
                // 最后不足一帧的部分补静音（Int16Array 默认是 0）
                let frameCount = done ? Math.ceil(count / FRAME_SAMPLES) : Math.floor(count / FRAME_SAMPLES)
                if (frameCount > 0) {
                    let amr = encoder.encode(frames.buffer.slice(0, frameCount * FRAME_SAMPLES * 2))
                    if (amr.byteLength > 0) {
                        fs.writeSync(outFile.fd, amr)
                    }
                }
                if (done) {
                    finish(true)
                } else {
                    setTimeout(encodeSlice, 0)
                }
            } catch (e) {
                console.error(TAG, 'encode failed', e)
                finish(false)
            }
        }
        encodeSlice()
    })
}
