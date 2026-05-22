//
//  JJPlayer+Seek.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation

extension JJPlayer {
    /// 物理 Seek 跳转到指定时间点（秒），支持高精单帧物理预览与时钟重对齐
    public func seek(to seconds: Double) {
        // 1. 状态防护：必须就绪或播放中，且已实例化解复用器
        guard activeDemuxer != nil,
              state == .ready || state == .playing || state == .paused || state == .completed else { return }

        let originalState = state
        let originalVolume = volume
        let originalMute = isMuted
        let originalRate = playbackRate

        // 2. 时序截断：置 isPlayingLoop 为 false 并注销 displayLink 停止主线程心跳
        isPlayingLoop = false
        updateDecodingEOF(false)
        stopDisplayLink()

        // 3. 双锁保护清空音视频缓冲区与发声时钟
        resetBuffersAndClock()

        // 4. 后台派发物理跳转与单帧精确物理预览，防止 UI 线程阻塞
        mediaLoaderQueue.async { [weak self] in
            guard let self else { return }
            let success = activeDemuxer?.seek(to: seconds) ?? false
            if success {
                performSingleFramePreview()
            }

            // 5. 主线程重组音频声卡，物理清空已播放 sample 点数，重对齐时钟
            DispatchQueue.main.async {
                self.rebuildAudioEngine(volume: originalVolume, isMuted: originalMute, rate: originalRate)

                // 💥 实时强制拉齐响应式进度，消除拖拽后UI进度的延迟同步
                self.updateCurrentTime(seconds)
                self.updateBufferMetrics()

                // 6. 状态恢复：如果 Seek 前是播放状态，调用 play() 重新拉起，否则进入暂停
                if originalState == .playing {
                    self.changeState(to: .paused)
                    self.play()
                } else {
                    self.changeState(to: .paused)
                }
            }
        }
    }

    // 💥【SRP 辅助函数：缓冲区与时钟归零】
    private func resetBuffersAndClock() {
        videoQueueLock.lock()
        videoFrameQueue.removeAll(keepingCapacity: false)
        videoQueueLock.unlock()

        audioLock.lock()
        audioBuffer.removeAll(keepingCapacity: false)
        audioLock.unlock()

        audioPtsLock.lock()
        firstAudioPTS = -1.0
        audioPtsLock.unlock()
    }

    // 💥【SRP 辅助函数：单帧精确物理预览】
    private func performSingleFramePreview() {
        guard let demuxer = activeDemuxer else { return }
        var frameFound = false
        // 最多尝试解码 20 次，拉取出 Seek 后的最近一帧画面
        for _ in 0 ..< 20 {
            let status = demuxer.decodeAndDispatch()
            if status == -1 { break } // EOF

            videoQueueLock.lock()
            let hasFrame = !videoFrameQueue.isEmpty
            videoQueueLock.unlock()

            if hasFrame {
                frameFound = true
                break
            }
        }

        if frameFound {
            videoQueueLock.lock()
            let previewImage = videoFrameQueue.first?.cgImage
            videoFrameQueue.removeAll()
            videoQueueLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.updateCurrentFrame(previewImage)
            }
        }
    }

    // 💥【SRP 辅助函数：声卡物理引擎重组】
    private func rebuildAudioEngine(volume: Float, isMuted: Bool, rate: Float) {
        audioPlayer?.stop()
        audioPlayer = nil

        let newPlayer = JJAudioQueuePlayer()
        newPlayer.pcmDataRequester = { [weak self] capacity in
            guard let self else { return Data() }
            return consumeAudioData(length: capacity)
        }

        // 继承 Seek 之前的物理音量、静音与倍速配置
        newPlayer.volume = volume
        newPlayer.isMuted = isMuted
        newPlayer.playbackRate = rate

        audioPlayer = newPlayer
        DebugLog("🔄 [JJPlayer] 音频声卡物理引擎重建成功，Seek 硬件时间戳已清零重对齐！")
    }
}
