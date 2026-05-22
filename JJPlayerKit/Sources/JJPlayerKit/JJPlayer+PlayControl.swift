//
//  JJPlayer+PlayControl.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation
import JJFFmpegCore

extension JJPlayer {
    /// 开始播放
    public func play() {
        guard state == .ready || state == .paused else { return }
        changeState(to: .playing)
        updateDecodingEOF(false)
        isPlayingLoop = true
        DebugLog("▶️ 开始播放，启动专属一站式双流后台解码循环...")

        // 1. 物理激活底层 AudioQueue 引擎，驱动声卡开始连续消费发声
        audioPlayer?.play()

        // 2. 启动屏幕刷新同步回路 (displayLink)
        startDisplayLink()

        // 3. 开启高优先级后台解码工作流，单一物理读取流，避免阻塞 UI 线程
        startDecodeLoop()
    }

    /// 暂停播放
    public func pause() {
        guard state == .playing else { return }

        // 暂停声卡播放发声，保持缓冲区排队数据不丢失
        audioPlayer?.pause()

        // 暂停屏幕刷新同步回路
        stopDisplayLink()

        changeState(to: .paused)
        DebugLog("⏸ 音视频暂停播放。")
    }

    /// 停止播放并重置所有媒体状态
    public func stop() {
        isPlayingLoop = false // 关闭循环标识，后台解码线程自适应退出
        updateDecodingEOF(false)

        // 物理截断声卡发声，销毁 AudioQueue 管道与内存
        audioPlayer?.stop()
        setupAudioEngine(player: nil)

        // 注销屏幕刷新同步回路
        stopDisplayLink()

        // 线程安全清空 PCM 数据缓冲，防止下一次播放时残留杂音
        clearAudioBuffer()

        // 物理清空视频帧缓冲队列
        clearVideoFrameQueue()

        // 重置音频首帧发声 PTS 时间戳追踪基准
        resetFirstAudioPTS()

        changeState(to: .idle)
        resetPlayProgress()

        activeDemuxer?.close() // 手动强制闭合解复用器，销毁所有 C 指针内存
        setDemuxer(nil)
        DebugLog("⏹ 停止播放并物理重置状态机、音频引擎与同步时钟。")
    }

    /// 💥【SRP 拆分：启动后台解码线程】
    private func startDecodeLoop() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            runDecodeLoop()
        }
    }

    /// 💥【SRP 拆分：解码轮询决策循环】
    private func runDecodeLoop() {
        while true {
            // 💥 修改为：只要解复用器存在，且处于就绪/播放/暂停状态，均允许解码预缓冲
            guard let demuxer = activeDemuxer,
                  state == .playing || state == .paused || state == .ready else { break }

            // 一站式从底层多媒体流中提取、解码并分发单个数据包
            let status = demuxer.decodeAndDispatch()

            if status == 0 {
                applyFlowControl()
            } else if status == -1 {
                // 读完视频包，标志 EOF，通知主线程
                DispatchQueue.main.async { [weak self] in
                    self?.updateDecodingEOF(true)
                }
                break
            }
        }
    }

    /// 💥【SRP 拆分：双流自适应流量控制】
    private func applyFlowControl() {
        let currentWatermark = getAudioBufferSize()
        let currentVideoFrames = getVideoFrameQueueCount()

        // 💥 【阶段四硬核升级：音视频双重流量控制 (Dual Flow Control)】
        // 同时关联音频缓冲水位（256KB，约1.5秒容量）与视频帧队列长度（24帧，约0.8秒缓冲）。
        // 当任何一个达到上限时，挂起解码线程 33ms，实现最平稳的供求自适应与极低内存损耗！
        if currentWatermark > 256 * 1024 || currentVideoFrames > 24 {
            Thread.sleep(forTimeInterval: 0.033) // 缓冲区饱满，解码线程歇息一帧时间
        } else {
            // 预缓冲加速充盈中，微调度让出 CPU 时间片，防止死锁
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// 💥【SRP 拆分：状态与缓冲重置辅助】
    private func clearAudioBuffer() {
        audioLock.lock()
        audioBuffer.removeAll(keepingCapacity: false)
        audioLock.unlock()
    }

    private func clearVideoFrameQueue() {
        videoQueueLock.lock()
        videoFrameQueue.removeAll(keepingCapacity: false)
        videoQueueLock.unlock()
    }

    private func resetFirstAudioPTS() {
        audioPtsLock.lock()
        firstAudioPTS = -1.0
        audioPtsLock.unlock()
    }
}
