//
//  VideoPlayerCard.swift
//  JJPlayer
//
//  Created by Antigravity on 2026/5/22.
//

import Combine
import JJPlayerKit
import SwiftUI

// ==============================================================================
//

// MARK: - 7. 视频播放渲染与拟物控制卡片组件 (单一职责：集成视频渲染与物理控制面板)

//
// ==============================================================================
struct VideoPlayerCard: View {
    @ObservedObject var player: JJPlayer

    @State private var isDraggingSlider: Bool = false
    @State private var sliderValue: Double = 0.0

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                // 1. 播放器视口头部标题与心跳指示灯
                HeaderView(player: player)

                // 2. 16:9 GPU 硬件加速渲染视口底座
                RenderViewportView(player: player)

                // 3. 播放进度 Seek 控制与网络缓存进度条
                PlaybackSliderView(
                    player: player,
                    isDraggingSlider: $isDraggingSlider,
                    sliderValue: $sliderValue
                )

                // 4. 音频控制栏 (一键静音 + 音量滑块)
                AudioControlBar(player: player)

                // 5. 播放倍速选择器 (变速不变调)
                PlaybackRateSelector(player: player)

                Divider()
                    .background(Color.white.opacity(0.1))

                // 6. 拟物播放控制台 (播放、暂停、停止)
                PlaybackConsoleView(player: player)
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.1 视口头部组件 (单一职责：渲染加速状态与心跳呼吸灯)

//
// ==============================================================================
struct HeaderView: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        HStack {
            Label("GPU 硬件加速渲染视口", systemImage: "bolt.shield.fill")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.blue)

            Spacer()

            // 状态心跳灯
            if player.state == .playing {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green, radius: 4)
                    .opacity(0.8)
            } else if player.state == .paused {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: .orange, radius: 4)
                    .opacity(0.8)
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.2 渲染视口底座组件 (单一职责：声画直出与暂停状态物理遮罩)

//
// ==============================================================================
struct RenderViewportView: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .aspectRatio(16 / 9, contentMode: .fit)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            // 硬件加速渲染图层
            JJSwiftUIPlayerView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .cornerRadius(12)
                .clipped()

            // 暂停状态下的半透明遮罩与播放图标提示
            if player.state == .paused {
                ZStack {
                    Color.black.opacity(0.3)
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white.opacity(0.8))
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .cornerRadius(12)
                .transition(.opacity)
            }

            // 💥 加载缓冲状态下的精美毛玻璃 Loading 遮罩
            if player.isLoading {
                ZStack {
                    Color.black.opacity(0.45)

                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)

                        Text("网络数据缓冲中...")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .cornerRadius(12)
                .transition(.opacity)
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.3 播放进度 Seek 与缓冲条组件 (单一职责：物理 Seek 跳转与缓冲百分比展示)

//
// ==============================================================================
struct PlaybackSliderView: View {
    @ObservedObject var player: JJPlayer
    @Binding var isDraggingSlider: Bool
    @Binding var sliderValue: Double

    @State private var dotOpacity: Double = 1.0

    var body: some View {
        VStack(spacing: 6) {
            if player.isLive {
                // 直播自适应拟物组件
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .shadow(color: .red, radius: 4)
                            .opacity(dotOpacity)
                            .onAppear {
                                withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    dotOpacity = 0.3
                                }
                            }

                        Text("LIVE 直播中")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                    )

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.4))
                        Text("已播时长: \(player.currentTime.formattedDurationString)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(.vertical, 6)
            } else {
                HStack {
                    // 当前播放位置（若在拖拽中，展示拖拽值；否则展示真实的播放进度）
                    Text((isDraggingSlider ? sliderValue : player.currentTime).formattedDurationString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()

                    // 高精度网络流缓冲水位提示
                    Text(String(format: "已缓冲 %.1f%%", player.bufferProgress * 100.0))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.blue.opacity(0.8))

                    Spacer()

                    // 媒体总长度
                    Text(player.mediaDuration.formattedDurationString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }

                // 精美双层轨道进度 Slider
                ZStack(alignment: .leading) {
                    // 1. 底层：整体背景轨
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)

                    // 2. 中层：网络缓冲指示条
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.blue.opacity(0.35))
                            .frame(width: geometry.size.width * CGFloat(player.bufferProgress), height: 6)
                    }
                    .frame(height: 6)

                    // 3. 顶层：原生拖拽 Slider，双向绑定防抖设计，拖拽完成后触发 Seek 引擎
                    Slider(value: isDraggingSlider ? $sliderValue : Binding(
                        get: { player.currentTime },
                        set: { sliderValue = $0 }
                    ), in: 0 ... max(1.0, player.mediaDuration)) { editing in
                        isDraggingSlider = editing
                        if !editing {
                            player.seek(to: sliderValue)
                        }
                    }
                    .accentColor(.blue)
                }
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.4 音频控制栏组件 (单一职责：静音切换与物理音量拖动控制)

//
// ==============================================================================
struct AudioControlBar: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        HStack(spacing: 12) {
            // 一键静音开关
            Button(action: {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                    player.isMuted.toggle()
                }
            }) {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(player.isMuted ? .red : .blue)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(player.isMuted ? Color.red.opacity(0.3) : Color.blue.opacity(0.2), lineWidth: 1)
                    )
            }

            // 物理音量滑动轨
            HStack {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))

                Slider(value: $player.volume, in: 0.0 ... 1.0)
                    .accentColor(.blue)

                Image(systemName: "speaker.3.fill")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.white.opacity(0.04))
            .cornerRadius(19)
            .overlay(
                RoundedRectangle(cornerRadius: 19)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

// ==============================================================================
//

// MARK: - 7.5 倍速播放选择器 (单一职责：变速不变调物理倍速切换)

//
// ==============================================================================
struct PlaybackRateSelector: View {
    @ObservedObject var player: JJPlayer
    private let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.isLive ? "播放倍速 (直播锁定 1.0x)" : "播放倍速 (变速不变调高保真发声)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.5))

            if player.isLive {
                // 直播锁定展示
                HStack {
                    Text("1.00x (直播流保护性锁定)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(rates, id: \.self) { rate in
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                player.playbackRate = rate
                            }
                        }) {
                            Text(String(format: "%.2fx", rate))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(player.playbackRate == rate ? .white : .white.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    Group {
                                        if player.playbackRate == rate {
                                            LinearGradient(
                                                colors: [.blue, .purple],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        } else {
                                            Color.white.opacity(0.06)
                                        }
                                    }
                                )
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(player.playbackRate == rate ? Color.blue.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                    }
                }
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.6 播放控制台组件 (单一职责：播放/暂停/停止生命周期调度)

//
// ==============================================================================
struct PlaybackConsoleView: View {
    @ObservedObject var player: JJPlayer

    var body: some View {
        HStack(spacing: 24) {
            // 停止并重置
            ControlButton(icon: "stop.fill", label: "停止", color: .red) {
                withAnimation(.spring()) {
                    player.stop()
                }
            }

            // 播放/暂停双态按钮
            if player.state == .playing {
                ControlButton(icon: "pause.fill", label: "暂停", color: .orange) {
                    player.pause()
                }
            } else {
                ControlButton(icon: "play.fill", label: "播放", color: .green) {
                    player.play()
                }
            }
        }
    }
}

// ==============================================================================
//

// MARK: - 7.7 拟物控制按钮小组件 (单一职责：统一控制按钮的视觉与触觉反馈样式)

//
// ==============================================================================
struct ControlButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [color.opacity(0.8), color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(10)
            .shadow(color: color.opacity(0.3), radius: 6, x: 0, y: 3)
        }
    }
}
