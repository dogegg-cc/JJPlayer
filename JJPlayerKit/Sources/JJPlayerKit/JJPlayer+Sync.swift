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

        // 1. 自适应缓冲下溢挂起与充盈恢复判定
        evaluateBufferingState()

        // 若处于 Loading 挂起状态下，为了防止时钟乱跑，仅在主线程更新缓冲条进度并直接返回！
        if isLoading {
            updateBufferMetrics()
            return
        }

        // 2. 获取并更新精确的音频发声时钟
        var audioClock = getAudioPrimaryClock()
        updateCurrentTime(audioClock)
        updateBufferMetrics()

        // 3. 执行画面同步与丢帧渲染
        renderAndSyncFrames(audioClock: &audioClock)

        // 4. 消费完毕状态机平滑闭环检测 (直播流不触发正常播放完毕状态机流转)
        if !isLive, isDecodingEOF, videoFrameQueue.isEmpty, getAudioBufferSize() == 0 {
            DebugLog("🎉 缓冲区数据完全消费完毕，音视频同步流畅步入 .completed 状态。")
            changeState(to: .completed)
            audioPlayer?.pause()
            stopDisplayLink()
            updateDecodingEOF(false)
        }
    }

    /// 💥 自适应缓冲下溢挂起与充盈恢复判定 (SRP)
    private func evaluateBufferingState() {
        guard !isDecodingEOF else { return }

        let audioSize = getAudioBufferSize()
        videoQueueLock.lock()
        let videoCount = videoFrameQueue.count
        videoQueueLock.unlock()

        if !isLoading {
            // 1. 下溢挂起评估：音频或视频接近耗尽时挂起，暂停声卡
            if videoCount == 0, audioSize < 32 * 1024 {
                updateLoadingStatus(true)
                audioPlayer?.pause()
                DebugLog("⚠️ [JJPlayer] 检测到缓冲区下溢 (Audio: \(audioSize)B, Video: 0)，挂起播放...")
            }
        } else {
            // 2. 充盈恢复评估：缓冲积攒足够时唤醒，重新物理启动声卡
            if videoCount >= 8, audioSize >= 128 * 1024 {
                updateLoadingStatus(false)
                audioPlayer?.play()
                DebugLog("✅ [JJPlayer] 缓冲区已充盈 (Audio: \(audioSize)B, Video: \(videoCount))，继续播放...")
            }
        }
    }

    /// 💥 画面音视频同步与丢帧渲染 (SRP)
    private func renderAndSyncFrames(audioClock: inout Double) {
        videoQueueLock.lock()
        defer { videoQueueLock.unlock() }

        // A. 直播时钟突变 Discontinuity 自修复
        if isLive, !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue[0]
            let diff = nextFrame.pts - audioClock
            if abs(diff) > 2.0 {
                audioPtsLock.lock()
                let playTime = audioPlayer?.currentPlaybackTime ?? 0.0
                firstAudioPTS = nextFrame.pts - playTime
                audioPtsLock.unlock()

                audioClock = nextFrame.pts
                updateCurrentTime(audioClock)
                DebugLog("⚠️ [JJPlayer] 直播流时钟突变 (Diff: \(diff)s)，已物理重算 firstAudioPTS 进行声画对齐。")
            }
        }

        // B. 双向快速追赶决策
        while !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue[0]
            let diff = nextFrame.pts - audioClock

            if diff < -0.04 {
                // A. 视频帧落后于音频超过 40ms：该画面已过时，丢帧
                videoFrameQueue.removeFirst()
                continue
            } else if diff > 0.04 {
                // B. 视频帧超前于音频超过 40ms：画面超前声音，挂起等待
                break
            } else {
                // C. 完美落入声画极精对齐区间 [-40ms, 40ms]
                updateCurrentFrame(nextFrame.cgImage)
                videoFrameQueue.removeFirst()
                break
            }
        }

        // 3. 消费完毕状态机平滑闭环检测 (直播流不触发正常播放完毕状态机流转)
        if !isLive, isDecodingEOF, videoFrameQueue.isEmpty, getAudioBufferSize() == 0 {
            DebugLog("🎉 缓冲区数据完全消费完毕，音视频同步流畅步入 .completed 状态。")
            changeState(to: .completed)
            audioPlayer?.pause()
            stopDisplayLink()
            updateDecodingEOF(false)
        }
    }
}
