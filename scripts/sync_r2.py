#!/usr/bin/env python3
"""把 GuoDuo 的软件源 / 安装包 / 更新说明同步到 Cloudflare R2（dl.oneduo.app），App 内检查更新读这里。

2026-11-20 起 GuoDuo 的更新统一指向自家 oneduo.app（Gitee 镜像不对外）。
  python3 scripts/sync_r2.py            # 发版后跑：读 docs/source/guoduo.json，上传 build/ 里有的 IPA，
                                        # 生成下载地址指向 R2 的源副本，并上传 docs/releases/*.md
R2 布局（与一键签 py/packaging/r2_sync.py 一致）：
  guoduo/guoduo.json            软件源（下载地址 = R2）
  guoduo/v<版本>/<IPA 文件名>     安装包
  guoduo/notes/v<版本>.md        更新说明（App 弹窗显示）
凭据（不入库）：环境变量 ONEDUO_CF_TOKEN，或 ~/.config/oneduo/cf_token。
"""
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ACCOUNT = os.environ.get("ONEDUO_CF_ACCOUNT", "89ffdab4c08748b7a491e7a6f0d3147b")
BUCKET = os.environ.get("ONEDUO_R2_BUCKET", "oneduo-dl")
PUBLIC = "https://dl.oneduo.app"
API = f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/r2/buckets/{BUCKET}/objects/"
ROOT = pathlib.Path(__file__).resolve().parents[1]
UA = "GuoDuo-sync/1"


def token():
    t = os.environ.get("ONEDUO_CF_TOKEN")
    f = pathlib.Path.home() / ".config/oneduo/cf_token"
    if not t and f.exists():
        t = f.read_text().strip()
    if not t:
        sys.exit("没有 Cloudflare token（ONEDUO_CF_TOKEN 或 ~/.config/oneduo/cf_token）")
    return t


TOK = token()


def put(key, data: bytes, ctype, cache="public, max-age=60"):
    for i in range(4):
        req = urllib.request.Request(API + key, data=data, method="PUT", headers={
            "Authorization": "Bearer " + TOK, "Content-Type": ctype, "Cache-Control": cache})
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                if json.loads(r.read()).get("success"):
                    print(f"  ↑ {key}  ({len(data):,} B)")
                    return
        except Exception as e:  # noqa: BLE001
            print(f"  上传失败重试 {i + 1}：{key} {e}")
    raise SystemExit(f"上传失败：{key}")


def remote_size(key):
    try:
        req = urllib.request.Request(f"{PUBLIC}/{key}", method="HEAD", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            return int(r.headers.get("Content-Length") or -1)
    except urllib.error.HTTPError:
        return -1


def main():
    src = json.loads((ROOT / "docs/source/guoduo.json").read_text("utf-8"))
    kept = []
    for a in src.get("apps", []):
        ver = str(a.get("version") or "")
        name = (a.get("downloadURL") or "").rsplit("/", 1)[-1]
        ipa = ROOT / "build" / name
        key = f"guoduo/v{ver}/{name}"
        have = remote_size(key)
        if ipa.is_file() and have != ipa.stat().st_size:
            put(key, ipa.read_bytes(), "application/octet-stream", "public, max-age=31536000, immutable")
            have = ipa.stat().st_size
        elif have >= 0:
            print(f"  = {key}（已存在）")
        if have < 0:
            print(f"  ⚠️ {name} 本地没有、R2 也没有，源里去掉这个版本")
            continue
        a["downloadURL"] = f"{PUBLIC}/{key}"
        a["iconURL"] = f"{PUBLIC}/guoduo/app-icon.png"
        kept.append(a)
    if not kept:
        sys.exit("一个版本都没有可下载的 IPA")
    src["apps"] = kept
    src["name"] = "GuoDuo 官方源"
    src["sourceURL"] = f"{PUBLIC}/guoduo/guoduo.json"
    src["sourceicon"] = f"{PUBLIC}/guoduo/app-icon.png"
    put("guoduo/app-icon.png", (ROOT / "docs/brand/app-icon.png").read_bytes(), "image/png", "public, max-age=3600")
    for md in sorted((ROOT / "docs/releases").glob("v*.md")):
        if remote_size(f"guoduo/notes/{md.name}") != md.stat().st_size:
            put(f"guoduo/notes/{md.name}", md.read_bytes(), "text/markdown; charset=utf-8", "public, max-age=300")
    put("guoduo/guoduo.json", json.dumps(src, ensure_ascii=False, indent=2).encode(),
        "application/json; charset=utf-8")
    print(f"✅ {PUBLIC}/guoduo/guoduo.json  最新 {kept[0]['version']}")


if __name__ == "__main__":
    main()
