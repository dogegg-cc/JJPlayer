# JJPlayer Project Swift Guidelines (.rule/swift.md)

本文件是 `JJPlayer` 与 `JJPlayerKit` 项目唯一的 **Swift 编码规范与开发指引 (Single Source of Truth)**。无论是开发团队成员，还是 AI 编码助手，在为此项目编写、修改或重构 Swift 代码时，必须严格遵守以下规则。

---

## 🛠 1. 强安全与解包规范 (Null-Safety)
- **严禁强制解包**：绝对禁止使用 `!` 对可选类型进行强制解包，也严禁使用 `try!` 和 `as!`。必须使用 `guard let`、`if let` 或空合运算符 `??` 提供安全回退。
- **现代 Swift 5.7+ 解包简写**：推荐使用编译器内置的简写语法，省去冗余的命名重复：
  ```swift
  // 推荐 👍
  guard let self else { return }
  if let videoCodec { ... }
  
  // 避免 ❌
  guard let self = self else { return }
  ```

---

## 💾 2. 内存管理与闭包捕获列表 (Memory Safety & ARC)
- **内存泄漏防护**：由于 `ffmpegkit` 中的异步执行回调（例如 `executeAsync`）会持有闭包作用域，闭包内部如果引用了 `self`（播放器实例），**必须显式在捕获列表中使用 `[weak self]`**。
- **UI 绑定更新**：在 `weak self` 解包后，如果涉及更新 `@Published` 属性，必须回到主线程更新。
  ```swift
  // 推荐 👍
  FFmpegKit.executeAsync(command) { [weak self] session in
      guard let self else { return }
      // 执行耗时解析...
      DispatchQueue.main.async {
          self.state = .ready // 主线程安全更新 UI
      }
  }
  ```

---

## ⏳ 3. 现代并发与线程隔离 (Swift Concurrency)
- **主线程安全机制**：任何直接参与 UI 渲染、进度更新、状态切换的类（例如 `JJPlayer`）或属性，都必须标记 `@MainActor`，以利用 Swift 6 编译器静态检测来杜绝多线程安全隐患。
- **结构化并发**：优先使用 `async/await` 代替深层嵌套的 completion 闭包，让流控制逻辑扁平化：
  ```swift
  // 推荐 👍
  func preparePlayer() async throws {
      let metadata = try await fetchMetadata()
      await MainActor.run {
          self.videoResolution = metadata.resolution
      }
  }
  ```

---

## 🎛 4. FFmpeg/C 语言指针交互规约 (C-Interop & Unsafe Swift)
- FFmpeg 的底层核心数据结构（如 `AVFrame`, `AVPacket` 等）是纯 C 语言指针。在 Swift 与其进行交互时，需遵守：
  - **块作用域防护**：严禁直接在生命周期外保留临时生成的 `UnsafePointer`，必须通过 Swift 推荐的 `withUnsafePointer(to:_:)` 等块作用域安全读取。
  - **内存自清理**：由于 C 内存不参与 ARC 自动引用计数，所有在 Swift 中分配的 C 资源必须配对有 `defer` 块，确保在方法作用域退出时 100% 释放：
    ```swift
    // 推荐 👍
    func processCBuffer() {
        let buffer = malloc(1024)
        defer { free(buffer) } // 绝不遗漏内存释放
        
        // 业务逻辑...
    }
    ```

---

## 🌐 5. 模块化与可见性设计 (API Visibility)
- 由于 `JJPlayerKit` 作为一个 SDK 库分发，必须严格遵循面向接口的封装原则：
  - **明确暴露 `public`**：外部 App 需要调用的状态枚举（如 `JJPlayerState`）、播放控制器（如 `JJPlayer`）、生命周期 API（如 `play()`, `pause()`）必须显式标记 `public`。
  - **强内聚 `private(set)`**：为了防止外部项目恶意篡改播放器的内部状态机，播放器的所有属性应设计为对外可读、内部可写：
    ```swift
    // 推荐 👍
    @Published public private(set) var state: JJPlayerState = .idle
    ```

---

## 📐 6. 统一代码排版风格 (Coding Style)
- **缩进**：统一采用 **4 空格缩进**，严禁使用 Tab 键。
- **计算属性简写**：当计算属性只有单行且为只读时，省略 `get {}` 关键字。
  ```swift
  // 推荐 👍
  public var isPlaying: Bool { state == .playing }
  ```
