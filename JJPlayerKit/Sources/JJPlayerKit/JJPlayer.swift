//
//  JJPlayer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import ffmpegkit
import Foundation

/// 核心视频播放控制器
///
/// 【学习笔记 - 遵循 ObservableObject 的现代响应式架构】
/// `JJPlayer` 遵循 `ObservableObject` 协议，并将其核心媒体状态（如 state、duration、codec等）
/// 使用 `@Published` 进行修饰。一旦后台解析线程修改了这些属性，SwiftUI 的声明式 UI 系统
/// 就会自动截获变更、驱动整个视图组件优雅重绘。这是现代 iOS 开发中数据驱动 UI 的最优雅范式。
public final class JJPlayer: ObservableObject {
    /// 播放器当前聚合状态 (闲置、解析中、就绪、播放中、出错等)
    @Published public private(set) var state: JJPlayerState = .idle

    /// 当前载入媒体的总时长（秒）
    @Published public private(set) var mediaDuration: Double = 0.0

    /// 视频的分辨率描述（如：1920x1080）
    @Published public private(set) var videoResolution: String = "Unknown"

    /// 视频流的编解码器名称（如：h264, hevc）
    @Published public private(set) var videoCodec: String = "Unknown"

    public init() {
        #if canImport(ffmpegkit)
            // 编译条件分支测试：验证底层的 FFmpegKit 二进制静态库是否成功链接
            if let version = FFmpegKitConfig.getFFmpegVersion() {
                print("🎉 JJPlayer 核心库初始化成功，底层的 FFmpeg 版本: \(version)")
            } else {
                print("⚠️ JJPlayer 初始化，但未检测到 FFmpeg 核心库版本。")
            }
        #else
            print("⚠️ JJPlayer 核心库初始化（未链接 FFmpeg 二进制库）。")
        #endif
    }

    /// 异步载入媒体文件，利用手写的 C API 解复用核心 (JJDemuxer) 提取流级别元数据
    ///
    /// 【学习笔记 - 极佳的异步线程模型 (I/O 密集型解耦)】
    /// 探测多媒体流 (FFprobe 机制) 伴随着繁重的磁盘读取或网络请求 (高耗时的 I/O 操作)。
    /// 如果在主线程执行，会导致 UI 瞬间冻结 (卡死)，给用户带来极差的卡顿体验。
    ///
    /// 我们的多线程执行方案：
    /// 1. 改变状态为 `.preparing` -> 立即通知 SwiftUI 渲染炫酷的 Loading 动画。
    /// 2. 使用 `DispatchQueue.global(qos: .userInitiated).async` 开启高优先级的后台工作线程进行 I/O 探测。
    /// 3. 用 `[weak self]` 弱引用防止在解析过程中玩家提前退出视图导致的内存循环引用和野指针崩溃。
    /// 4. 成功或失败后，必须使用 `DispatchQueue.main.async` 切回主线程更新 UI 绑定属性。
    ///
    /// - Parameter path: 本地视频文件的绝对路径或网络流 URL
    public func loadMedia(path: String) {
        state = .preparing
        print("🔄 正在载入媒体文件: \(path)")

        #if canImport(ffmpegkit)
            // 开启异步后台线程
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }

                // 实例化我们的解复用核心
                let demuxer = JJDemuxer()
                do {
                    // 执行探测 (可能会抛出网络 403 / 路径非法等错误)
                    try demuxer.open(url: path)

                    // 回到主线程更新 UI 绑定属性与状态机 (UI 操作必须在主线程执行！)
                    DispatchQueue.main.async {
                        self.mediaDuration = demuxer.duration
                        self.videoResolution = "\(demuxer.videoWidth)x\(demuxer.videoHeight)"
                        self.videoCodec = demuxer.videoCodecName
                        self.state = .ready
                        print("✅ JJPlayer 底层 C 接口解析元数据成功：时长=\(demuxer.duration)s, 分辨率=\(demuxer.videoWidth)x\(demuxer.videoHeight), 编码=\(demuxer.videoCodecName)")
                    }
                } catch {
                    // 捕捉底层 C 抛上来的错误并切回主线程抛给 UI 界面渲染
                    let errorMsg = error.localizedDescription
                    print("❌ JJPlayer 解析失败：\(errorMsg)")
                    DispatchQueue.main.async {
                        self.state = .error(errorMsg)
                    }
                }
            }
        #else
            // 降级沙盒演示分支：若当前处于非 iOS 模拟器/无真机 FFmpeg 条件下，启动优雅降级演示
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.mediaDuration = 120.0
                self.videoResolution = "1920x1080"
                self.videoCodec = "h264"
                self.state = .ready
                print("⚠️ 未发现 FFmpeg 环境，启用沙盒模拟播放就绪。")
            }
        #endif
    }

    /// 开始播放
    public func play() {
        guard state == .ready || state == .paused else { return }
        state = .playing
        print("▶️ 视频开始播放...")
    }

    /// 暂停播放
    public func pause() {
        guard state == .playing else { return }
        state = .paused
        print("⏸ 视频暂停播放。")
    }

    /// 停止播放并重置所有媒体状态
    public func stop() {
        state = .idle
        mediaDuration = 0.0
        videoResolution = "Unknown"
        videoCodec = "Unknown"
        print("⏹ 视频停止播放并重置状态机。")
    }
}
