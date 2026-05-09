# UX 打磨：深色模式对比度 + 列表动画设计

## Goal

两项独立的 UX 打磨：
1. 深色模式下 AI Chat 气泡边框对比度提升
2. NoteLanding 笔记列表删除/完成时 slide-out 动画反馈

---

## Part 1: 深色模式对比度微调

### 问题

AI 气泡边框使用 `colorScheme.primary.withValues(alpha: 0.15)`，深色模式下 primary 本身偏暗，0.15 alpha 几乎不可见，气泡看起来没有边界。

### 方案

将 AI 气泡和工具气泡的边框 alpha 从 `0.15` 提高到 `0.3`。

### 修改文件

**`lib/screen/AiChat.dart`**

两处修改：
1. `_buildMessageBubble` 中 AI 消息的 `BorderSide`：`colorScheme.primary.withValues(alpha: 0.15)` → `colorScheme.primary.withValues(alpha: 0.3)`
2. `_buildToolBubble` 中 `Border.all`：`colorScheme.outline.withValues(alpha: 0.15)` → `colorScheme.outline.withValues(alpha: 0.3)`

---

## Part 2: 笔记列表 slide-out 动画

### 问题

删除笔记或标记完成（hideDone 模式下）时，卡片直接消失，没有过渡动画，体验生硬。

### 方案

在删除/隐藏前对该卡片播放向左滑出 + 淡出动画（300ms），动画结束后再执行实际的删除和 UI 刷新。

### 架构

**修改文件：`lib/screen/NoteLanding.dart`**

**状态管理：**
- 新增 `final Set<int> _removingIds = {}` — 标记正在动画退出的笔记 ID
- 新增 `final Map<int, AnimationController> _removeAnimations = {}` — 每个退出动画的 controller

**动画参数：**
- Duration: 300ms
- Curve: Curves.easeIn
- 效果: SlideTransition `Offset(0, 0)` → `Offset(-1.0, 0.0)` + FadeTransition 1.0 → 0.0

**触发时机：**

1. **删除笔记**（`_confirmDelete` 确认后）：
   - 调用 `_animateRemoval(item.id!)` 
   - 动画结束回调中：`db.deleteNoteItem(item)` + `_updateUI(context)`

2. **标记完成（hideDone 模式下）**：
   - checkbox `onChanged` 中判断 `switcherProvider.isHiddenDone() && newValue == true`
   - 先调 `db.toggleNoteItem(item)`
   - 然后 `_animateRemoval(item.id!)` 
   - 动画结束回调中：`_updateUI(context)`

**方法设计：**

```dart
void _animateRemoval(int id, VoidCallback onComplete) {
  final controller = AnimationController(
    duration: const Duration(milliseconds: 300),
    vsync: this,  // 需要 TickerProviderStateMixin
  );
  _removeAnimations[id] = controller;
  setState(() => _removingIds.add(id));
  controller.forward().then((_) {
    _removingIds.remove(id);
    _removeAnimations.remove(id);
    controller.dispose();
    onComplete();
  });
}
```

**卡片包裹：**

在笔记卡片渲染处，检查 `_removingIds.contains(item.id)`：
- 如果正在退出：包裹 `SlideTransition` + `FadeTransition`
- 如果正常：不包裹（零开销）

```dart
Widget card = _buildNoteCard(item, ...);  // 现有卡片构建
if (_removingIds.contains(item.id)) {
  final controller = _removeAnimations[item.id!]!;
  final slideAnimation = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-1.0, 0.0),
  ).animate(CurvedAnimation(parent: controller, curve: Curves.easeIn));
  final fadeAnimation = Tween<double>(
    begin: 1.0,
    end: 0.0,
  ).animate(CurvedAnimation(parent: controller, curve: Curves.easeIn));
  card = SlideTransition(
    position: slideAnimation,
    child: FadeTransition(opacity: fadeAnimation, child: card),
  );
}
```

**生命周期：**
- `_AiChatState` 不需要改（Part 1 只改 alpha 值）
- `_NoteLandingState` 需要 mixin `TickerProviderStateMixin`（支持多个 AnimationController）
- `dispose()` 中清理所有 `_removeAnimations` 的 controller

---

## 边界与约束

- **Part 1**：仅改两个 alpha 数值，不改颜色源或布局
- **Part 2**：不改 `ReorderableListView` 结构，动画仅在 removal 时触发
- **Part 2**：拖拽排序不受影响（`_removingIds` 为空时完全无额外开销）
- **Part 2**：非 hideDone 模式下标记完成不触发动画（卡片仍留在列表中）
- **Part 2**：如果动画进行中用户再次操作同一项，忽略（`_removingIds` 已包含）

---

## i18n

无需新增 i18n key。

---

## 测试验证

### Part 1
1. 深色模式下 AI Chat → AI 气泡边框清晰可见
2. 深色模式下工具气泡边框清晰可见
3. 浅色模式下边框不过于突兀（0.3 仍然柔和）

### Part 2
1. 删除已完成笔记 → 确认后卡片向左滑出消失 → 列表刷新
2. hideDone 模式下勾选完成 → 卡片向左滑出 → 列表刷新
3. 非 hideDone 模式下勾选完成 → 无动画，卡片原地变灰（现有行为不变）
4. 拖拽排序仍正常工作
5. 快速连续删除多个笔记 → 各自独立动画，不冲突
