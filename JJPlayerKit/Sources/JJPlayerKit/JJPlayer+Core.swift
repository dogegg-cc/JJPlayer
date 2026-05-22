//
//  JJPlayer+Core.swift
//  JJPlayerKit
//
//  Created by Antigravity.
//

import CoreVideo
import Foundation
import JJFFmpegCore
import VideoToolbox

extension JJPlayer {
    /// 异步载入媒体文件，利用手写的 C API 解复用核心 (JJDemuxer) 提取流级别元数据
    ///
    /// - Parameter path: 本地视频文件的绝对路径或网络流 URL
    public func loadMedia(path: String) {
        // 💥 先彻底清理旧的播放状态（停止 decode loop、关闭旧 demuxer、释放声卡）
        // 避免旧的网络连接和 I/O 重试阻塞干扰新视频加载
        stop()

        changeState(to: .preparing)
        DebugLog("🔄 正在载入媒体文件: \(path)")

        // 所有的 loadMedia、stop 逻辑全部放入串行队列按顺序行进，物理上隔离多线程并发冲突
        mediaLoaderQueue.async { [weak self] in
            guard let self else { return }
            do {
                // 1. 初始化 C 解复用核心 (JJDemuxer) 并打开媒体文件
                let demuxer = try prepareDemuxer(path: path)

                // 2. 配置视频与音频的双路闭包回调
                setupCallbacks(for: demuxer)

                // 3. 读出基本元数据以更新响应式 UI 状态并自动检测直播流
                let duration = demuxer.duration
                let isLiveStream = duration <= 0
                let finalDuration = isLiveStream ? 0.0 : duration
                let resolution = "\(demuxer.videoWidth)x\(demuxer.videoHeight)"
                let codec = demuxer.videoCodecName

                // 4. 实例化原生 AudioQueue 音频引擎
                let player = createAudioPlayerInstance()

                DispatchQueue.main.async {
                    self.updateMetadata(duration: finalDuration, resolution: resolution, codec: codec)
                    self.updateLiveStatus(isLiveStream)
                    self.setDemuxer(demuxer)
                    self.setupAudioEngine(player: player)
                    self.changeState(to: .ready)
                    DebugLog("✅ JJPlayer 双路解码器及 AudioQueue 音频引擎就绪成功！")
                }
            } catch {
                // 捕捉底层 C 抛上来的错误并切回主线程抛给 UI 界面渲染
                let errorMsg = error.localizedDescription
                DebugLog("❌ JJPlayer 解析失败：\(errorMsg)")
                DispatchQueue.main.async {
                    self.changeState(to: .error(errorMsg))
                }
            }
        }
    }

    /// 💥【SRP 拆分：初始化解复用器和解码器】
    private func prepareDemuxer(path: String) throws -> JJDemuxer {
        let filteredPath = filterAndGeneratePureM3u8(from: path)
        let demuxer = JJDemuxer()
        try demuxer.open(url: filteredPath)
        try demuxer.initializeDecoders()
        return demuxer
    }

    /// 💥 工业级降维打击优化：提取并重组 Master m3u8 以拦截多变体网络探测风暴
    // swiftlint:disable function_body_length cyclomatic_complexity
    private func filterAndGeneratePureM3u8(from urlString: String) -> String {
        guard urlString.lowercased().hasPrefix("http://") || urlString.lowercased().hasPrefix("https://") else {
            return urlString
        }
        guard urlString.lowercased().contains(".m3u8") else {
            return urlString
        }

        guard let url = URL(string: urlString) else { return urlString }
        let baseUrl = url.deletingLastPathComponent()

        // 1. 同步加载 Master m3u8 文本（10 秒超时，此函数已在后台串行队列执行，不阻塞 UI）
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        // swiftlint:disable:next line_length
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 JJPlayer/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var m3u8Content: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            if let data, let text = String(data: data, encoding: .utf8) {
                m3u8Content = text
            }
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10.0)

        guard let content = m3u8Content else {
            DebugLog("⚠️ [JJPlayer] Master m3u8 下载超时或失败，退回原链接")
            return urlString
        }

        // 2. 如果不包含变体流标志，说明已经是单 Variant m3u8，直接播放
        if !content.contains("#EXT-X-STREAM-INF") {
            return urlString
        }

        let lines = content.components(separatedBy: .newlines)

        // ──────────────────────────────────────────────
        // Pass 1: 扫描第一个 STREAM-INF，提取其 AUDIO group 引用
        // ──────────────────────────────────────────────
        var targetAudioGroup: String?
        var firstStreamInfLine: String?
        var firstStreamInfUrl: String?

        var idx = 0
        while idx < lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            idx += 1
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                firstStreamInfLine = line
                targetAudioGroup = extractAttribute("AUDIO", from: line)
                if idx < lines.count {
                    firstStreamInfUrl = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }

        guard let streamInfLine = firstStreamInfLine,
              let streamInfUrl = firstStreamInfUrl
        else {
            return urlString
        }

        // ──────────────────────────────────────────────
        // Pass 2: 精准重组——只保留匹配 GROUP-ID 的音频标签 + 第一个视频变体
        // ──────────────────────────────────────────────
        var newLines = [String]()
        newLines.append("#EXTM3U")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXT-X-VERSION") || trimmed.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") {
                newLines.append(trimmed)
            }
        }

        // 精准匹配音频媒体标签
        if let audioGroup = targetAudioGroup {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") {
                    let groupId = extractAttribute("GROUP-ID", from: trimmed)
                    if groupId == audioGroup {
                        let resolved = resolveMediaLineAbsoluteUrl(trimmed, baseUrl: baseUrl)
                        newLines.append(resolved)
                        break
                    }
                }
            }
        }

        // 精简 STREAM-INF：剥离 SUBTITLES 和 CLOSED-CAPTIONS 属性
        let cleanedStreamInf = stripAttributes(["SUBTITLES", "CLOSED-CAPTIONS"], from: streamInfLine)
        newLines.append(cleanedStreamInf)
        newLines.append(resolveAbsoluteUrl(streamInfUrl, baseUrl: baseUrl))

        // 3. 将精简重组后的内容写入沙盒临时文件
        let pureM3u8Text = newLines.joined(separator: "\n")
        let tempDirectory = NSTemporaryDirectory()
        let tempFilePath = (tempDirectory as NSString).appendingPathComponent("pure_variant.m3u8")

        do {
            try pureM3u8Text.write(toFile: tempFilePath, atomically: true, encoding: .utf8)
            DebugLog("🎯 [JJPlayer] Master m3u8 精简重组成功！重定向至：\(tempFilePath)")
            DebugLog("🎯 [JJPlayer] 提纯内容：\n\(pureM3u8Text)")
            return tempFilePath
        } catch {
            DebugLog("⚠️ [JJPlayer] 临时 m3u8 写入失败，退回原链接: \(error.localizedDescription)")
            return urlString
        }
    }

    // swiftlint:enable function_body_length cyclomatic_complexity

    /// 从 HLS 标签行中提取指定属性的值（如 AUDIO="a1" → "a1"）
    private func extractAttribute(_ name: String, from line: String) -> String? {
        let pattern = name + "=\""
        guard let range = line.range(of: pattern) else { return nil }
        let start = range.upperBound
        guard let endRange = line[start...].range(of: "\"") else { return nil }
        return String(line[start ..< endRange.lowerBound])
    }

    /// 从 STREAM-INF 行中剥离指定属性（如 SUBTITLES、CLOSED-CAPTIONS）
    private func stripAttributes(_ attrs: [String], from line: String) -> String {
        var result = line
        for attr in attrs {
            // 匹配 ,ATTR="value" 或 ATTR="value", 形式
            if let attrRange = result.range(of: attr + "=\"") {
                let searchStart = attrRange.lowerBound
                let afterEquals = attrRange.upperBound
                if let closeQuote = result[afterEquals...].range(of: "\"") {
                    var removeStart = searchStart
                    var removeEnd = closeQuote.upperBound
                    // 移除前导逗号
                    let beforeIdx = result.index(before: removeStart)
                    if result[beforeIdx] == "," {
                        removeStart = beforeIdx
                    } else if removeEnd < result.endIndex, result[removeEnd] == "," {
                        removeEnd = result.index(after: removeEnd)
                    }
                    result.removeSubrange(removeStart ..< removeEnd)
                }
            }
        }
        return result
    }

    /// 将变体流里的相对链接转换为绝对链接
    private func resolveAbsoluteUrl(_ path: String, baseUrl: URL) -> String {
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return path
        }
        if let resolvedUrl = URL(string: path, relativeTo: baseUrl) {
            return resolvedUrl.absoluteString
        }
        return path
    }

    /// 将 #EXT-X-MEDIA 标签行中的 URI 相对路径转换为绝对路径
    private func resolveMediaLineAbsoluteUrl(_ line: String, baseUrl: URL) -> String {
        guard let uriRange = line.range(of: "URI=\"") else { return line }
        let startIndex = uriRange.upperBound
        guard let endIndex = line[startIndex...].range(of: "\"")?.lowerBound else { return line }

        let relativeUri = String(line[startIndex ..< endIndex])
        let absoluteUri = resolveAbsoluteUrl(relativeUri, baseUrl: baseUrl)

        var newLine = line
        newLine.replaceSubrange(startIndex ..< endIndex, with: absoluteUri)
        return newLine
    }

    /// 💥【SRP 拆分：配置视频与音频的双路闭包回调】
    private func setupCallbacks(for demuxer: JJDemuxer) {
        // 视频通道回调：预先在后台转换为 CGImage 并快速推入锁保护队列
        demuxer.setVideoCallback { [weak self] pixelBuffer, pts in
            guard let self else { return }
            handleVideoPixelBuffer(pixelBuffer, pts: pts)
        }

        // 音频通道回调：直接将解出的 PCM 字节追加至全局 audioBuffer
        demuxer.setAudioCallback { [weak self] pcmData, pts in
            guard let self else { return }
            handleAudioPCMData(pcmData, pts: pts)
        }
    }

    /// 💥【SRP 拆分：处理视频像素帧】
    private func handleVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: Double) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if status == noErr, let image = cgImage {
            videoQueueLock.lock()
            videoFrameQueue.append(VideoFrame(cgImage: image, pts: pts))
            videoQueueLock.unlock()
        }
    }

    /// 💥【SRP 拆分：处理音频 PCM 数据】
    private func handleAudioPCMData(_ pcmData: Data, pts: Double) {
        audioPtsLock.lock()
        if firstAudioPTS < 0 {
            // 记录该视频源音频首帧被解复用出来的绝对 PTS，作为物理对齐基准
            firstAudioPTS = pts
        }
        audioPtsLock.unlock()

        appendAudioData(pcmData)
    }

    /// 💥【SRP 拆分：创建 AudioQueue 实例并绑定回调】
    private func createAudioPlayerInstance() -> JJAudioQueuePlayer {
        let player = JJAudioQueuePlayer()
        player.pcmDataRequester = { [weak self] capacity in
            guard let self else { return Data() }
            return consumeAudioData(length: capacity)
        }
        return player
    }
}
