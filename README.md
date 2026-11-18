# GuoDuo

原生 SwiftUI 的第三方短剧客户端，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。开源免费，**非官方**。

SwiftUI 界面 + JavaScriptCore 运行上游 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama) 的取源核心（GPL-3.0）。

## 功能

- **推荐**：随机剧池竖滑，一屏一部只放第 1 集；按横竖屏 / 折叠姿态挑横屏片或竖屏片
- **发现 / 搜索**：红果 / 西饭 / 河马片源，题材筛选，粘贴分享链接直达
- **播放**：竖滑切集、拖进度预览、长按加速、倍速、画中画、弹幕、本集热评、极简模式、听书模式
- **折叠屏**：桌面半折下半屏操作台，书本半折右侧常驻选集，横屏右侧液态玻璃标签栏
- **我的**：观看记录、收藏、扫码登录同步云端记录、离线下载、储存空间管理
- **检查更新**：启动时自动检查 GitHub 新版本并显示更新内容；「我的 → 关于」可手动检查

每个版本的改动见 [docs/releases](docs/releases/) 或 [GitHub Releases](https://github.com/81199000/HongGuo/releases)。

## 下载安装

支持 iOS / iPadOS 26.0 及以上。GuoDuo 未上架 App Store，[Releases](https://github.com/81199000/HongGuo/releases) 里的安装包是**未签名 IPA**（文件名带 `unsigned.ipa`），需要用自己的签名工具（爱思助手、全能签、轻松签、Sideloadly、AltStore 等）签名后安装。覆盖安装新版时观看记录与收藏会保留。

## 目录结构

- `core/upstream/`：从上游 `src/native/` 原样拷贝的签名 / 设备注册 / 目录 / 搜索 / 取源模块（`public.js` 来自 `android/web/`，只改了 transport 路径）。上游版本见 `core/UPSTREAM_COMMIT`
- `core/shims/`：Node 内置模块在 JSC 里的替身（沿用上游安卓版 `android/web/` 的 Native 桥约定）
- `core/entry.js`：导出 `HG.browse / search / episodes / source` 给 Swift
- `HongGuo/Core/HGCore.swift`：JSContext 宿主 + Native.*（网络、AES、摘要、gzip、计时器）
- `HongGuo/Core/HGCencDecryptor.swift`：CENC AES-CTR MP4 解密，对照上游 `decryptMp4Buffer` 逐字节一致
- `HongGuo/Player`、`HongGuo/Storage`：播放器手势、弹幕、环境光、储存管理，改自 [DouDuo](https://github.com/81199000/DouDuo)（MIT）

## 构建

```sh
cd core && npm ci && node build.cjs && cd ..
xcodegen generate
xcodebuild -project HongGuo.xcodeproj -scheme HongGuo -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## 同步上游

```sh
U=/path/to/hongguo-drama
for f in app-source hongguo-app-catalog hongguo-app-search playback-device playback-signature playback-v5 sm3 request-signal download-quality; do cp $U/src/native/$f.js core/upstream/; done
cd core && npm install && node build.cjs
```

同步后更新 `core/UPSTREAM_COMMIT`。

## 发版（维护者）

1. 升 `project.yml` 的 `MARKETING_VERSION`
2. 写 `docs/releases/v<版本>.md`（App 内更新弹窗直接显示它的内容）
3. 提交并推送后运行 `./release.sh`：编译未签名 IPA，发布 GitHub Release

## 致谢与许可

- 取源核心：[jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama)（GPL-3.0）及其上游 woshishiq1/drpys、N3urda/hongguoTV、tsukiyo-zero/hongguoTV、charlie901208/HGTV 等贡献者，详见 [NOTICE](NOTICE) 与各文件头部
- 本项目以 [GPL-3.0](LICENSE) 协议开源；你可以自由使用、修改和再分发，但衍生作品同样须以 GPL-3.0 开源

## 免责声明

GuoDuo 是非官方客户端，与红果短剧 / 字节跳动、西饭、河马及任何内容方无关，不存储、不提供任何视频内容，片源均来自各平台公开接口。片源接口未公开，随时可能失效；不支持 ByteVC2 编码的集数。仅供个人学习研究使用，请勿用于商业用途，所有商标归各自权利人所有。
