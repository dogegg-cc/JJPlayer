//
//  Double+Format.swift
//  JJPlayerKit
//
//  Created by 我勒个去去 on 2026/5/21.
//

import Foundation

public extension Double {
    /// 将时间秒数格式化为 "mm:ss" 或 "hh:mm:ss"
    /// 遵循单一职责原则，将纯粹的数据转换逻辑从 SwiftUI 视图层中彻底剥离
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
