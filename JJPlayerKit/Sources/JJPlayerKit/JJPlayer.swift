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
import VideoToolbox

/// 核心视频与音频播放控制器
///
/// 【学习笔记 - 遵循 ObservableObject 的现代响应式架构】
/// `JJPlayer` 遵循 `ObservableObject` 协议，并将其核心媒体状态（如 state、duration、codec等）
/// 使用 `@Published` 进行修饰。一旦后台解析线程修改了这些属性，SwiftUI 的声明式 UI 系统
/// 就会自动截获变更、驱动整个视图组件优雅重绘。
///
/// 【阶段三重大重构：音视频一站式闭包分发与流量控制】
/// 淘汰了旧有的视频单路解包模式，打通了“一站式 decodeAndDispatch 单一读取驱动 + Swift 双路异步生产队列”架构，
/// 并首创了“基于音频缓冲水位的动态流量控制 (Audio Buffer Flow Control)”限速算法，实现完美声画连续发声。
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

    // 持有底层解复用与解码控制核心，保证在播放生命周期中不被提前释放
    private var activeDemuxer: JJDemuxer?

    // 后台高优先级解码专用线程队列
    private let decodeQueue = DispatchQueue(label: "cc.dogegg.JJPlayer.decode", qos: .userInteractive)

    // 后台串行载入/切换媒体专用队列，物理隔离并阻断多线程重入探测导致的 C 内存冲突与崩溃
    private let mediaLoaderQueue = DispatchQueue(label: "cc.dogegg.JJPlayer.loader", qos: .userInitiated)

    // 控制解码渲染循环是否继续
    private var isPlayingLoop: Bool = false

    // --------------------------------------------------
    // 【阶段三新增：线程安全音频缓冲队列与 AudioQueue 实例】
    // --------------------------------------------------
    // 线程安全锁，保障后台解码线程追加 PCM 与系统声卡回调消费互斥，杜绝多线程数据竞争
    // 💥【重大优化：使用 Darwin 原生高性能 os_unfair_lock 杜绝优先级反转与卡顿】
    private let audioLock = JJUnfairLock()

    // 高吞吐量音频 PCM 帧数据追加队列
    private var audioBuffer = Data()

    // iOS 底层 AudioQueue 原生音频引擎实例
    private var audioPlayer: JJAudioQueuePlayer?

    // --------------------------------------------------
    // 【阶段四新增：音视频高精度同步时钟与视频队列】
    // --------------------------------------------------
    private struct VideoFrame {
        let cgImage: CGImage
        let pts: Double
    }

    // 视频帧缓冲队列与高速低级锁
    private var videoFrameQueue = [VideoFrame]()
    private let videoQueueLock = JJUnfairLock()

    // 音频首帧发声 PTS 物理时间戳追踪基准
    private var firstAudioPTS: Double = -1.0
    private let audioPtsLock = JJUnfairLock()

    // CADisplayLink 渲染触发回路
    private var displayLink: CADisplayLink?

    public init() {
        // 验证手搓的底层 C 混编核心是否连接成功
        DebugLog("🎉 JJPlayer 核心库初始化成功，底层 C 混编核心 [JJFFmpegCore] 已就绪！")
    }

    /// 异步载入媒体文件，利用手写的 C API 解复用核心 (JJDemuxer) 提取流级别元数据
    ///
    /// - Parameter path: 本地视频文件的绝对路径或网络流 URL
    public func loadMedia(path: String) {
        state = .preparing
        DebugLog("🔄 正在载入媒体文件: \(path)")

        // 所有的 loadMedia、stop 逻辑全部放入串行队列按顺序行进，物理上隔离多线程并发冲突
        mediaLoaderQueue.async { [weak self] in
            guard let self else { return }
            do {
                // 1. 初始化 C 解复用核心 (JJDemuxer) 并打开媒体文件
                let demuxer = JJDemuxer()
                try demuxer.open(url: path)
                try demuxer.initializeDecoders()

                // 2. 读出基本元数据以更新响应式 UI 状态
                let duration = demuxer.duration
                let resolution = "\(demuxer.videoWidth)x\(demuxer.videoHeight)"
                let codec = demuxer.videoCodecName

                // 3. 配置视频与音频的双路闭包回调
                // 视频通道回调：预先在后台转换为 CGImage 并快速推入锁保护队列，主线程只消费不转换，保障绝对的物理效能！
                demuxer.setVideoCallback { [weak self] pixelBuffer, pts in
                    guard let self else { return }

                    // 将 iOS CVPixelBuffer 预先后台零拷贝换算为 CGImage
                    // 💥【硬核性能优化：解放主线程，后台提前解码渲染像素】
                    var cgImage: CGImage?
                    let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
                    if status == noErr, let image = cgImage {
                        videoQueueLock.lock()
                        videoFrameQueue.append(VideoFrame(cgImage: image, pts: pts))
                        videoQueueLock.unlock()
                    }
                }

                // 音频通道回调：直接将解出的 PCM 字节追加至全局 audioBuffer
                demuxer.setAudioCallback { [weak self] pcmData, pts in
                    guard let self else { return }

                    audioPtsLock.lock()
                    if firstAudioPTS < 0 {
                        // 记录该视频源音频首帧被解复用出来的绝对 PTS，作为物理对齐基准
                        firstAudioPTS = pts
                    }
                    audioPtsLock.unlock()

                    appendAudioData(pcmData)
                }

                DispatchQueue.main.async {
                    self.activeDemuxer = demuxer
                    self.mediaDuration = duration
                    self.videoResolution = resolution
                    self.videoCodec = codec
                    self.state = .ready

                    // --------------------------------------------------
                    // C. 实例化原生 AudioQueue 音频引擎并配置数据请求回调
                    // --------------------------------------------------
                    let player = JJAudioQueuePlayer()
                    player.pcmDataRequester = { [weak self] capacity in
                        guard let self else { return Data() }
                        // 当声卡回调触发，0ms 延迟从我们安全的队列中消费提货投喂给声卡
                        return consumeAudioData(length: capacity)
                    }
                    self.audioPlayer = player

                    DebugLog("✅ JJPlayer 双路解码器及 AudioQueue 音频引擎就绪成功！")
                }
            } catch {
                // 捕捉底层 C 抛上来的错误并切回主线程抛给 UI 界面渲染
                let errorMsg = error.localizedDescription
                DebugLog("❌ JJPlayer 解析失败：\(errorMsg)")
                DispatchQueue.main.async {
                    self.state = .error(errorMsg)
                }
            }
        }
    }

    /// 开始播放
    public func play() {
        guard state == .ready || state == .paused else { return }
        state = .playing
        isPlayingLoop = true
        DebugLog("▶️ 开始播放，启动专属一站式双流后台解码循环...")

        // 1. 物理激活底层 AudioQueue 引擎，驱动声卡开始连续消费发声
        audioPlayer?.play()

        // 2. 启动屏幕刷新同步回路 (displayLink)
        DispatchQueue.main.async { [weak self] in
            self?.startDisplayLink()
        }

        // 3. 开启高优先级后台解码工作流，单一物理读取流，避免阻塞 UI 线程
        decodeQueue.async { [weak self] in
            while true {
                // 并发红线防线：检测播放状态与强安全 weak self 校验
                guard let self else { break }
                guard isPlayingLoop, let demuxer = activeDemuxer else { break }

                // 核心 C API：一站式从底层多媒体流中提取、解码并分发单个数据包
                let status = demuxer.decodeAndDispatch()

                if status == 0 {
                    // 成功处理了一个音/视频帧数据包
                    // 💥 【阶段四硬核升级：音视频双重流量控制 (Dual Flow Control)】
                    // 同时关联音频缓冲水位（256KB，约1.5秒容量）与视频帧队列长度（24帧，约0.8秒缓冲）。
                    // 当任何一个达到上限时，挂起解码线程 33ms，实现最平稳的供求自适应与极低内存损耗！
                    let currentWatermark = getAudioBufferSize()
                    let currentVideoFrames = getVideoFrameQueueCount()
                    if currentWatermark > 256 * 1024 || currentVideoFrames > 24 {
                        Thread.sleep(forTimeInterval: 0.033) // 缓冲区饱满，解码线程歇息一帧时间
                    } else {
                        // 预缓冲加速充盈中，微调度让出 CPU 时间片，防止死锁
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                } else if status == -1 {
                    // 读完视频或出错，切回主线程安全停止
                    DispatchQueue.main.async {
                        self.stop()
                    }
                    break
                } else {
                    // status == 1 代表处理了无关数据包（如字幕等），极速空转，不作休眠，以便快速寻找到下一个有效帧
                }
            }
        }
    }

    /// 暂停播放
    public func pause() {
        guard state == .playing else { return }
        isPlayingLoop = false // 关闭循环标识，后台解码线程会在下一周自适应安全退出

        // 暂停声卡播放发声，保持缓冲区排队数据不丢失
        audioPlayer?.pause()

        // 暂停屏幕刷新同步回路
        DispatchQueue.main.async { [weak self] in
            self?.stopDisplayLink()
        }

        state = .paused
        DebugLog("⏸ 音视频暂停播放。")
    }

    /// 停止播放并重置所有媒体状态
    public func stop() {
        isPlayingLoop = false // 关闭循环标识，后台解码线程自适应退出

        // 物理截断声卡发声，销毁 AudioQueue 管道与内存
        audioPlayer?.stop()
        audioPlayer = nil

        // 注销屏幕刷新同步回路
        DispatchQueue.main.async { [weak self] in
            self?.stopDisplayLink()
        }

        // 线程安全清空 PCM 数据缓冲，防止下一次播放时残留杂音
        audioLock.lock()
        audioBuffer.removeAll(keepingCapacity: false)
        audioLock.unlock()

        // 物理清空视频帧缓冲队列
        videoQueueLock.lock()
        videoFrameQueue.removeAll(keepingCapacity: false)
        videoQueueLock.unlock()

        // 重置音频首帧发声 PTS 时间戳追踪基准
        audioPtsLock.lock()
        firstAudioPTS = -1.0
        audioPtsLock.unlock()

        state = .idle
        mediaDuration = 0.0
        videoResolution = "Unknown"
        videoCodec = "Unknown"
        currentFrame = nil
        activeDemuxer?.close() // 手动强制闭合解复用器，销毁所有 C 指针内存
        activeDemuxer = nil
        DebugLog("⏹ 停止播放并物理重置状态机、音频引擎与同步时钟。")
    }

    // --------------------------------------------------

    // MARK: - 线程安全音频 PCM 字节队列存取封装

    // --------------------------------------------------

    private func appendAudioData(_ data: Data) {
        audioLock.lock()
        audioBuffer.append(data)
        audioLock.unlock()
    }

    private func consumeAudioData(length: Int) -> Data {
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

    private func getAudioBufferSize() -> Int {
        audioLock.lock()
        let count = audioBuffer.count
        audioLock.unlock()
        return count
    }

    // --------------------------------------------------

    // MARK: - 音视频同步 (AV Sync) 核心引擎与流控

    // --------------------------------------------------

    private func startDisplayLink() {
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

    private func stopDisplayLink() {
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
    private func getAudioPrimaryClock() -> Double {
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

    private func getVideoFrameQueueCount() -> Int {
        videoQueueLock.lock()
        let count = videoFrameQueue.count
        videoQueueLock.unlock()
        return count
    }

    /// 高频音视频同步主决策循环 (在主线程随屏幕刷新帧同步调用)
    @objc private func updateSyncLoop() {
        guard state == .playing else { return }

        // 1. 获取最精确 of 音频发声时钟 (Audio Primary Clock)
        let audioClock = getAudioPrimaryClock()

        videoQueueLock.lock()
        defer { videoQueueLock.unlock() }

        // 2. 双向快速追赶决策
        while !videoFrameQueue.isEmpty {
            let nextFrame = videoFrameQueue[0]
            let diff = nextFrame.pts - audioClock

            if diff < -0.04 {
                // A. 视频帧落后于音频超过 40ms：表示该画面已经过时，果断执行【快速丢帧】！
                // 不触发 CGImage 的主线程渲染逻辑，直接 removeFirst() 继续 while 轮询下一帧，直到追平音频
                videoFrameQueue.removeFirst()
                continue
            } else if diff > 0.04 {
                // B. 视频帧超前于音频超过 40ms：说明画面超前声音，音频还没播放到这一秒
                // 停止渲染画面，break 跳出，将当前帧维持在队首，等待下一个 displayLink 脉冲
                break
            } else {
                // C. 完美落入声画极精对齐区间 [-40ms, 40ms]
                // 触发主线程直接上色渲染，并消费移除此帧
                currentFrame = nextFrame.cgImage
                videoFrameQueue.removeFirst()
                break
            }
        }
    }
}
