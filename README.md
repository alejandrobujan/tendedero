# ImageLine · 图片晾绳

<img src="docs/imageline-icon.png" width="112" alt="ImageLine 原创图标">

ImageLine 是基于 [Tendedero](https://github.com/alejandrobujan/tendedero) 的本机修改版：让复制的图片文件与图片内容都能进入屏幕顶部的晾衣绳，沿用截图的操作能力。

## 当前版本

**1.0.5**，基于 Tendedero 1.5.0 / upstream `2c3ffd95f173585260aa198e85d3ea62a878f688`。支持 macOS 14 及以上；构建包包含 Apple 芯片与 Intel 两种架构。

- Finder 中对图片文件按 Cmd+C，读取真实图片，支持多图。
- 保存独立 PNG 副本，标注、移动或删除绳上图片不会修改外部原文件。
- 按图片像素内容去重，处理编码元数据差异与应用重启；取下后可再加入，内容变化后可加入新图。
- 保留截图、预览、标注、拖动、删除及原有快捷键操作。
- 挂载区右下角提供“清空全部”按钮，内部副本移入废纸篓、外部原图保留；清空后可继续挂载。
- 距屏幕右边缘 1/5 处的放大拉环支持下拉清空：出现“松手清空”后释放，绳子回弹、照片掉落；轻拉或往上收回可取消。1.0.3 已修复按钮无法点击的问题。
- 排除文本/文档预览、文件夹图标、非图片文件、私密/临时内容以及自身复制回环。

拉环待拉状态为细蓝边，达到阈值后蓝边明显加粗、填充加深，再松手清空。

复制图片功能在菜单中的“挂上复制的图片”控制。图片使用本机 ImageIO 解码；单个输入上限 64 MiB、8000 万像素，动画图片按第一帧处理。专有文档复制格式不保证支持。

## 构建和验证

```sh
swift test
swift scripts/check-strings.swift
SIGN_IDENTITY=- scripts/build-app.sh
bash scripts/package-imageline.sh
open build/ImageLine.app
```

`SIGN_IDENTITY=-` 构建本机临时签名版本，不使用原作者身份或图标。原作者的 DMG/发布脚本保留作上游参考；修改版打包使用 `scripts/package-imageline.sh`。

1.0.4 已通过 24 项测试，覆盖剪贴板、批量清空、原图保护、原生窗口命中、拖拽事件路由、取消手势和三种图片尺寸。隔离副本的按钮界面点击已成功清掉两张测试图；真实鼠标拖拽因后续界面工具连接超时尚未完成，窗口事件测试已通过。1.0.1 曾通过 13 项安装后处理验证，使用 Finder 等效剪贴板文件引用，原生 Finder UI Cmd+C 测试尚未完成。剪贴板检查脚本为 `scripts/verify-installed.swift`；它临时修改系统剪贴板，完成后恢复，在真实用户正在操作剪贴板时不宜重复运行。

## 关键源码

| 文件 | 用途 |
| --- | --- |
| `Sources/ClipboardSupport/ClipboardImageReader.swift` | 文件/数据输入识别、解码、方向修正和像素指纹 |
| `Sources/Tendedero/ClipboardWatcher.swift` | 监听、后台转换、去重重建、独立副本保存 |
| `Sources/Tendedero/Line.swift` | 原有图片操作、自身复制标记和冗余副本清理 |
| `Sources/Tendedero/AppDelegate.swift` | 截图/复制接入、菜单与登录项迁移 |
| `Sources/Tendedero/LineControls.swift` | 原生清空按钮、拉环绘制与拖拽事件 |
| `Sources/Tendedero/LinePanel.swift` | 透明悬浮窗口和原生控件命中 |
| `scripts/make-imageline-icon.swift` | 原创图标绘制 |
| `Tests/ClipboardSupportTests/` | 回归测试 |
| `Tests/LineTests/` | 批量清空和外部原图保护回归 |

实现记录见 [变更说明](docs/IMAGELINE-CHANGELOG.md)。完整交付包、原始需求和验证记录保存在仓库上级项目工作区的分类目录，见上级 README。

## 来源与许可

原项目由 Alejandro Buján 开发，源码按 [LICENSE](LICENSE) 的 MIT 条款使用并保留版权信息。Tendedero 的名称、图标和相关图像不包含在代码授权内；本修改版使用 ImageLine 名称、不同的菜单栏符号与原创应用图标，不暗示原作者背书。原始品牌脚本和 docs 内容仅作为上游源码材料保留，不用于修改版应用的品牌资产。
