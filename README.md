<p align="center">
  <img src="docs/brand/app-icon.png" width="128" alt="GuoDuo icon">
</p>

<h1 align="center">GuoDuo</h1>

<p align="center">原生 SwiftUI 的红果短剧客户端，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。开源免费，非官方。</p>

红果短剧官方 App 在折叠屏内屏、iPad 上不适配，所以有了它。界面和播放全部原生（SwiftUI + AVPlayer），取源核心用 JavaScriptCore 运行上游 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama)（GPL-3.0）。播放器手势、弹幕、折叠屏布局沿用姊妹项目 [DouDuo](https://github.com/81199000/DouDuo)。

## 功能

**推荐**
- 打开 App 后台先备好几部，点进推荐直接放本地文件；竖滑一屏一部，每部只放第 1 集
- 看过的会记住，下次不再推荐同一集；第 1 集都看完了改从第 2 集推荐
- 喜欢就点「全集」进这部剧的详情页

**发现 / 搜索**
- 红果 / 西饭 / 河马片源，热播榜、真人剧、漫剧、AI 剧分类，题材筛选
- 粘贴红果分享链接直达

**播放**
- 竖滑切集、横滑快进快退（带预览）、长按加速、倍速、画中画
- 弹幕、本集热评（前 5 集）、极简模式、听书模式（退出后继续出声，默认关）

**折叠屏 / iPad**
- 桌面半折：上视频、下半屏操作台（滑动快进 / 上下切换、弹幕、环境光投影）
- 书本半折：左视频、右侧常驻选集
- 横屏：右侧液态玻璃标签栏，评论从右侧滑出

**我的**
- 继续观看、收藏：外面一排，点「全部」看完整列表
- 扫码登录红果账号同步云端观看记录、离线下载、储存空间管理
- 检查更新：启动时自动检查 GitHub 新版本并显示更新内容

每个版本的改动见 [更新说明](docs/releases/) 或 [GitHub Releases](https://github.com/81199000/GuoDuo/releases)。

## 下载安装

支持 iOS / iPadOS **18.4 及以上**。GuoDuo 未上架 App Store，用 **[一键签](https://github.com/81199000/OneDuo)** 安装：免费，用自己的 Apple ID，到期自动续签。

1. 下载 [一键签](https://github.com/81199000/OneDuo/releases/latest)（Windows / Mac）
2. 数据线连手机，在一键签里选 **GuoDuo**，点 **一键安装**
3. 手机上 **设置 → 通用 → VPN 与设备管理** 信任你的 Apple ID

详细步骤见 [一键签使用教程](https://github.com/81199000/OneDuo#使用教程)。

> 更新也在一键签里完成：有新版会自动装上，观看记录和收藏会保留。

## 常见问题

- **打开就闪退**：签名过期了，打开一键签点「立即全部续签」
- **某部剧放不了**：部分集数只有 ByteVC2 编码，iOS 不支持；或在红果需要解锁
- **推荐 / 取源全部失败**：红果接口变了，等上游修复后更新 GuoDuo
- **占用空间大**：「我的 → 储存空间 → 清理缓存」，离线下载的视频不会被清

## 构建

需要 Xcode 26 以上、Node.js 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
git clone https://github.com/81199000/GuoDuo.git && cd GuoDuo
brew install xcodegen
cd core && npm ci && node build.cjs && cd ..
xcodegen generate
xcodebuild -project HongGuo.xcodeproj -scheme HongGuo -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## 目录结构

- `core/upstream/`：从上游 `src/native/` 拷贝的签名 / 设备注册 / 目录 / 搜索 / 取源模块（`public.js` 来自 `android/web/`，只改了 transport 路径），上游版本见 `core/UPSTREAM_COMMIT`
- `core/shims/`：Node 内置模块在 JSC 里的替身（沿用上游安卓版的 Native 桥约定）
- `core/entry.js`：导出 `HG.browse / search / episodes / source` 给 Swift
- `HongGuo/Core/HGCore.swift`：JSContext 宿主 + Native.*（网络、AES、摘要、gzip、计时器）
- `HongGuo/Core/HGCencDecryptor.swift`：CENC AES-CTR MP4 解密，对照上游 `decryptMp4Buffer` 逐字节一致
- `HongGuo/Player`、`HongGuo/Storage`：播放器手势、弹幕、环境光、储存管理，改自 [DouDuo](https://github.com/81199000/DouDuo)（MIT）

## 同步上游

上游更新不会自动进 GuoDuo，需要手动同步、重新发版：

```sh
U=/path/to/hongguo-drama
for f in app-source hongguo-app-catalog hongguo-app-search playback-device playback-signature playback-v5 sm3 request-signal download-quality; do cp $U/src/native/$f.js core/upstream/; done
cd core && npm install && node build.cjs
```

同步后更新 `core/UPSTREAM_COMMIT`。注意 `core/upstream/app-source.js` 有一处本地改动（`auto` 画质也带回宽高，搜 `GuoDuo：` 注释），覆盖后要补回。

## 发版（维护者）

1. 升 `project.yml` 的 `MARKETING_VERSION`
2. 写 `docs/releases/v<版本>.md`（App 内更新弹窗直接显示它的内容）
3. 提交并推送后运行 `./release.sh`：编译未签名 IPA，发布 GitHub Release

## 致谢与许可

- 取源核心：[jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama)（GPL-3.0）及其上游 woshishiq1/drpys、N3urda/hongguoTV、tsukiyo-zero/hongguoTV、charlie901208/HGTV 等贡献者，详见 [NOTICE](NOTICE) 与各文件头部
- 播放器与折叠屏布局：[DouDuo](https://github.com/81199000/DouDuo)（MIT）
- 本项目以 [GPL-3.0](LICENSE) 协议开源；你可以自由使用、修改和再分发，但衍生作品同样须以 GPL-3.0 开源

## 免责声明

> 本声明说明项目意图与边界，**不构成法律意见，也不能免除法律责任**。

GuoDuo 是非官方客户端，与红果短剧 / 字节跳动、西饭、河马及任何内容方**没有任何隶属、合作或授权关系**，不存储、不提供任何视频内容，片源均来自各平台接口。接口未公开，随时可能失效；不支持 ByteVC2 编码的集数。仅供个人学习研究使用，请勿用于商业用途或传播，所有商标归各自权利人所有。
