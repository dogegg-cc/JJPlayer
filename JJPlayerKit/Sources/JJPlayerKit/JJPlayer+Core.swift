//
//  JJPlayer+Core.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import CoreVideo
import Foundation
import JJFFmpegCore
import VideoToolbox

extension JJPlayer {
    /// 异步载入媒体文件，利用手写的 C API 解复用核心 (JJDemuxer) 提取流级别元数据
    ///
    /// - Parameter path: 本地视频文件的绝对路径或网络流 URL
    public func loadMedia(path: String) {
        changeState(to: .preparing)
        DebugLog("🔄 正在载入媒体文件: \(path)")

        // 所有的 loadMedia、stop 逻辑全部放入串行队列按顺序行进，物理上隔离多线程并发冲突
        mediaLoaderQueue.async { [weak self] in
            guard let self else { return }
            do {
                // 1. 初始化 C 解复用核心 (JJDemuxer) 并打开媒体文件
                let demuxer = try prepareDemuxer(path: path)

                // 2. 配置视频与音频的双路闭包回调
                setupCallbacks(for: demuxer)

                // 3. 读出基本元数据以更新响应式 UI 状态
                let duration = demuxer.duration
                let resolution = "\(demuxer.videoWidth)x\(demuxer.videoHeight)"
                let codec = demuxer.videoCodecName

                // 4. 实例化原生 AudioQueue 音频引擎
                let player = createAudioPlayerInstance()

                DispatchQueue.main.async {
                    self.updateMetadata(duration: duration, resolution: resolution, codec: codec)
                    self.setDemuxer(demuxer)
                    self.setupAudioEngine(player: player)
                    self.changeState(to: .ready)
                    DebugLog("✅ JJPlayer 双路解码器及 AudioQueue 音频引擎就绪成功！")
                }
            } catch {
                // 捕捉底层 C 抛上来的错误并切回主线程抛给 UI 界面渲染
                let errorMsg = error.localizedDescription
                DebugLog("❌ JJPlayer 解析失败：\(errorMsg)")
                DispatchQueue.main.async {
                    self.changeState(to: .error(errorMsg))
                }
            }
        }
    }

    /// 💥【SRP 拆分：初始化解复用器和解码器】
    private func prepareDemuxer(path: String) throws -> JJDemuxer {
        let demuxer = JJDemuxer()
        try demuxer.open(url: path)
        try demuxer.initializeDecoders()
        return demuxer
    }

    /// 💥【SRP 拆分：配置视频与音频的双路闭包回调】
    private func setupCallbacks(for demuxer: JJDemuxer) {
        // 视频通道回调：预先在后台转换为 CGImage 并快速推入锁保护队列
        demuxer.setVideoCallback { [weak self] pixelBuffer, pts in
            guard let self else { return }
            handleVideoPixelBuffer(pixelBuffer, pts: pts)
        }

        // 音频通道回调：直接将解出的 PCM 字节追加至全局 audioBuffer
        demuxer.setAudioCallback { [weak self] pcmData, pts in
            guard let self else { return }
            handleAudioPCMData(pcmData, pts: pts)
        }
    }

    /// 💥【SRP 拆分：处理视频像素帧】
    private func handleVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if status == noErr, let image = cgImage {
            videoQueueLock.lock()
            videoFrameQueue.append(VideoFrame(cgImage: image, pts: pts))
            videoQueueLock.unlock()
        }
    }

    /// 💥【SRP 拆分：处理音频 PCM 数据】
    private func handleAudioPCMData(_ pcmData: Data, pts: Double) {
        audioPtsLock.lock()
        if firstAudioPTS < 0 {
            // 记录该视频源音频首帧被解复用出来的绝对 PTS，作为物理对齐基准
            firstAudioPTS = pts
        }
        audioPtsLock.unlock()

        appendAudioData(pcmData)
    }

    /// 💥【SRP 拆分：创建 AudioQueue 实例并绑定回调】
    private func createAudioPlayerInstance() -> JJAudioQueuePlayer {
        let player = JJAudioQueuePlayer()
        player.pcmDataRequester = { [weak self] capacity in
            guard let self else { return Data() }
            return consumeAudioData(length: capacity)
        }
        return player
    }
}
