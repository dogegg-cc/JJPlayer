//
//  JJPlayerState.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import Foundation

/// 播放器高聚合生命周期状态机
public enum JJPlayerState: Equatable {
    /// 初始闲置状态
    case idle

    /// 正在读取元数据并解析音视频流
    case preparing

    /// 媒体资源就绪，可以开始播放
    case ready

    /// 正在播放音视频
    case playing

    /// 已暂停播放
    case paused

    /// 播放已全部完成
    case completed

    /// 发生播放或转码错误，带上具体的错误描述
    case error(String)
}
