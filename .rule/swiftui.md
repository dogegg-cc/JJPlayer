# JJPlayer Project SwiftUI Guidelines (.rule/swiftui.md)

本文件是 `JJPlayer` 项目唯一的 **SwiftUI 界面开发规范与组件化指引**。为实现极佳的渲染性能、优雅的单一职责组件拆分、以及 Premium 拟物玻璃化设计，所有涉及 SwiftUI 的开发、重构和审查工作必须严格遵循以下规则。

---

## 📐 1. 极致单一职责与组件拆分规范 (SOLID & Modularity)
* **主骨架极简化**：核心页面主入口视图（如 `ContentView`）的 `body` 必须保持极其纯净，代码行数通常应控制在 **30 行以内**，仅用于声明式地组合各大子卡片。
* **物理文件解耦**：
  * 禁止在一个 Swift 文件里无限制堆积多个 `struct` 视图。只要该组件具有独立的渲染边界、或行数超过 60 行，就**必须**将其拆分为独立的物理文件。
  * 物理文件应当组织在专门的 `Views/` 目录和 `Views/Common/` 通用小组件目录下。
* **结构体优先于计算属性**：
  * **推荐 👍**：提取独立的 `struct SubView: View`。结构体是 Swift 的值类型，有利于 SwiftUI 依赖追踪机制精细化比较组件的属性变化，仅在发生属性变更时局部刷新。
  * **避免 ❌**：在主视图中声明大量的 `func checkProgressView() -> some View` 或 `var detailsView: some View` 函数和计算属性。这会使渲染层膨胀，并在每次页面刷新时迫使编译器全量重绘整个视图树，带来灾难性的性能隐患。

---

## 🎛 2. 状态管理与数据单向流动 (Data Flow & State Control)
* **私有状态隔离**：组件内仅用于临时控制 UI 交互的状态（如 TextField 文本输入、弹窗显示、临时 Loading 动画等），必须使用 `private` 标记的 `@State`：
  ```swift
  // 推荐 👍
  @State private var isFieldFocused: Bool = false
  ```
* **精准属性传递**：
  * **避免 ❌**：将整个复杂的 `ObservableObject`（如 `@ObservedObject var player: JJPlayer`）无节制地深层传递给只读的底部叶子节点组件。
  * **推荐 👍**：若子组件仅仅需要展示某个状态（如总时长、音频编码），请只传递 `let` 静态常量；若需要双向绑定修改，传递 `@Binding var value`。这能阻断底层数据变更引起整棵渲染树不必要的 Diffing。

---

## 💎 3. 拟物化与毛玻璃样式抽象规范 (Premium Design & Glassmorphism)
* **禁止重复拷贝装饰器**：
  * 严禁在不同的卡片（如输入卡片、状态面板、学习笔记等）中反复书写相同的 `.background(.ultraThinMaterial)`、`.overlay(RoundedRectangle...)`、`.shadow(...)` 等复杂 UI 修饰器。
* **抽象公共样式容器**：
  * **推荐 👍**：抽象出通用的毛玻璃卡片容器 `struct GlassCard<Content: View>: View`，或编写自定义的 `ViewModifier`。
  ```swift
  // 推荐 👍
  struct GlassCard<Content: View>: View {
      let content: Content
      
      init(@ViewBuilder content: () -> Content) {
          self.content = content()
      }
      
      var body: some View {
          content
              .padding(20)
              .background(.ultraThinMaterial)
              .cornerRadius(20)
              .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
              .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
      }
  }
  ```

---

## ⚡ 4. 渲染性能与逻辑解耦规范 (Performance & Computation)
* **零计算 Body**：`body` 属性的作用应**仅局限于构建声明式视图树**。
  * **严禁 ❌**：在 `body` 闭包内放置任何格式化函数（如时间格式化 `formatDuration`）、数组排序筛选、或网络/IO 请求。
  * **推荐 👍**：所有复杂计算和格式化必须提取为专门的 Extensions（如 `Double` 扩展）、或在后台线程交由工具类/ViewModel 运算，View 仅读取计算完成后的 `String` 或基础值进行极速直出。
* **禁用强硬刷新**：禁止通过不断更改整个主视图的 `.id(UUID())` 来强行触发重绘，应完全依赖 SwiftUI 响应式属性的精准驱动。

---