//
//  JJAudioQueuePlayer+Init.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import AudioToolbox
import Foundation

extension JJAudioQueuePlayer {
    // 💥【SRP 拆分：AudioQueue 物理初始化入口】
    func setupAudioQueue() {
        var format = prepareAudioFormat()

        guard createAudioQueueInstance(format: &format) else { return }
        guard let queue = audioQueue else { return }

        configureTimePitch(queue: queue)
        allocateAudioBuffers(queue: queue)

        DebugLog("🎵 [JJAudioQueuePlayer] AudioQueue 物理引擎配置成功，3个滚动 Buffer 分配就绪！")
    }

    // 1. 组装物理流 ASBD 格式描述
    private func prepareAudioFormat() -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = 44100.0
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 16
        format.mChannelsPerFrame = 2
        format.mFramesPerPacket = 1
        format.mBytesPerFrame = 4
        format.mBytesPerPacket = 4
        return format
    }

    // 2. 实例化底层的 AudioQueueRef
    private func createAudioQueueInstance(format: inout AudioStreamBasicDescription) -> Bool {
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = AudioQueueNewOutput(
            &format,
            audioQueueOutputCallback,
            selfPointer,
            nil,
            nil,
            0,
            &audioQueue
        )
        if status != noErr {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueNewOutput 创建声卡失败，错误码: \(status)")
            return false
        }
        return true
    }

    // 3. 配置高品质 TimePitch 变速不变调引擎
    private func configureTimePitch(queue: AudioQueueRef) {
        // 💥【激活关键：显式启用 TimePitch 处理器】
        var enableTimePitch: UInt32 = 1
        AudioQueueSetProperty(queue, kAudioQueueProperty_EnableTimePitch, &enableTimePitch, UInt32(MemoryLayout<UInt32>.size))

        var bypassTimePitch: UInt32 = 0
        AudioQueueSetProperty(queue, kAudioQueueProperty_TimePitchBypass, &bypassTimePitch, UInt32(MemoryLayout<UInt32>.size))

        var algorithm = kAudioQueueTimePitchAlgorithm_Spectral
        AudioQueueSetProperty(queue, kAudioQueueProperty_TimePitchAlgorithm, &algorithm, UInt32(MemoryLayout<UInt32>.size))
    }

    // 4. 预分配 3 个音频缓冲传送带并静音预热
    private func allocateAudioBuffers(queue: AudioQueueRef) {
        for i in 0 ..< 3 {
            var buf: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, bufferSize, &buf)
            if allocStatus == noErr, let b = buf {
                buffers[i] = b
                memset(b.pointee.mAudioData, 0, Int(bufferSize))
                b.pointee.mAudioDataByteSize = bufferSize
                AudioQueueEnqueueBuffer(queue, b, 0, nil)
            } else {
                DebugLog("❌ [JJAudioQueuePlayer] AudioQueue 缓冲 \(i) 分配失败，状态: \(allocStatus)")
            }
        }
    }

    // 💥【SRP 拆分：物理销毁释放资源】
    func destroyAudioQueue() {
        guard let queue = audioQueue else { return }
        stop()

        let status = AudioQueueDispose(queue, true)
        if status == noErr {
            audioQueue = nil
            buffers = [nil, nil, nil]
            DebugLog("🗑️ [JJAudioQueuePlayer] AudioQueue 成功物理归零销毁。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueDispose 销毁失败，状态码: \(status)")
        }
    }
}
