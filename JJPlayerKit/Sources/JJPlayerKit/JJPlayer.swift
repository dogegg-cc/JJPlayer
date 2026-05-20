//
//  JJPlayer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation
#if canImport(ffmpegkit)
    import ffmpegkit
#endif

/// 核心视频播放控制器，遵循 ObservableObject 协议，完美兼容 SwiftUI 数据绑定机制
public final class JJPlayer: ObservableObject {
    /// 播放器当前聚合状态
    @Published public private(set) var state: JJPlayerState = .idle

    /// 当前载入媒体的总时长（秒）
    @Published public private(set) var mediaDuration: Double = 0.0

    /// 视频的分辨率（例如：1920x1080）
    @Published public private(set) var videoResolution: String = "Unknown"

    /// 视频流的编解码器名称（例如：h264, hevc）
    @Published public private(set) var videoCodec: String = "Unknown"

    public init() {
        #if canImport(ffmpegkit)
            if let version = FFmpegKitConfig.getFFmpegVersion() {
                print("🎉 JJPlayer 核心库初始化成功，底层的 FFmpeg 版本: \(version)")
            } else {
                print("⚠️ JJPlayer 初始化，但未检测到 FFmpeg 核心库版本。")
            }
        #else
            print("⚠️ JJPlayer 核心库初始化（未链接 FFmpeg 二进制库）。")
        #endif
    }

    /// 异步载入媒体文件，并利用 FFprobe 提取媒体元数据 (Metadata)
    /// - Parameter path: 本地视频文件的绝对路径或网络流 URL
    public func loadMedia(path: String) {
        state = .preparing
        print("🔄 正在载入媒体文件: \(path)")

        #if canImport(ffmpegkit)
            // 构造 FFprobe 参数：异步提取视频的 width, height, duration, codec_name
            let command = "-v error -show_entries stream=width,height,codec_name -show_entries format=duration -of default=noprint_wrappers=1 \"\(path)\""

            FFprobeKit.executeAsync(command) { [weak self] session in
                guard let self, let session else { return }

                let returnCode = session.getReturnCode()
                if ReturnCode.isSuccess(returnCode) {
                    // 读取解析到的输出
                    if let output = session.getOutput() {
                        print("✅ FFprobe 解析元数据成功:\n\(output)")

                        // 切换回主线程更新 UI 绑定的属性
                        DispatchQueue.main.async {
                            self.parseMetadataOutput(output)
                            self.state = .ready
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.state = .error("FFprobe 元数据解析失败：输出为空")
                        }
                    }
                } else {
                    let errorVal = session.getReturnCode()?.getValue() ?? -1
                    let errorMsg = "FFprobe 执行失败，错误码: \(errorVal)"
                    print("❌ \(errorMsg)")
                    DispatchQueue.main.async {
                        self.state = .error(errorMsg)
                    }
                }
            }
        #else
            // 降级沙盒演示
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.mediaDuration = 120.0
                self.videoResolution = "1920x1080"
                self.videoCodec = "h264"
                self.state = .ready
                print("⚠️ 未发现 FFmpeg 环境，启用沙盒模拟播放就绪。")
            }
        #endif
    }

    /// 解析 FFprobe 键值对控制台输出
    private func parseMetadataOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        var width = ""
        var height = ""

        for line in lines {
            let parts = line.components(separatedBy: "=")
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

                switch key {
                case "duration":
                    if let dur = Double(value) {
                        mediaDuration = dur
                    }
                case "width":
                    width = value
                case "height":
                    height = value
                case "codec_name":
                    videoCodec = value
                default:
                    break
                }
            }
        }

        if !width.isEmpty, !height.isEmpty {
            videoResolution = "\(width)x\(height)"
        }
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
