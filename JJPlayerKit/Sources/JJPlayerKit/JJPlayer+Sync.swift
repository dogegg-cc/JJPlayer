//
//  JJPlayer+Sync.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation
import QuartzCore

extension JJPlayer {
    /// 开启屏幕刷新同步回路 (displayLink)
    func startDisplayLink() {
        // 必须运行在主线程
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startDisplayLink()
            }
            return
        }

        stopDisplayLink() // 防护：启动前先安全停止旧的

        // 绑定 updateSyncLoop 方法，随着系统的刷新帧脉冲连续触发
        let link = CADisplayLink(target: self, selector: #selector(updateSyncLoop))
        link.add(to: .main, forMode: .common)
        displayLink = link
        DebugLog("🔗 [JJPlayer] CADisplayLink 同步回路已挂载到主线程运行循环。")
    }

    /// 停止屏幕刷新同步回路
    func stopDisplayLink() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [weak self] in
                self?.stopDisplayLink()
            }
            return
        }

        displayLink?.invalidate()
        displayLink = nil
    }

    /// 精准获取全局 Audio Primary Clock
    func getAudioPrimaryClock() -> Double {
        audioPtsLock.lock()
        let basePTS = firstAudioPTS
        audioPtsLock.unlock()

        // 音频首帧还没唱出来时，基准为 0
        if basePTS < 0 {
            return 0.0
        }

        if let player = audioPlayer {
            // 当前音频发声绝对 PTS = 音频首帧基准 PTS + 声卡已连续播放物理采样时间
            return basePTS + player.currentPlaybackTime
        }

        return basePTS
    }

    /// 高频音视频同步主决策循环 (在主线程随屏幕刷新帧同步调用)
    @objc func updateSyncLoop() {
        guard state == .playing else { return }

        // 💥 自适应缓冲下溢挂起与充盈恢复判定
        if !isDecodingEOF {
            let audioSize = getAudioBufferSize()
            videoQueueLock.lock()
            let videoCount = videoFrameQueue.count
            videoQueueLock.unlock()

            if !isLoading {
                // 1. 下溢挂起评估：当视频帧消耗完，且音频缓冲区 PCM 数据接近耗尽（小于 32KB），
                //    代表即将卡顿，应立即启动缓冲挂起 Loading，并暂停声卡以防止杂音和空耗。
                if videoCount == 0, audioSize < 32 * 1024 {
                    updateLoadingStatus(true)
                    audioPlayer?.pause()
                    DebugLog("⚠️ [JJPlayer] 检测到缓冲区下溢 (Audio: \(audioSize)B, Video: 0)，挂起播放以进行网络数据缓冲...")
                }
            } else {
                // 2. 充盈恢复评估：若在挂起中，当缓冲积攒够 8 帧视频且音频达到 128KB (可流畅播放 0.5s 以上时)，
                //    恢复播放，重新物理启动声卡。
                if videoCount >= 8, audioSize >= 128 * 1024 {
                    updateLoadingStatus(false)
                    audioPlayer?.play()
                    DebugLog("✅ [JJPlayer] 缓冲区已充盈 (Audio: \(audioSize)B, Video: \(videoCount))，继续流畅播放...")
                }
            }
        }

        // 💥 若处于 Loading 挂起状态下，为了防止时钟乱跑或强行消费，仅在主线程更新缓冲条进度并直接返回！
        if isLoading {
            updateBufferMetrics()
            return
        }

        // 1. 获取最精确 of 音频发声时钟 (Audio Primary Clock)
        let audioClock = getAudioPrimaryClock()

        // 💥 随屏幕刷新在主线程安全更新响应式参数，彻底抛弃外部脏轮询 Timer！
        updateCurrentTime(audioClock)
        updateBufferMetrics()

        videoQueueLock.lock()
        defer { videoQueueLock.unlock() }

        // 2. 双向快速追赶决策
        while !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue[0]
            let diff = nextFrame.pts - audioClock

            if diff < -0.04 {
                // A. 视频帧落后于音频超过 40ms：表示该画面已经过时，果断执行【快速丢帧】！
                videoFrameQueue.removeFirst()
                continue
            } else if diff > 0.04 {
                // B. 视频帧超前于音频超过 40ms：说明画面超前声音，音频还没播放到这一秒
                break
            } else {
                // C. 完美落入声画极精对齐区间 [-40ms, 40ms]
                updateCurrentFrame(nextFrame.cgImage)
                videoFrameQueue.removeFirst()
                break
            }
        }

        // 3. 消费完毕状态机平滑闭环检测
        if isDecodingEOF, videoFrameQueue.isEmpty, getAudioBufferSize() == 0 {
            DebugLog("🎉 缓冲区数据完全消费完毕，音视频同步流畅步入 .completed 状态。")
            changeState(to: .completed)
            audioPlayer?.pause()
            stopDisplayLink()
            updateDecodingEOF(false)
        }
    }
}
