//
//  JJAudioQueuePlayer+Callback.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import AudioToolbox
import Foundation

extension JJAudioQueuePlayer {
    /// 底层声卡回调投喂核心实现
    func handleBufferCallback(_ aq: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        var pcmData = Data()

        // 💥 只有当正处于物理发声状态时才提取实际音频数据
        if isRunning, let requester = pcmDataRequester {
            pcmData = requester(capacity)
        }

        if !pcmData.isEmpty {
            pcmData.withUnsafeBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    memcpy(buffer.pointee.mAudioData, baseAddress, pcmData.count)
                }
            }
            buffer.pointee.mAudioDataByteSize = UInt32(pcmData.count)
        } else {
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        }

        AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
    }
}

// 💥【C 语言格式高精度声卡回调函数指针包装】
let audioQueueOutputCallback: AudioQueueOutputCallback = { inUserData, inAQ, inBuffer in
    guard let inUserData else { return }
    let player = Unmanaged<JJAudioQueuePlayer>.fromOpaque(inUserData).takeUnretainedValue()
    player.handleBufferCallback(inAQ, inBuffer)
}
