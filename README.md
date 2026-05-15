第一次用AI编程的实践，之前一直用mos和alttab两个软件，想实践一下ai编程的流程，就想着把这两个软件功能合并成一个，很多功能是简化版，但已经够用啦。需要注意的一点是，alttab功能默认用的我自己的键位，并没有设置更改快捷键，但我认为用control来实现是最好的方案了，所以如果使用的话需要**在系统设置里把command和control互换。**

不做不知道，做起来才发现各种bug需要调整，体验需要优化。真不容易啊！

**以下是ai写的介绍**

SwitchScroll
SwitchScroll 是一款小巧的 macOS 菜单栏实用工具，专为个人窗口和滚动工作流而设计。

功能特性
鼠标滚轮反向滚动

简单的平滑滚动

Control+Tab 窗口切换器

切换器覆盖层中的窗口缩略图

轻量级的最近窗口排序

原生 AppKit 菜单栏应用程序

下载
从 GitHub Releases 页面下载最新的 DMG 文件。

打开 DMG，然后将 SwitchScroll.app 拖入 Applications（应用程序）文件夹中。

出于隐私考虑，公开提供的 DMG 使用的是 ad-hoc 签名，因此它不会暴露个人的 Apple 开发者证书。由于它没有经过开发者 ID (Developer ID) 签名或公证，macOS 可能会在您首次打开它时显示 Gatekeeper 警告。如果您信任该来源，请在“访达 (Finder)”中按住 Control 键点按或右键点按将其打开，然后选择“打开”。

权限
SwitchScroll 需要以下 macOS 权限：

辅助功能 (Accessibility)：处理滚动和激活窗口所必需

屏幕录制 (Screen Recording)：用于获取窗口缩略图（可选）

如果缩略图不可用，窗口切换器在没有它们的情况下仍然可以正常工作。

隐私
SwitchScroll 仅在本地运行：

无网络连接

无数据分析

无自动更新

无遥测数据

不上传窗口标题、屏幕截图、滚动事件或应用使用情况

屏幕录制权限仅用于捕获本地窗口缩略图，以供切换器覆盖层使用。

构建
在 Xcode 中打开 SwitchScroll.xcodeproj，并在需要时选择您自己的签名团队。

命令行构建：

Bash
xcodebuild -project SwitchScroll.xcodeproj -scheme SwitchScroll -configuration Debug build
注意事项
本项目不打算在 App Store 发行。如果您要广泛地重新分发 Release 构建版本，可能需要在您自己的机器上重新进行签名或公证。
