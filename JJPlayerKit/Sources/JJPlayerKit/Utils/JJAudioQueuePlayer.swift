//
//  JJAudioQueuePlayer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import AudioToolbox
import Foundation

/// 基于 iOS 底层 AudioQueueRef 的高性能低延迟 PCM 音频播放引擎
public final class JJAudioQueuePlayer {
    // 物理声卡播放管道引用指针
    var audioQueue: AudioQueueRef?

    // 3 个循环交替使用的音频缓冲区
    var buffers: [AudioQueueBufferRef?] = [nil, nil, nil]

    // 每个缓冲区的物理容量大小（字节），设为 16KB
    let bufferSize: UInt32 = 16384

    // 是否正在物理发声
    var isRunning: Bool = false

    // 💥【参数状态物理存储】
    var currentVolumeSetting: Float = 1.0
    var currentMuteSetting: Bool = false
    var currentRateSetting: Float = 1.0

    /// 数据供给闭包
    public var pcmDataRequester: ((Int) -> Data)?

    /// 初始化并物理激活 iOS 音频播放通道
    public init() {
        setupAudioQueue()
    }

    deinit {
        destroyAudioQueue()
    }

    /// 开启物理播放发声
    public func play() {
        guard let queue = audioQueue, !isRunning else { return }
        let status = AudioQueueStart(queue, nil)
        if status == noErr {
            isRunning = true
            DebugLog("🔊 [JJAudioQueuePlayer] AudioQueue 成功启动发声。")
            // 💥 强制应用启动前的倍速与音量配置，防止被 CoreAudio 启动心跳覆盖或静默丢弃
            AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, AudioQueueParameterValue(currentRateSetting))
            let targetVol = currentMuteSetting ? 0.0 : currentVolumeSetting
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, AudioQueueParameterValue(targetVol))
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueStart 启动失败，状态码: \(status)")
        }
    }

    /// 暂停播放
    public func pause() {
        guard let queue = audioQueue, isRunning else { return }
        let status = AudioQueuePause(queue)
        if status == noErr {
            isRunning = false
            DebugLog("⏸ [JJAudioQueuePlayer] AudioQueue 暂停成功。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueuePause 暂停失败，状态码: \(status)")
        }
    }

    /// 停止物理播放并清空声卡管道
    public func stop() {
        guard let queue = audioQueue else { return }
        let status = AudioQueueStop(queue, true)
        if status == noErr {
            isRunning = false
            DebugLog("⏹ [JJAudioQueuePlayer] AudioQueue 物理截断停止。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueStop 停止失败，状态码: \(status)")
        }
    }

    /// 重置音频引擎预热状态
    public func reset() {
        stop()
        for buffer in buffers {
            if let buf = buffer {
                memset(buf.pointee.mAudioData, 0, Int(bufferSize))
                buf.pointee.mAudioDataByteSize = bufferSize
                if let queue = audioQueue {
                    AudioQueueEnqueueBuffer(queue, buf, 0, nil)
                }
            }
        }
    }

    /// 获取当前声卡正在物理发声的播放时间（秒）
    public var currentPlaybackTime: Double {
        guard let queue = audioQueue else { return 0.0 }
        var time = AudioTimeStamp()
        let status = AudioQueueGetCurrentTime(queue, nil, &time, nil)
        if status == noErr, time.mFlags.contains(.sampleTimeValid) {
            return Double(time.mSampleTime) / 44100.0
        }
        return 0.0
    }
}
