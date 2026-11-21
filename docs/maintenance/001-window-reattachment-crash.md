# 截图栏窗口重建闪退

日期：2026-11-21

## 现象与证据

用户反馈鼠标移到菜单栏图标时偶发闪退，也有未察觉应用已经退出的情况。本机 11 月 19 日两份、11 月 21 日一份系统崩溃报告均指向 `LineView.scrollBounds(width:)`，调用方为 `AppDelegate.keepOnActiveSpace()`。

## 根因与修复决策

重建截图栏窗口时，`LinePanel` 先挂载内容，再恢复窗口尺寸。内容宽度暂为零时，固定图片的绳结可能超过右边界，创建反向 `ClosedRange` 导致 SIGTRAP。

在范围创建处将下界限制为不超过上界，使可见区域在过窄时收缩至右边界。这样也覆盖窄窗口，正常尺寸下的布局不变，无需修改桌面恢复机制。

## 验证

- 用 9 张临时图片、其中 6 张固定，在原生窗口中重新挂载实际 `LineView`。
- 修复前：测试 SIGTRAP，提示 `Range requires lowerBound <= upperBound`。
- 修复后：完整 82 项原生测试通过，包括图片和固定状态保留、恢复窗口后的点击区域。
- 字符串检查：13 种语言、102 条，通过。
- 使用 macOS 26.5 SDK 和临时模块缓存；原生测试通过沙箱外窗口服务运行，仅使用临时图片、独立偏好和私有剪贴板。
- Apple Silicon / Intel 通用 release 应用构建通过，产物为 `build/Tendedero.app`，使用本地 ad hoc 签名；未安装到系统目录。
- 原始仓库 main `3c5b575` 上同样存在此问题；以该提交为基线移入修复后，完整 82 项原生测试、13 种语言 86 条字符串检查均通过。

## 提交与上游状态

- 本地修复提交：`b4a2dbf`，分支 `codex/fix-line-window-crash-local`。
- 上游 PR 用修复提交：`c6ddc90`，分支 `codex/fix-line-window-crash`，已推送至 `channingkuo/tendedero`。仅包含修复和回归测试两个文件，无 fork 其他功能。
- GitHub 连接器向 `alejandrobujan/tendedero` 创建 PR 时返回 403 `Resource not accessible by integration`；浏览器连接也连续超时。因此 PR 尚未创建。
- 比较页面：https://github.com/alejandrobujan/tendedero/compare/main...channingkuo:codex/fix-line-window-crash?expand=1

## 复盘与后续

窗口挂载期间的几何尺寸不是稳定的屏幕尺寸。依赖这些尺寸构造范围时必须处理空的可见区域；回归测试应覆盖重新挂载，而不仅是正常显示时的交互。

后续：恢复 GitHub 写入连接或浏览器连接后创建上游 PR；观察实际桌面切换和长期运行。
