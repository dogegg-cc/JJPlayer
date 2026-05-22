//
//  JJPlayer+Buffer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation

extension JJPlayer {
    // 💥【SRP 拆分：向线程安全队列追加音频 PCM 数据】
    func appendAudioData(_ data: Data) {
        audioLock.lock()
        audioBuffer.append(data)
        audioLock.unlock()
    }

    // 💥【SRP 拆分：声卡消费数据，提供极速 0ms 提货】
    func consumeAudioData(length: Int) -> Data {
        audioLock.lock()
        defer { audioLock.unlock() }

        if audioBuffer.isEmpty {
            return Data()
        }

        let consumeSize = min(length, audioBuffer.count)
        let subData = audioBuffer.prefix(consumeSize)
        audioBuffer.removeFirst(consumeSize)

        return Data(subData)
    }

    // 💥【SRP 拆分：获取当前音频缓冲大小（水位）】
    func getAudioBufferSize() -> Int {
        audioLock.lock()
        let count = audioBuffer.count
        audioLock.unlock()
        return count
    }

    // 💥【SRP 拆分：获取当前视频队列中未渲染的帧数】
    func getVideoFrameQueueCount() -> Int {
        videoQueueLock.lock()
        let count = videoFrameQueue.count
        videoQueueLock.unlock()
        return count
    }
}
