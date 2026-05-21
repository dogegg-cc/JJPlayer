//
//  JJDemuxer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation
import JJFFmpegCore

/// 底层媒体流解复用器 (Demuxer)
///
/// 【学习笔记 - 解复用器在播放器中的地位】
/// 解复用器 (Demuxer) 是任何视频播放器流水线的「排头兵」。
/// 它的唯一核心职责就是：打开多媒体容器文件 (如 .mp4, .mkv, .flv)，
/// 解析其容器头信息，分离出一条视频流和一条音频流，并把流级别的信息 (元数据、编解码配置) 传给上层，
/// 为后续的视频解码 (Video Decode) 和音频解码 (Audio Decode) 做好所有的准备工作。
///
/// 【架构设计 - 现代 Swift 安全隔离设计】
/// 既然 FFmpeg 的 C 指针 (AVFormatContext 等) 充斥着 unsafe 指针和内存泄漏危险，
/// `JJDemuxer` 通过持有底层的 `JJFFmpegBridge` 实例，将 Objective-C 的非 ARC 类型优雅地
/// 转换为 Swift 中的强类型和安全属性，从而将 C 语言的安全隐患彻底杜绝在 Framework 底层。
public final class JJDemuxer {
    // 实例化底层的 C/ObjC 桥接器，在 dealloc 时自动释放底层 C 内存
    private let bridge = JJFFmpegBridge()

    /// 视频流的索引位置，若无视频流则为 -1
    /// 通过计算属性安全屏蔽了底层的 int 转换，直接输出标准的 Swift Int
    public var videoStreamIndex: Int { Int(bridge.videoStreamIndex) }

    /// 音频流的索引位置，若无音频流则为 -1
    public var audioStreamIndex: Int { Int(bridge.audioStreamIndex) }

    /// 媒体的总时长（秒）
    public var duration: Double { bridge.duration }

    /// 视频像素物理宽度
    public var videoWidth: Int32 { Int32(bridge.videoWidth) }

    /// 视频像素物理高度
    public var videoHeight: Int32 { Int32(bridge.videoHeight) }

    /// 视频编解码器简称 (例如: "h264", "hevc")，直接在 UI 上渲染展示
    public var videoCodecName: String { bridge.videoCodecName }

    /// 音频编解码器简称 (例如: "aac", "mp3")
    public var audioCodecName: String { bridge.audioCodecName }

    public init() {}

    /// 使用底层 C 接口异步打开视频输入源，并探测多媒体流的深度细节
    ///
    /// 这是播放器的首次 I/O 交互，如果打开的是网络流，该方法可能产生可预知的网络阻断或 403 Forbidden 错误。
    /// 错误会通过底层的 NSError 封装并直接通过 `throws` 机制优雅抛给 Swift 的调用者。
    ///
    /// - Parameter url: 本地路径 (POSIX 绝对路径) 或网络流 URL 字符串
    public func open(url: String) throws {
        try bridge.openURL(url)
    }

    /// 释放全部解复用器占用的核心对象和底层 C 资源
    public func close() {
        bridge.close()
    }

    // ==============================================================================

    // MARK: - 【阶段二：视频解码与渲染桥接接口】

    // ==============================================================================

    /// 激活底层 C 语言视频解码通道，分配解码器上下文
    public func initializeVideoDecoder() throws {
        try bridge.initializeVideoDecoder()
    }

    /// 从媒体流中抽取数据包并解码出下一帧原始视频图像 (CVPixelBuffer)
    ///
    /// 【学习笔记 - Swift-C 混编的 Unmanaged 内存转移】
    /// 在 C 世界分配的 CVPixelBufferRef 在 ObjC 桥接中返回时为 `Unmanaged<CVPixelBuffer>` 可选类型。
    /// 在 Swift 中，我们必须使用 `takeRetainedValue()`。这句神奇的代码会向 Swift 编译器声明：
    /// “将底层 C 分配的内存所有权直接移转并 Retain 给 Swift ARC 自动引用计数”。
    /// 自此，这一块物理显存缓冲区将被 Swift 强安全接管，并在离开作用域时 100% 自动被 ARC 销毁，优雅杜绝了 C 级泄露。
    ///
    /// - Returns: 解码好的 iOS 硬件兼容像素缓冲区，若读完流或出错则返回 nil
    public func decodeNextFrame() -> CVPixelBuffer? {
        guard let unmanaged = bridge.decodeNextFrame() else { return nil }
        return unmanaged.takeRetainedValue()
    }
}
