//
//  JJAudioQueuePlayer.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import AudioToolbox
import Foundation

/// 基于 iOS 底层 AudioQueueRef 的高性能低延迟 PCM 音频播放引擎
///
/// 【学习笔记 - 为什么选择 AudioQueue 渲染原始 PCM？】
/// iOS 多媒体框架中，AVAudioPlayer 仅支持播放封装好的音频文件，而 CoreAudio / AUHAL (AudioUnit) 则极其晦涩复杂。
/// `AudioQueue` 作为承上启下的中间层低延迟通道，不仅能通过物理回调驱动播放任意手搓的 PCM 数据流，
/// 更是具有优秀的资源控制力、低延迟吞吐量，是开发自研 FFmpeg 播放器音频输出端的黄金首选。
public final class JJAudioQueuePlayer {
    // 物理声卡播放管道引用指针
    private var audioQueue: AudioQueueRef?

    // 3 个循环交替使用的音频缓冲区，实现滚动传送带投喂
    private var buffers: [AudioQueueBufferRef?] = [nil, nil, nil]

    // 每个缓冲区的物理容量大小（字节），设为 16KB，支持约 93 毫秒的双声道发声
    private let bufferSize: UInt32 = 16384

    // 是否正在物理发声
    private var isRunning: Bool = false

    /// 数据供给闭包，每次声卡消费完后，回调此闭包向 Swift 解码缓冲区索要最新的 PCM 字节数据
    public var pcmDataRequester: ((Int) -> Data)?

    /// 初始化并物理激活 iOS 音频播放通道
    public init() {
        setupAudioQueue()
    }

    deinit {
        // 析构红线：当播放器销毁时，必须物理释放底层 AudioQueue 拥有的所有声卡通道和内核资源，防止泄露！
        destroyAudioQueue()
    }

    /// 开启物理播放发声
    public func play() {
        guard let queue = audioQueue, !isRunning else { return }
        let status = AudioQueueStart(queue, nil)
        if status == noErr {
            isRunning = true
            DebugLog("🔊 [JJAudioQueuePlayer] AudioQueue 成功启动发声。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueStart 启动失败，状态码: \(status)")
        }
    }

    /// 暂停播放
    public func pause() {
        guard let queue = audioQueue, isRunning else { return }
        let status = AudioQueuePause(queue)
        if status == noErr {
            isRunning = false
            DebugLog("⏸ [JJAudioQueuePlayer] AudioQueue 暂停成功。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueuePause 暂停失败，状态码: \(status)")
        }
    }

    /// 停止物理播放并清空声卡管道
    public func stop() {
        guard let queue = audioQueue else { return }
        // 第二个参数 true 代表立即清空排队数据物理截断（防止残留尾音），false 代表等队列自然播完再停
        let status = AudioQueueStop(queue, true)
        if status == noErr {
            isRunning = false
            DebugLog("⏹ [JJAudioQueuePlayer] AudioQueue 物理截断停止。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueStop 停止失败，状态码: \(status)")
        }
    }

    /// 重置音频引擎预热状态
    public func reset() {
        stop()

        // 重新投喂静音数据预热 3 个缓冲传送带，确保启动瞬间的连续供料
        for buffer in buffers {
            if let buf = buffer {
                memset(buf.pointee.mAudioData, 0, Int(bufferSize))
                buf.pointee.mAudioDataByteSize = bufferSize
                if let queue = audioQueue {
                    AudioQueueEnqueueBuffer(queue, buf, 0, nil)
                }
            }
        }
    }

    // --------------------------------------------------

    // MARK: - 私有物理底座搭建

    // --------------------------------------------------

    private func setupAudioQueue() {
        // 1. 精准描述物理 PCM 音频的硬件流格式（44100Hz, 16bit, 立体声交错型）
        var format = AudioStreamBasicDescription()
        format.mSampleRate = 44100.0 // 采样率：44.1kHz（CD 级黄金标准）
        format.mFormatID = kAudioFormatLinearPCM // 线性脉冲编码调制（无损裸数据）

        // 格式标志：SInt16（有符号整数）且物理打包交错，iOS 声卡的最爱
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = 16 // 每一个采样点的位深位宽：16-bit
        format.mChannelsPerFrame = 2 // 双声道（左右声道立体声）
        format.mFramesPerPacket = 1 // 每个数据包只有一帧（PCM 经典标准）
        format.mBytesPerFrame = 4 // 每一帧物理字节数：2声道 * 2字节(16bit) = 4 字节
        format.mBytesPerPacket = 4

        // 2. 物理还原 Swift 实例非托管指针（Opaque Pointer）
        // 核心技术：在 C 语言回调 MyAudioQueueCallback 中，无法直接携带 Swift 闭包的 self 上下文。
        // 我们通过 passUnretained(self) 生成一个不受自动引用计数干预的 C 样式非托管指针传入 userData，
        // 声卡回调触发时，可以通过它 100% 0ms 安全恢复对当前类实例的引用！
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // 3. 握手 iOS 原生音频引擎，分配 AudioQueueRef
        let status = AudioQueueNewOutput(
            &format,
            audioQueueOutputCallback, // 注册高精 C 回调函数指针
            selfPointer, // 传入实例指针作为用户参数
            nil, // 使用默认的回调运行循环线程（通常为系统的实时 CoreAudio 高优先线程）
            nil, // 使用默认的运行模式
            0, // 保留字，设为 0
            &audioQueue
        )

        guard status == noErr, let queue = audioQueue else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueNewOutput 创建声卡失败，错误码: \(status)")
            return
        }

        // 4. 预分配 3 个音频缓冲传送带（Buffers）并强制零填充（静音）进行预热
        for i in 0 ..< 3 {
            var buf: AudioQueueBufferRef?
            let allocStatus = AudioQueueAllocateBuffer(queue, bufferSize, &buf)
            if allocStatus == noErr, let b = buf {
                buffers[i] = b

                // 预填静音，保障初次播放的声卡稳定性，杜绝毛刺底噪
                memset(b.pointee.mAudioData, 0, Int(bufferSize))
                b.pointee.mAudioDataByteSize = bufferSize

                // 送入声卡物理排队队列
                AudioQueueEnqueueBuffer(queue, b, 0, nil)
            } else {
                DebugLog("❌ [JJAudioQueuePlayer] AudioQueue 缓冲 \(i) 分配失败，状态: \(allocStatus)")
            }
        }

        DebugLog("🎵 [JJAudioQueuePlayer] AudioQueue 物理引擎配置成功，3个滚动 Buffer 分配就绪！")
    }

    private func destroyAudioQueue() {
        guard let queue = audioQueue else { return }
        stop()

        // 物理销毁播放引擎（第二个参数 true 代表立即强行销毁，回收声卡通道）
        let status = AudioQueueDispose(queue, true)
        if status == noErr {
            audioQueue = nil
            buffers = [nil, nil, nil]
            DebugLog("🗑️ [JJAudioQueuePlayer] AudioQueue 成功物理归零销毁。")
        } else {
            DebugLog("❌ [JJAudioQueuePlayer] AudioQueueDispose 销毁失败，状态码: \(status)")
        }
    }

    /// 底层声卡回调投喂核心实现
    fileprivate func handleBufferCallback(_ aq: AudioQueueRef, _ buffer: AudioQueueBufferRef) {
        guard isRunning else { return }

        // 1. 计算当前 Buffer 最大能吞下的 PCM 字节深度
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)

        // 2. 0ms 极速从 Swift 生产者缓冲中“提货”
        var pcmData = Data()
        if let requester = pcmDataRequester {
            pcmData = requester(capacity)
        }

        // 3. 填料决策
        if !pcmData.isEmpty {
            // 成功提到货，执行物理内存拷贝灌入 Buffer
            pcmData.withUnsafeBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    memcpy(buffer.pointee.mAudioData, baseAddress, pcmData.count)
                }
            }
            // 更新当前缓冲区实际填入的 PCM 字节长度
            buffer.pointee.mAudioDataByteSize = UInt32(pcmData.count)
        } else {
            // 提货空虚（缓冲区饿死，多见于网络流卡顿）：填充全零静音，杜绝声卡Underflow物理喀哒爆音！
            memset(buffer.pointee.mAudioData, 0, capacity)
            buffer.pointee.mAudioDataByteSize = UInt32(capacity)
        }

        // 4. 将重新装载完毕的 Buffer 再次投递（Enqueue）进声卡流水线中，滚动播放
        AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
    }
}

// --------------------------------------------------

// MARK: - C 语言格式高精度声卡回调函数（@convention(c)）

// --------------------------------------------------

/// 【学习笔记 - Swift 中使用 @convention(c) 编写 C 兼容函数指针】
/// 像 CoreAudio 这样极度底层的 C 多媒体库，其回调函数签名需要直接传递 C 语言标准格式的函数指针。
/// Swift 在语言级别提供了 `@convention(c)` 修饰符，告诉 Swift 编译器：
/// “把这个闭包物理编译为不携带任何 Swift 运行时元数据的纯 C 样式 ABI 函数”。
/// 自此，我们能无缝与 Apple 核心音频框架握手，实现毫秒级的实时反馈。
private let audioQueueOutputCallback: AudioQueueOutputCallback = { inUserData, inAQ, inBuffer in
    guard let inUserData else { return }

    // 核心技术：在 C 世界中，从 void * 指针（inUserData）物理恢复 Swift 的 JJAudioQueuePlayer 强对象引用
    let player = Unmanaged<JJAudioQueuePlayer>.fromOpaque(inUserData).takeUnretainedValue()

    // 切回对象实例处理复杂的 Buffer 灌入与重新投料逻辑
    player.handleBufferCallback(inAQ, inBuffer)
}
