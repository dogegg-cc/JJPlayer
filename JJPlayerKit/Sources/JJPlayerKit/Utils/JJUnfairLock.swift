//
//  JJUnfairLock.swift
//  JJPlayerKit
//
//  Created by Antigravity on 2026-05-21.
//

import Foundation
import os

/// Darwin 原生高性能互斥锁封装，杜绝优先级反转，保证极致性能
///
/// 【设计细节 - iOS 底层多媒体开发最佳实践】
/// `os_unfair_lock` 是 iOS 10+ 引入的轻量级互斥锁，大小仅为 4 字节。
/// 它旨在取代已被废弃的 `OSSpinLock`，并且与底层的 `pthread_mutex` 相比，具有极低的运行时和上下文开销。
/// 关键是：**内核原生支持优先级继承 (Priority Inheritance)**。当拥有高 QoS 优先级的实时声卡线程（AudioQueue 回调）
/// 等待该锁时，iOS 内核会自动将持有锁的低优先级后台解码线程（生产者）的优先级临时提升，完美避免了“优先级反转”引发的声卡断流和爆音。
public final class JJUnfairLock {
    private var unfairLock = os_unfair_lock()

    public init() {}

    /// 尝试加锁。若锁已被其他线程持有，当前线程将被高效挂起，等待内核唤醒。
    @inline(__always)
    public func lock() {
        os_unfair_lock_lock(&unfairLock)
    }

    /// 释放锁并唤醒等待该锁的线程。
    @inline(__always)
    public func unlock() {
        os_unfair_lock_unlock(&unfairLock)
    }

    /// 使用包围闭包的快捷加锁释放机制，支持返回值
    @inline(__always)
    public func around<T>(_ closure: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfairLock)
        defer { os_unfair_lock_unlock(&unfairLock) }
        return try closure()
    }
}
