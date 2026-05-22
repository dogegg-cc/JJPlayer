//
//  JJPlayer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import CoreVideo
import Foundation
import JJFFmpegCore
import QuartzCore

/// 核心视频与音频播放控制器
///
/// 【学习笔记 - 遵循 ObservableObject 的现代响应式架构】
/// `JJPlayer` 遵循 `ObservableObject` 协议，并将其核心媒体状态（如 state、duration、codec等）
/// 使用 `@Published` 进行修饰。一旦后台解析线程修改了这些属性，SwiftUI 的声明式 UI 系统
/// 就会自动截获变更、驱动整个视图组件优雅重绘。
public final class JJPlayer: ObservableObject {
    /// 播放器当前聚合状态 (闲置、解析中、就绪、播放中、出错等)
    @Published public private(set) var state: JJPlayerState = .idle

    /// 当前载入媒体的总时长（秒）
    @Published public private(set) var mediaDuration: Double = 0.0

    /// 视频的分辨率描述（如：1920x1080）
    @Published public private(set) var videoResolution: String = "Unknown"

    /// 视频流的编解码器名称（如：h264, hevc）
    @Published public private(set) var videoCodec: String = "Unknown"

    /// 当前解码出的 iOS CoreVideo 视频帧的 CGImage，绑定至原生 SwiftUI 图像层高速直出渲染
    @Published public private(set) var currentFrame: CGImage?

    /// 当前播放位置（秒，响应式）
    @Published public private(set) var currentTime: Double = 0.0

    /// 当前已缓存到的最大绝对时间点（秒，响应式）
    @Published public private(set) var bufferedTime: Double = 0.0

    /// 网络已缓存百分比进度 (0.0 ~ 1.0，响应式)
    @Published public private(set) var bufferProgress: Double = 0.0

    /// 解码线程是否已经全部读取解复用完成 (EOF)
    @Published public private(set) var isDecodingEOF: Bool = false

    /// 音频播放物理音量（范围 0.0 ~ 1.0）
    @Published public var volume: Float = 1.0 {
        didSet {
            audioPlayer?.volume = volume
        }
    }

    /// 一键静音开关
    @Published public var isMuted: Bool = false {
        didSet {
            audioPlayer?.isMuted = isMuted
        }
    }

    /// 播放倍速（0.75, 1.0, 1.25, 1.5, 2.0, 3.0 等）
    @Published public var playbackRate: Float = 1.0 {
        didSet {
            audioPlayer?.playbackRate = playbackRate
        }
    }

    // 持有底层解复用与解码控制核心，保证在播放生命周期中不被提前释放
    var activeDemuxer: JJDemuxer?

    // 后台高优先级解码专用线程队列
    let decodeQueue = DispatchQueue(label: "cc.dogegg.JJPlayer.decode", qos: .userInteractive)

    // 后台串行载入/切换媒体专用队列，物理隔离并阻断多线程重入探测导致的 C 内存冲突与崩溃
    let mediaLoaderQueue = DispatchQueue(label: "cc.dogegg.JJPlayer.loader", qos: .userInitiated)

    // 控制解码渲染循环是否继续
    var isPlayingLoop: Bool = false

    // --------------------------------------------------
    // 【阶段三新增：线程安全音频缓冲队列与 AudioQueue 实例】
    // --------------------------------------------------
    // 线程安全锁，保障后台解码线程追加 PCM 与系统声卡回调消费互斥，杜绝多线程数据竞争
    let audioLock = JJUnfairLock()

    // 高吞吐量音频 PCM 帧数据追加队列
    var audioBuffer = Data()

    // iOS 底层 AudioQueue 原生音频引擎实例
    var audioPlayer: JJAudioQueuePlayer?

    // --------------------------------------------------
    // 【阶段四新增：音视频高精度同步时钟与视频队列】
    // --------------------------------------------------
    struct VideoFrame {
        let cgImage: CGImage
        let pts: Double
    }

    // 视频帧缓冲队列与高速锁
    var videoFrameQueue = [VideoFrame]()
    let videoQueueLock = JJUnfairLock()

    // 音频首帧发声 PTS 物理时间戳追踪基准
    var firstAudioPTS: Double = -1.0
    let audioPtsLock = JJUnfairLock()

    // CADisplayLink 渲染触发回路
    var displayLink: CADisplayLink?

    public init() {
        // 验证手搓的底层 C 混编核心是否连接成功
        DebugLog("🎉 JJPlayer 核心库初始化成功，底层 C 混编核心 [JJFFmpegCore] 已就绪！")
    }

    // --------------------------------------------------

    // MARK: - 💥【SRP 拆分状态写入助手】

    // --------------------------------------------------
    // 由于 Swift 的 private(set) 限制，Extension 无法直接写入 Published 属性。
    // 我们提供以下 internal 助手方法，以绝对安全、高内聚的方式支持 Extension 的状态与渲染帧修改。

    func changeState(to newState: JJPlayerState) {
        state = newState
    }

    func updateDecodingEOF(_ isEOF: Bool) {
        isDecodingEOF = isEOF
    }

    func updateCurrentFrame(_ frame: CGImage?) {
        currentFrame = frame
    }

    func updateCurrentTime(_ time: Double) {
        currentTime = time
    }

    func updateMetadata(duration: Double, resolution: String, codec: String) {
        mediaDuration = duration
        videoResolution = resolution
        videoCodec = codec
    }

    func setupAudioEngine(player: JJAudioQueuePlayer?) {
        audioPlayer = player
    }

    func setDemuxer(_ demuxer: JJDemuxer?) {
        activeDemuxer = demuxer
    }

    func resetPlayProgress() {
        currentTime = 0.0
        bufferedTime = 0.0
        bufferProgress = 0.0
        mediaDuration = 0.0
        videoResolution = "Unknown"
        videoCodec = "Unknown"
        currentFrame = nil
        isDecodingEOF = false
    }

    func updateBufferMetrics() {
        let maxRead = activeDemuxer?.maxReadPTS ?? 0.0
        if bufferedTime != maxRead {
            bufferedTime = maxRead
            bufferProgress = mediaDuration > 0 ? min(1.0, maxRead / mediaDuration) : 0.0
        }
    }
}
