# HongGuo（红果自用 iOS）

私有自用。SwiftUI 界面 + JavaScriptCore 跑上游 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama) 的取源核心（GPL-3.0）。

- `core/upstream/`：从上游 `src/native/` 原样拷贝的签名 / 设备注册 / 目录 / 搜索 / 取源模块（`public.js` 来自 `android/web/`，只改了 transport 路径）
- `core/shims/`：Node 内置模块在 JSC 里的替身（沿用上游安卓版 `android/web/` 的 Native 桥约定）
- `core/entry.js`：导出 `HG.browse / search / episodes / source` 给 Swift
- `HongGuo/Core/HGCore.swift`：JSContext 宿主 + Native.*（网络、AES、摘要、gzip、计时器）
- `HongGuo/Core/HGCencDecryptor.swift`：CENC AES-CTR MP4 解密，对照上游 `decryptMp4Buffer` 逐字节一致

## 同步上游

```sh
U=/path/to/hongguo-drama
for f in app-source hongguo-app-catalog hongguo-app-search playback-device playback-signature playback-v5 sm3 request-signal download-quality; do cp $U/src/native/$f.js core/upstream/; done
cd core && npm install && node build.cjs
```

## 构建

```sh
xcodegen generate
xcodebuild -project HongGuo.xcodeproj -scheme HongGuo -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

不支持 ByteVC2 编码的集数。片源接口未公开，随时可能失效。
