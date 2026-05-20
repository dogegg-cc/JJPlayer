// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JJPlayerKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // 导出的播放器工具库产品
        .library(
            name: "JJPlayerKit",
            targets: ["JJPlayerKit"]
        )
    ],
    dependencies: [
        // 依赖您上传至 GitHub 的二进制 FFmpeg 封装库
        .package(url: "https://github.com/dogegg-cc/ffmpeg-kit-spm.git", branch: "main")
    ],
    targets: [
        // 播放器核心工具库 Target
        .target(
            name: "JJPlayerKit",
            dependencies: [
                // 链接远程包导出的主库
                .product(name: "FFmpegKit", package: "ffmpeg-kit-spm")
            ],
            path: "Sources/JJPlayerKit"
        )
    ]
)
