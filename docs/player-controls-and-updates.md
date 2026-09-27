# 播放控制与更新

## 2.1.6+3：可选 YouTube 式手势

设置 > 播放器设置 > YouTube 式播放手势。未保存过该开关时默认关闭；保留用户之前保存的双击快退/快进开关值。切换后重新打开视频生效。

- 开启：左/右三分之一区域双击后退/快进 10 秒，中间双击不改变播放状态。单击显示中央上一集、播放/暂停、下一集按钮；按钮只响应单击，双击不会误暂停或切集。底部去掉重复的三个按钮。
- 关闭：恢复原来的双击播放/暂停和底部按钮。直播和桌面鼠标操作保持原有交互。
- 同一 APK 支持 ARM64 手机和 x86_64 AVD，文件名 `PiliPlus-2.1.6-arm64-v8a-x86_64-debug.apk`，包名与签名延续此前实验版。

### AVD 验证（2026-09-28）

在 Android 36.1 x86_64 的 bili-clean-api36 上安装实际 APK，通过离线缓存播放两段 120 秒本地测试视频。模拟器 MediaCodec 硬解发生 ANR 后，在模拟器设置内关闭硬解，软件解码下完成以下验证；未改动手机解码设置。

- 竖屏左右双击跳转通过：右侧 54.000 → 65.000 秒，左侧 65.000 → 55.333 秒（包含操作期间的自然播放时间）。
- 暂停时中间双击保持 55.333 秒与暂停状态；播放时中间双击保持播放。
- 单击显示中央三按钮，单击暂停生效；双击可见的播放按钮保持暂停。
- 单击下一集切换到 Test Part 2，上一集返回 Test Part 1。
- 横屏中央按钮布局正常；左右双击仍分别跳转约 ±10 秒。
- 关闭开关并重新进入视频后，双击左右侧仅恢复播放/暂停、不跳转，中央按钮消失。

测试证据保存在本机 `dist/avd-gesture-results.json`、`dist/avd-center-buttons.png`、`dist/avd-landscape.png`、`dist/avd-disabled-controls.png`。同一 APK 已通过 `adb install -r` 安装到连接的 PLQ110 手机，安装后核对版本为 2.1.6、versionCode 3，保留原数据。

构建沿用下方参数，将版本改为 `pili.name=2.1.6`、`pili.code=3`，目标平台改为 `android-arm64,android-x64`。

## 2.1.5+2

- 手机播放器左、中、右各占三分之一：左侧双击后退 10 秒，右侧双击快进 10 秒，中间双击暂停/播放。保留“播放设置 > 双击快退/快进”开关。提示出现后继续点按可累加 10 秒。
- 播放器菜单 > 定时关闭 > 播放到当前视频结束：无需设置分钟数，结束后执行选择的“暂停视频”或“退出APP”，优先于循环、连播和互动视频分支。选择“禁用”或新的倒计时可取消。
- 设置 > 自动检查更新默认开启；关于 > 当前版本可手动检查。读取公开仓库 LumiaBlack51/PiliPlus 的 `/releases/latest`，忽略草稿和预发布；网络失败不打扰自动检查，手动检查给出错误提示。
- 按数字版本比较，避免发布时间变化导致重复提醒或降级。Release 标签必须采用 `v2.1.5` 或 `v2.1.5+2` 格式。未来版本须同步提高 pubspec 和编译参数中的版本、Android versionCode。
- Android 更新按钮按设备 ABI 和 debug/release 包类型选择 APK，交给浏览器下载及系统安装器确认。当前包保留 `com.example.piliplus.debug` 和原 debug 签名，便于覆盖已有实验版。后续更新必须沿用同一包名和签名。
- 当前 ARM64 资产命名：`PiliPlus-2.1.5-arm64-v8a-debug.apk`。未来应保留 `arm64-v8a`、`-debug`、`.apk` 等标识；没有匹配安装包时打开 Release 页面。

构建保留 Chromium transport：

```powershell
$env:PUB_CACHE='E:\pili-pub'
& E:/software/flutter-3.47.4/bin/flutter.bat build apk --no-pub --debug --target-platform android-arm64 --dart-define=PILI_BROWSER_TRANSPORT=true --dart-define=PILI_NETWORK_DIAGNOSTICS=true --dart-define=pili.name=2.1.5 --dart-define=pili.code=2 --android-project-arg kotlin.incremental=false
```

验证：修改文件静态分析通过；23 个测试通过，覆盖播放跳转提示、结束关闭状态与取消、版本比较及现有网络传输。手机实际手势、视频结束和系统安装流程仍需实机验收。
