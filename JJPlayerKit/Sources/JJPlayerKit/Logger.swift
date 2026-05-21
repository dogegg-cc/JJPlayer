//
//  Logger.swift
//  JJPlayerKit
//
//  Created by 我勒个去去 on 2026/5/21.
//

import Foundation

/// 全局调试日志
/// - Parameters:
///   - message: 打印内容
///   - file: 调用文件 (默认自动获取)
///   - method: 调用方法 (默认自动获取)
///   - line: 调用行号 (默认自动获取)
nonisolated func DebugLog(_ message: some Any, file: String = #file, method: String = #function, line: Int = #line) {
    #if DEBUG
        let fileName = (file as NSString).lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        // 输出格式: [时间] [文件名:行号] 方法名: 内容
        print("[\(timestamp)] [\(fileName):\(line)] \(method): \(message)")
    #endif
}
