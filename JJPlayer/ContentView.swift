//
//  ContentView.swift
//  JJPlayer
//
//  Created by 我勒个去去 on 2026/5/20.
//

import JJPlayerKit
import SwiftUI

// ==============================================================================

// MARK: - 主骨架入口视图 (极致组件化：主视图 body 仅有 16 行声明式组合，完全遵循 SRP)

// ==============================================================================
struct ContentView: View {
    // 实例化底层的播放控制核心
    @StateObject private var player = JJPlayer()

    // 输入的媒体路径或网络 URL，默认提供西瓜播放器的高速国内测试视频
    @State private var mediaPath: String = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"

    // 动画状态控制
    @State private var isAnalyzing: Bool = false

    var body: some View {
        ZStack {
            // 组件 1：高颜值炫彩与动态光晕背景
            BackgroundGradientView()

            ScrollView {
                VStack(spacing: 28) {
                    // 组件 2：页面 Header 标题区
                    HeaderSection()

                    // 组件 3：媒体源输入区 (毛玻璃拟物卡片)
                    MediaInputCard(mediaPath: $mediaPath, player: player, isAnalyzing: $isAnalyzing)

                    // 组件 4：核心引擎状态与元数据监测面板 (毛玻璃拟物卡片)
                    StatusPanel(player: player)

                    // 组件 4.5：阶段二高吞吐硬件加速播放与控制台 (就绪/播放中/暂停/完成状态下淡入展示)
                    if player.state == .ready || player.state == .playing || player.state == .paused || player.state == .completed {
                        VideoPlayerCard(player: player)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // 组件 5：FFmpeg 学习笔记提示栏
                    StudyNotesCard()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}

// ==============================================================================

// MARK: - 1. 背景组件 (单一职责：炫彩渐变与动态光晕)

// ==============================================================================
struct BackgroundGradientView: View {
    var body: some View {
        ZStack {
            // 现代底色炫彩背景渐变
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.15), Color(red: 0.15, green: 0.12, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // 炫酷的动态背景光晕模糊层
            VStack {
                HStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 250, height: 250)
                        .blur(radius: 80)
                        .offset(x: -50, y: -50)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Circle()
                        .fill(Color.purple.opacity(0.18))
                        .frame(width: 300, height: 300)
                        .blur(radius: 90)
                        .offset(x: 80, y: 100)
                }
            }
            .ignoresSafeArea()
        }
    }
}

// ==============================================================================

// MARK: - 2. 头部组件 (单一职责：主副标题渲染)

// ==============================================================================
struct HeaderSection: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("JJPLAYER CORES")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.blue)
                .tracking(4)
                .padding(.top, 20)

            Text("FFmpeg 媒体探测器")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)

            Text("阶段一：提取流媒体封装元数据 (FFprobe 驱动)")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
    }
}

// ==============================================================================

// MARK: - 3. 拟物化毛玻璃卡片容器 (通用样式抽象，杜绝卡片边框/阴影的重复代码)

// ==============================================================================
struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
    }
}

// ==============================================================================

// MARK: - 4. 媒体输入组件 (单一职责：地址输入与加载触发按钮组合)

// ==============================================================================
struct MediaInputCard: View {
    @Binding var mediaPath: String
    @ObservedObject var player: JJPlayer
    @Binding var isAnalyzing: Bool

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("输入媒体源 (本地路径 / 网络 URL)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))

                // 输入单行组件
                MediaInputField(mediaPath: $mediaPath)

                // 动作按钮组件
                ActionButton(player: player, action: triggerAnalysis)
            }
        }
    }

    private func triggerAnalysis() {
        withAnimation(.spring()) {
            isAnalyzing = true
            player.loadMedia(path: mediaPath)
        }
    }
}

// ==============================================================================

// MARK: - 4.1 媒体源输入行组件 (单一职责：输入控制与清除功能)

// ==============================================================================
struct MediaInputField: View {
    @Binding var mediaPath: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .foregroundColor(.blue)
                .font(.title3)

            TextField("请输入视频地址...", text: $mediaPath)
                .foregroundColor(.white)
                .font(.system(size: 14, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .accessibilityIdentifier("media_input_text_field")

            if !mediaPath.isEmpty {
                Button(action: { mediaPath = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// ==============================================================================

// MARK: - 4.2 动作触发按钮 (单一职责：解析加载状态与按钮交互)

// ==============================================================================
struct ActionButton: View {
    @ObservedObject var player: JJPlayer
    let action: () -> Void

    private var isPreparing: Bool {
        player.state == .preparing
    }

    var body: some View {
        Button(action: action) {
            HStack {
                if isPreparing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.9)
                        .padding(.trailing, 6)
                } else {
                    Image(systemName: "play.cpu.fill")
                        .font(.system(size: 16, weight: .bold))
                }

                Text(isPreparing ? "正在通过 FFprobe 解析..." : "开始提取元数据")
                    .fontWeight(.bold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.purple],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.blue.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .disabled(isPreparing)
        .accessibilityIdentifier("start_probing_button")
    }
}

// ==============================================================================

// MARK: - 5. 状态监测面板组件 (单一职责：分发并包裹具体状态面板)

// ==============================================================================
struct StatusPanel: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                // 状态栏头部
                HStack {
                    Text("核心引擎状态机")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()

                    StateBadge(state: player.state)
                }

                Divider()
                    .background(Color.white.opacity(0.1))

                // 根据状态机分发渲染子视图 (确保每种状态由完全单一职责的小 View 承担)
                switch player.state {
                case .ready, .playing, .paused, .completed:
                    MetadataDetailsView(player: player)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                case let .error(errorMsg):
                    ErrorPanel(errorMessage: errorMsg)
                default:
                    IdleWaitingPanel()
                }
            }
        }
    }
}

// ==============================================================================

// MARK: - 5.1 状态徽章组件 (单一职责：解析状态的文案和颜色映射)

// ==============================================================================
struct StateBadge: View {
    let state: JJPlayerState

    private var config: (text: String, color: Color) {
        switch state {
        case .idle: ("IDLE", .gray)
        case .preparing: ("PROBING...", .blue)
        case .ready: ("READY", .green)
        case .playing: ("PLAYING", .purple)
        case .paused: ("PAUSED", .orange)
        case .completed: ("COMPLETED", .teal)
        case .error: ("ERROR", .red)
        }
    }

    var body: some View {
        Text(config.text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(config.color.opacity(0.2))
            .foregroundColor(config.color)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(config.color.opacity(0.4), lineWidth: 1)
            )
    }
}

// ==============================================================================

// MARK: - 5.2 元数据详情列表组件 (单一职责：解析成功后的多条属性垂直排版)

// ==============================================================================
struct MetadataDetailsView: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        VStack(spacing: 16) {
            // 调用沉淀在播放器 SDK 内部的 Double+Format 核心工具时间格式化扩展
            MetadataRow(title: "视频总时长", value: player.mediaDuration.formattedDurationString, icon: "clock.fill", color: .green)
            MetadataRow(title: "视频分辨率", value: player.videoResolution, icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", color: .orange)
            MetadataRow(title: "视频编码格式", value: player.videoCodec.isEmpty ? "UNKNOWN" : player.videoCodec.uppercased(), icon: "cpu.fill", color: .pink)
        }
    }
}

// ==============================================================================

// MARK: - 5.3 单个元数据数据行组件 (单一职责：渲染单条属性细节卡片)

// ==============================================================================
struct MetadataRow: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }
}

// ==============================================================================

// MARK: - 5.4 错误提示面板组件 (单一职责：渲染探测失败的警告信息)

// ==============================================================================
struct ErrorPanel: View {
    let errorMessage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("解析失败")
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.15))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}

// ==============================================================================

// MARK: - 5.5 空闲等待面板组件 (单一职责：未载入视频时的引导提示)

// ==============================================================================
struct IdleWaitingPanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.2))
            Text("等待载入媒体源")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

// ==============================================================================

// MARK: - 6. 学习笔记提示卡片组件 (单一职责：静态 FFmpeg 命令行原理说明)

// ==============================================================================
struct StudyNotesCard: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("FFmpeg 学习笔记", systemImage: "lightbulb.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow)

                Text("当前已成功调通 FFmpegKit 导出的 FFprobe 底层接口。在 loadMedia() 中，我们异步执行了 FFprobe 探测命令，其底层实现机制类似于在 Shell 中执行：")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineSpacing(4)

                Text("ffprobe -v error -show_entries stream=width,height,codec_name -show_entries format=duration -of default=noprint_wrappers=1 <URL>")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(10)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(8)
                    .foregroundColor(.green.opacity(0.9))
            }
        }
    }
}
