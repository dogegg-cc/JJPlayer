//
//  JJSwiftUIPlayerView.swift
//  JJPlayerKit
//
//  Created by Antigravity on 2026/5/22.
//

import SwiftUI
import UIKit

/// 基于 iOS 底层 UIKit 经典 CALayer 高性能物理渲染的视频播放器视口
/// 遵循单一职责原则，在稳健的 UIKit 层完成核心图像绘制与手势交互，再物理桥接至 SwiftUI 视口
public struct JJSwiftUIPlayerView: UIViewRepresentable {
    @ObservedObject public var player: JJPlayer

    public init(player: JJPlayer) {
        self.player = player
    }

    /// 实例化 UIKit 层的核心播放视图，并注入物理手势交互控制
    public func makeUIView(context: Context) -> JJPlayerUIView {
        let view = JJPlayerUIView()
        view.backgroundColor = .clear
        view.player = player // 物理注入控制器实例以打通手势联动
        return view
    }

    /// 高频物理刷新：每当 player 里的 currentFrame (CGImage) 更新时，SwiftUI 会以高帧率派发此方法
    public func updateUIView(_ uiView: JJPlayerUIView, context: Context) {
        if let cgImage = player.currentFrame {
            uiView.update(with: cgImage)
        } else {
            uiView.clear()
        }
    }
}

// ==============================================================================
//

// MARK: - UIKit 高性能核心播放渲染底座 (CALayer contents 物理硬件直出与手势闭环)

//
// ==============================================================================
public final class JJPlayerUIView: UIView {
    // 物理弱引用播放器核心，安全避开强引用循环与内存泄漏
    public weak var player: JJPlayer?

    private var hudView: JJPlayerHUDView?
    private var activeGestureType: HUDType?

    private var initialVolume: Float = 1.0
    private var initialBrightness: CGFloat = 0.5
    private var initialSeekTime: Double = 0.0
    private var lastTargetSeekTime: Double = 0.0

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
        setupGestures()
    }

    /// 初始化图层渲染配置
    private func setupLayer() {
        layer.contentsGravity = .resizeAspect
        layer.minificationFilter = .linear
        layer.magnificationFilter = .linear
        layer.masksToBounds = true
    }

    /// 初始化物理级手势识别
    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    /// 主线程高频刷新：将 VideoToolbox GPU 零拷贝直出的 CGImage 直接赋值给 layer.contents
    public func update(with cgImage: CGImage) {
        if Thread.isMainThread {
            layer.contents = cgImage
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.layer.contents = cgImage
            }
        }
    }

    /// 清空画面
    public func clear() {
        if Thread.isMainThread {
            layer.contents = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.layer.contents = nil
            }
        }
    }

    // ==============================================================================
    //

    // MARK: - 物理级手势动作处理 (手势分流与 HUD 高频状态刷新)

    //
    // ==============================================================================
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let player else { return }

        switch gesture.state {
        case .began:
            beginPanGesture(gesture, player: player)
        case .changed:
            changePanGesture(gesture, player: player)
        case .ended, .cancelled:
            endPanGesture(gesture, player: player)
        default:
            break
        }
    }

    private func beginPanGesture(_ gesture: UIPanGestureRecognizer, player: JJPlayer) {
        let location = gesture.location(in: self)
        let velocity = gesture.velocity(in: self)

        // 1. 根据滑动向量速度判断是水平快进退还是垂直滑控
        if abs(velocity.x) > abs(velocity.y) {
            activeGestureType = .seek
            initialSeekTime = player.currentTime
            lastTargetSeekTime = initialSeekTime
        } else {
            // 2. 垂直控制看触摸点位置分流 (左半屏亮度，右半屏音量)
            if location.x < bounds.width / 2 {
                activeGestureType = .brightness
                initialBrightness = UIScreen.main.brightness
            } else {
                activeGestureType = .volume
                initialVolume = player.volume
            }
        }

        // 3. 动态展示精美毛玻璃 HUD 反馈
        showHUD(type: activeGestureType ?? .volume)
    }

    private func changePanGesture(_ gesture: UIPanGestureRecognizer, player: JJPlayer) {
        guard let type = activeGestureType else { return }
        let translation = gesture.translation(in: self)

        switch type {
        case .brightness:
            let delta = translation.y / bounds.height
            let targetBrightness = max(0.0, min(1.0, initialBrightness - delta))
            UIScreen.main.brightness = targetBrightness
            hudView?.show(type: .brightness, value: Float(targetBrightness))

        case .volume:
            let delta = Float(translation.y / bounds.height)
            let targetVolume = max(0.0, min(1.0, initialVolume - delta))
            player.volume = targetVolume
            hudView?.show(type: .volume, value: targetVolume)

        case .seek:
            // 满屏滑动物理快进退 60 秒
            let delta = Double(translation.x / bounds.width) * 60.0
            let duration = player.mediaDuration
            let targetTime = max(0.0, min(duration, initialSeekTime + delta))
            lastTargetSeekTime = targetTime

            let seekText = "\(targetTime.formattedDurationString) / \(duration.formattedDurationString)"
            hudView?.show(type: .seek, value: 0.0, seekText: seekText)
        }
    }

    private func endPanGesture(_ gesture: UIPanGestureRecognizer, player: JJPlayer) {
        // 如果是 Seek 手势，只在手势结束时一次性提交，防止高频 Seek 解码死锁
        if activeGestureType == .seek {
            player.seek(to: lastTargetSeekTime)
        }

        activeGestureType = nil
        hideHUD()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let player else { return }
        if player.state == .playing {
            player.pause()
        } else if player.state == .paused || player.state == .ready {
            player.play()
        }
    }

    // ==============================================================================
    //

    // MARK: - 拟物 HUD 视觉效果控制 (Wow 级物理淡入与阻尼收缩动画)

    //
    // ==============================================================================
    private func showHUD(type: HUDType) {
        hudView?.removeFromSuperview()

        let hud = JJPlayerHUDView()
        hud.frame = CGRect(x: (bounds.width - 130) / 2, y: (bounds.height - 130) / 2, width: 130, height: 130)
        hud.alpha = 0.0
        hud.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

        addSubview(hud)
        hudView = hud

        if type == .brightness {
            hud.show(type: .brightness, value: Float(UIScreen.main.brightness))
        } else if type == .volume {
            hud.show(type: .volume, value: player?.volume ?? 1.0)
        }

        UIView.animate(withDuration: 0.2, delay: 0.0, options: .curveEaseOut) {
            hud.alpha = 1.0
            hud.transform = .identity
        }
    }

    private func hideHUD() {
        guard let hud = hudView else { return }
        UIView.animate(withDuration: 0.2, delay: 0.3, options: .curveEaseIn, animations: {
            hud.alpha = 0.0
            hud.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        }, completion: { [weak self] _ in
            hud.removeFromSuperview()
            if self?.hudView === hud {
                self?.hudView = nil
            }
        })
    }
}

// ==============================================================================
//

// MARK: - 拟物毛玻璃 HUD 组件 (单一职责：绘制音量/亮度/Seek 水位指示与图标)

//
// ==============================================================================
private final class JJPlayerHUDView: UIVisualEffectView {
    private let iconView = UIImageView()
    private let textLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    init() {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        layer.cornerRadius = 16
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit

        textLabel.textColor = .white
        textLabel.font = .systemFont(ofSize: 11, weight: .bold)
        textLabel.textAlignment = .center

        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.2)

        contentView.addSubview(iconView)
        contentView.addSubview(textLabel)
        contentView.addSubview(progressView)

        layoutComponents()
    }

    private func layoutComponents() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            textLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            textLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),

            progressView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            progressView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            progressView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 10),
            progressView.heightAnchor.constraint(equalToConstant: 3)
        ])
    }

    func show(type: HUDType, value: Float, seekText: String? = nil) {
        progressView.isHidden = seekText != nil
        textLabel.text = seekText ?? String(format: "%.0f%%", value * 100)

        switch type {
        case .volume:
            iconView.image = UIImage(systemName: value <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        case .brightness:
            iconView.image = UIImage(systemName: "sun.max.fill")
        case .seek:
            iconView.image = UIImage(systemName: "clock.fill")
        }
    }
}

enum HUDType {
    case volume
    case brightness
    case seek
}

// ==============================================================================
//

// MARK: - Fileprivate 时间格式化工具 (单一职责：将秒数转换为标准 mm:ss / hh:mm:ss 字符串)

//
// ==============================================================================
private extension Double {
    var formattedDurationString: String {
        guard self > 0, !isNaN, !isInfinite else { return "00:00" }
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
