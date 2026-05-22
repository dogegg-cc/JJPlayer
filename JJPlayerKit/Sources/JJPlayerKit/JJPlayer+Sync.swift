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
