//
//  JJAudioQueuePlayer+Params.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import AudioToolbox
import Foundation

public extension JJAudioQueuePlayer {
    /// 物理播放音量（范围 0.0 ~ 1.0）
    var volume: Float {
        get {
            currentVolumeSetting
        }
        set {
            let boundedValue = max(0.0, min(newValue, 1.0))
            currentVolumeSetting = boundedValue

            // 如果处于静音状态，仅更新参数设置，不破坏声卡的零声量状态
            guard !currentMuteSetting, let queue = audioQueue else { return }
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, AudioQueueParameterValue(boundedValue))
        }
    }

    /// 一键静音开关
    var isMuted: Bool {
        get {
            currentMuteSetting
        }
        set {
            currentMuteSetting = newValue
            guard let queue = audioQueue else { return }

            // 静音时向声卡物理写入 0 音量，取消静音时恢复用户设定的真实音量
            let targetVol = newValue ? 0.0 : currentVolumeSetting
            AudioQueueSetParameter(queue, kAudioQueueParam_Volume, AudioQueueParameterValue(targetVol))
        }
    }

    /// 播放速率（支持变速不变调，物理范围 0.5 ~ 3.0）
    var playbackRate: Float {
        get {
            currentRateSetting
        }
        set {
            let boundedRate = max(0.5, min(newValue, 3.0))
            currentRateSetting = boundedRate

            guard let queue = audioQueue else { return }

            // 💥【物理声卡倍速消费】
            // 物理修改声卡发声的主时钟播放倍速，配合 setupAudioQueue 中已激活的
            // TimePitch 变速不变调引擎，声卡会以最高音质重组发声，音调完全正常！
            AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, AudioQueueParameterValue(boundedRate))
        }
    }
}
