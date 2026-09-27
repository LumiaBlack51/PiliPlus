# 2.1.5+2 播放控制与更新

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
