#!/usr/bin/env python3
"""juejin_upload.py — 掘金图片上传伴生脚本（真实浏览器通道）

为什么用浏览器：掘金图床是字节 ImageX，直调需要 AWS SigV4 签名，
但网关对非浏览器客户端稳定回 SignatureDoesNotMatch（2026-11-05 抓包铁证：
浏览器同请求的 SignedHeaders 只有 x-amz-date;x-amz-security-token，照抄仍被拒，
实为网关按 TLS/客户端指纹校验）。真实浏览器在掘金编辑器里上传则一次成功，
且拿到的就是编辑器会写进正文的同一条 CDN 地址，故走浏览器（与百家号通道同一模式）。

用法（由 cspub 自动调用，也可手动调试）：
  python3 juejin_upload.py --cookie-file cookie.txt --map-file map.json img1.png img2.jpg ...

输出约定：向 map-file 写回 {"<原始路径>": "<CDN URL>", ...} 的 JSON 并退出 0；
任一张失败时该路径映射为 ""。宿主机需 python3 + playwright + chromium。
"""
import argparse
import glob
import json
import sys

EDITOR_URL = "https://juejin.cn/editor/drafts/new"
# 上传后等待编辑器把图片 CDN 地址渲染出来的上限（毫秒）
UPLOAD_WAIT_MS = 20000


def parse_cookie(raw):
    """Cookie 整串 → playwright cookie 列表（域限定 .juejin.cn）。"""
    out = []
    for part in raw.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, v = part.split("=", 1)
        out.append({"name": k.strip(), "value": v.strip(),
                    "domain": ".juejin.cn", "path": "/"})
    return out


def launch(pw):
    """启动 chromium：优先默认 headless，没装 headless-shell 时降级完整版。"""
    try:
        return pw.chromium.launch(headless=True, args=["--no-sandbox"])
    except Exception as e:
        print(f"提示：默认 headless 启动失败（{e}），降级完整版 chromium", file=sys.stderr)
    cands = sorted(glob.glob("/root/.cache/ms-playwright/chromium-*/chrome-linux*/chrome"))
    if not cands:
        raise RuntimeError("未找到 chromium，执行 python3 -m playwright install chromium")
    return pw.chromium.launch(headless=True, args=["--no-sandbox"], executable_path=cands[-1])


def collect_cdn_url(resp):
    """识别 get_img_url 响应，解析出 main_url。"""
    if "get_img_url" not in resp.url:
        return None
    try:
        d = json.loads(resp.text())
    except Exception:
        return None
    if d.get("err_no") != 0:
        return None
    u = d.get("data", {}).get("main_url", "")
    return u or None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cookie-file", required=True)
    ap.add_argument("--map-file", required=True, help="路径→URL 映射 JSON 输出文件")
    ap.add_argument("images", nargs="+", help="本地图片路径列表")
    args = ap.parse_args()

    from playwright.sync_api import sync_playwright

    cookie = open(args.cookie_file, encoding="utf-8").read().strip()
    mapping = {p: "" for p in args.images}
    with sync_playwright() as pw:
        browser = launch(pw)
        ctx = browser.new_context(viewport={"width": 1440, "height": 900})
        ctx.add_cookies(parse_cookie(cookie))
        pending = {"url": ""}

        def on_resp(resp):
            u = collect_cdn_url(resp)
            if u:
                pending["url"] = u

        ctx.on("response", on_resp)
        page = ctx.new_page()
        page.goto(EDITOR_URL, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(5000)
        if "editor" not in page.url:
            print(f"WARNING: 未进入编辑器（当前 {page.url}），Cookie 可能已失效", file=sys.stderr)
            json.dump(mapping, open(args.map_file, "w", encoding="utf-8"), ensure_ascii=False)
            browser.close()
            sys.exit(1)

        for path in args.images:
            url = ""
            try:
                inputs = page.query_selector_all("input[type=file]")
                if not inputs:
                    print(f"WARNING: {path} 找不到上传入口", file=sys.stderr)
                else:
                    pending["url"] = ""
                    inputs[0].set_input_files(path)
                    waited = 0
                    while waited < UPLOAD_WAIT_MS and not pending["url"]:
                        page.wait_for_timeout(500)
                        waited += 500
                    url = pending["url"]
            except Exception as e:
                print(f"WARNING: {path} 上传异常：{e}", file=sys.stderr)
            mapping[path] = url
            print(f"  {path} -> {url or '(失败)'}", file=sys.stderr)

        browser.close()

    with open(args.map_file, "w", encoding="utf-8") as f:
        json.dump(mapping, f, ensure_ascii=False)
    sys.exit(0 if any(mapping.values()) else 1)


if __name__ == "__main__":
    main()
