# PiliPlus 海外网络播放优化交接

交接日期：2026-09-17。私有仓库：<https://github.com/LumiaBlack51/PiliPlus>。
基线为上游 `b0e7e4eb16d501bac0688738b0ba18d0fce87640`（2.1.4）；保留原项目历史和许可证。本次不合并上游后续更新。

## 接手时先做什么

1. 阅读本文，再看 [调查及实机结果](network-playback-investigation.md) 和 [脱敏结果数据](network-playback-results.json)。
2. 使用 Flutter **3.47.4 / Dart 3.13.3**，保留 `pubspec.lock`，应用上游 Flutter 和 material_ui 补丁。
3. 运行下文两个回归测试，再构建 Android ARM64 debug 包。
4. 在应用设置中把 CDN 选为 **自动优选（海外网络）**；这是可选模式，首次安装不会默认开启。

## 解决的问题与设计

实测部分海外网络下，高码率视频的长连接读取会明显降速，单纯增加播放器缓存或固定 CDN 未能稳定解决。新模式从当前清晰度返回的原始地址中探测候选节点，以有界 HTTP Range 下载隔离播放器读取节奏，并在失败时从相同字节偏移切换备用节点。

数据路径：播放接口返回地址 → `NetworkSource` → `CdnSelector` → `AdaptiveMediaSource`（127.0.0.1 临时服务）→ mpv。签名 URL 不改写、不写入持久存储；本地服务仅允许会话 token 对应的视频/音频轨道。

| 位置 | 职责与维护要点 |
| --- | --- |
| `lib/utils/cdn_selector.dart` | 最多 4 个不同 authority；每批最多 2 个 256 KiB 探测；每次探测 1.2 秒截止；成功缓存 120 秒、失败缓存 30 秒，最多 64 项 |
| `lib/utils/adaptive_media_source.dart` | 每次约 4 秒码流，范围 256 KiB–4 MiB；未知码率取 4 MiB；上游连接 3 秒、范围请求 6 秒截止；失败允许一次备用重试；切换冷却 30 秒 |
| `lib/pages/video/controller.dart` | 仅启用新模式时传递对应视频候选、音频候选和码率；手动地址保留所选主机 |
| `lib/plugin/pl_player/models/data_source.dart` | `NetworkSource` 增加候选地址与码率字段 |
| `lib/plugin/pl_player/controller.dart` | 创建和销毁会话、过期播放请求隔离；本地桥接超时 20 秒，直连仍 5 秒；可选诊断输出 |
| `lib/models/common/video/cdn_type.dart` | 枚举末尾追加新模式，避免改变旧设置的索引 |
| `lib/pages/setting/widgets/select_dialog.dart`、`lib/utils/video_utils.dart` | 新模式的设置说明与原始地址选择 |
| `test/utils/` | 11 个回归用例：范围校验、超时、取消、并发、缓存、切换、seek、低码率范围大小等 |

原有播放器缓存参数保持不变。不自动降低清晰度。直播、本地文件不启用此桥接。

## 环境与构建

本机已有打好补丁的 SDK：`E:\software\flutter-3.47.4`；依赖缓存：`E:\pili-pub`；Android SDK：`E:\software\androidsdk`。系统默认 `C:\src\flutter` 是 3.41.7，Dart 3.11.5，不能构建此项目。

在本机 PowerShell 的项目根目录运行：

```powershell
$env:FLUTTER_ROOT = 'E:\software\flutter-3.47.4'
$env:PUB_CACHE = 'E:\pili-pub'
$env:ANDROID_HOME = 'E:\software\androidsdk'
$env:Path = "$env:FLUTTER_ROOT\bin;$env:ANDROID_HOME\platform-tools;$env:Path"
flutter --version
flutter pub get
flutter test --no-pub test/utils/cdn_selector_test.dart test/utils/adaptive_media_source_test.dart
flutter build apk --debug --target-platform android-arm64 --android-project-arg kotlin.incremental=false --dart-define=PILI_NETWORK_DIAGNOSTICS=true
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

`kotlin.incremental=false` 用于 Windows 项目与依赖缓存跨盘的构建问题。debug 包 ID 为 `com.example.piliplus.debug`，与正式版共存。另一台机器须使用自己的 Android SDK、Java 17 和设备路径；不要复制账户、签名密钥或带签名的播放地址到 Git。

### 全新环境应用补丁

以 `.github/workflows/build.yml` 的 Android 流程和 `lib/scripts/patch.ps1` 为准。建议在独立 Linux 构建环境安装 PowerShell、Flutter 3.47.4、Java 17 和 Android SDK 后执行：

```powershell
# 在项目根目录，FLUTTER_ROOT 指向专用的干净 SDK；flutter 已在 PATH。
$env:GITHUB_WORKSPACE = (Get-Location).Path
& ./lib/scripts/patch.ps1 android
Set-Location $env:GITHUB_WORKSPACE
flutter test --no-pub test/utils/cdn_selector_test.dart test/utils/adaptive_media_source_test.dart
flutter build apk --debug --target-platform android-arm64 --dart-define=PILI_NETWORK_DIAGNOSTICS=true
```

上游补丁脚本会重置 Android 构建使用的 Flutter SDK、设置全局 Git 作者并重装/修改 UI 依赖；应仅在专用构建环境使用，已有补丁环境不要盲目重跑。脚本 Android 路径使用 `~/.pub-cache`，Windows 自定义缓存不能直接套用；本机已有配置可直接使用上面的本机命令。原上游 Actions 保留，未为私有仓库另配发布签名或验证云端构建。

## 验证记录与验收

本次交接重新执行：Flutter 3.47.4 下 11 个测试全部通过；改动 Dart 文件、测试及实验入口的 `dart analyze` 返回 `No issues found!`；3 个 Python 工具通过 `py_compile`，`git diff --check` 通过。本次没有重新构建 APK 或开展实机长时测试；既有实机数据见调查报告，不应当成跨网络性能保证。

既有 HDR 实验：180 秒观察中，自发缓冲从 94.328 秒降为 0；完整应用的另一条 1080P 视频仍出现一次 1.977 秒卡顿。启动和主动 seek 的等待单独统计。不能据此认定所有网络均无卡顿，也没有同画质官方应用 4K HDR 对照结论。

交接后的实机验收：分别播放 AVC/HEVC/AV1 1080P 和有权限的 HDR 视频，测试 seek、暂停恢复、切换视频、前后台切换；观察 `PILI_CDN` 的主机切换和 `PILI_NET` 的缓冲/丢帧指标，再切回普通 CDN 验证直连。网络变化、所有候选都慢、地址过期或不支持 Range 时仍可能失败。

既有本地产物：`dist/PiliPlus-overseas-debug.apk`，SHA-256：
`7a40b2d2f69c083183ec934c344e148f724432055312b302fc9b3033d529cb5c`。
`dist/` 不提交 Git；接手人可依上述步骤重新构建，debug 签名不同可能无法覆盖安装已有 debug 包。

## 诊断工具

工具使用 Python 标准库、ADB；网络探针另需手机 shell 可调用 curl。

```powershell
python tool/network_probe.py BV1fK4y1t7hj --rounds 2 --output network-measurements.json
python tool/network_capture.py playback.log
python tool/network_lab_summary.py playback.log
```

`network_capture.py` 只保留指定诊断标签，最多运行 10 分钟；`--launch` 会重启 debug 应用以收集启动事件。汇总脚本仅处理 `PILI_LAB` 实验日志，不能用它直接汇总普通应用的 `PILI_NET` 日志。

`tool/network_playback_lab.dart` 是独立实验入口，可通过构建参数 `--target tool/network_playback_lab.dart` 使用，会替代 debug 包的正常界面。实验输入 `files/lab-playurl.json` 的格式和使用方式见调查报告，包含短期签名地址，应仅临时放在设备上并在测试后清理。恢复正常应用时重新构建默认入口。

## 回退、后续工作与 Git 约定

- 功能回退：设置 CDN 为原来的选项（例如备用地址或手动提供商），重新打开视频即可使用原路径。
- 代码回退：用 `git log --oneline` 找到 `feat: add adaptive overseas playback and handover docs`，执行 `git revert <该提交哈希>`，运行测试/构建后推送。不要重置共享分支历史。
- 后续优先验证：多网络长期运行、网络切换时健康缓存失效、低速网络策略；若加入自动降画质，需另行明确用户体验和开关。
- 私有仓库使用 `origin`，公开上游使用 `upstream`；新开发建议使用 `codex/` 前缀分支。需要接手者访问时，由仓库所有者添加 collaborator。
- 只提交源码、脱敏数据与文档，保留原许可证。APK、临时日志、设备账户、签名密钥和私有实验输入不纳入 Git。
