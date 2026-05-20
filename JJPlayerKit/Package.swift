// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JJPlayerKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        // 导出的播放器工具库产品
        .library(
            name: "JJPlayerKit",
            targets: ["JJPlayerKit"]
        )
    ],
    dependencies: [
        // 依赖本地的二进制 FFmpeg 封装库，解决 Xcode Explicit Module 在远程依赖下的缓存锁定问题，实现极其敏捷的本地联调
        .package(name: "ffmpeg-kit-spm", path: "../../ffmpeg-kit-spm")
    ],
    targets: [
        // 底层 Objective-C/C 桥接封装层，专门处理 FFmpeg 原始 C 指针和底层调用，避开 Swift 的模块编译缺陷
        .target(
            name: "JJFFmpegCore",
            dependencies: [
                .product(name: "FFmpegKit", package: "ffmpeg-kit-spm")
            ],
            path: "Sources/JJFFmpegCore"
        ),
        // 播放器核心工具库 Target，直接依赖极其易用的 Objective-C 桥接层
        .target(
            name: "JJPlayerKit",
            dependencies: [
                "JJFFmpegCore"
            ],
            path: "Sources/JJPlayerKit"
        )
    ]
)
