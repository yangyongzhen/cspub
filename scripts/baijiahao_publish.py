#!/usr/bin/env python3
"""baijiahao_publish.py — 百家号发文伴生脚本（Playwright 浏览器自动化）

为什么需要它：百家号后台发布按钮是 React 组件，点击需经过 preCheck→paramProxy
完整事件链才能触发发布 API；纯 HTTP 直调 /rest/2.0/elite/article/publish 缺
CSRF 参数必 500（baijiahao-auto skill 2026-04 实战记录）。社区所有可用实现
均走浏览器自动化，故 cspub 的 Cookie 通道也走这条路。

流程（镜像 baijiahao-auto/baijiahao-publisher 实测选择器）：
  打开编辑页 → 关新手引导 → execCommand 填标题 → UEditor setContent 填正文
  → 点「存草稿」/「发布」（发布时若有封面弹窗则选单图+确定）。

用法（由 cspub 自动调用，也可手动调试）：
  python3 baijiahao_publish.py --title "标题" --html-file body.html \
      --cookie-file cookie.txt --mode draft|publish

输入约定：Cookie 是浏览器复制的整串（name=value; ...，须含 BDUSS 登录态），
经 --cookie-file 传入（临时文件，用完即删），避免经 argv/ps 泄露。
输出约定：最后一行打 [RESULT] success ... 或 [RESULT] failed ...，退出码 0/1。
"""
import argparse
import sys
import time

EDIT_URL = "https://baijiahao.baidu.com/builder/rc/edit?type=news&is_from_cms=1"


def parse_cookie(text: str):
    """浏览器整串 Cookie → Playwright addCookies 需要的 dicts（域统一 .baidu.com）"""
    cookies = []
    for part in text.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        name, _, value = part.partition("=")
        name = name.strip()
        value = value.strip()
        if name:
            cookies.append({
                "name": name,
                "value": value,
                "domain": ".baidu.com",
                "path": "/",
            })
    return cookies


def hide_tour(page):
    """关新手引导弹窗（.cheetah-tour 每次加载都会出现且遮挡按钮）；
    同时把空的弹窗包裹层（.cheetah-modal-wrap：弹窗已关但透明层残留）去指针化，
    否则它会拦截后续所有点击。"""
    page.evaluate(
        "() => {"
        " const t = document.querySelector('.cheetah-tour');"
        " if (t) t.style.display = 'none';"
        " const m = document.querySelector('.cheetah-tour-mask');"
        " if (m) m.style.display = 'none';"
        " document.querySelectorAll('dialog, [role=dialog]').forEach(e => {"
        " if (!e.querySelector('input, iframe')) e.remove(); });"
        " document.querySelectorAll('.cheetah-modal-wrap').forEach(e => {"
        " if (!e.querySelector('.cheetah-modal')) { e.style.pointerEvents = 'none'; e.style.display = 'none'; } }); }"
    )


def close_promo(page):
    """AI 推广弹窗/智能标题气泡时序不定地弹出并挡住编辑区：
    循环用 DOM click（React 对 isTrusted 不敏感）关掉所有可见的 close 按钮。"""
    for _ in range(4):
        closed = page.evaluate(
            "() => { let n = 0;"
            " document.querySelectorAll('button.close, [class*=\\'close\\']').forEach(b => {"
            " if (b.offsetParent !== null) { b.click(); n++; } });"
            " document.querySelectorAll('.cheetah-modal-wrap').forEach(e => {"
            " const t = e.innerText || '';"
            " if (t.indexOf('立即体验') >= 0 || !e.querySelector('.cheetah-modal'))"
            " { e.style.pointerEvents = 'none'; e.style.display = 'none'; } });"
            " return n; }"
        )
        page.keyboard.press("Escape")
        time.sleep(1)
        if closed == 0:
            break


def fill_title(page, title: str):
    """真标题框：[data-testid='news-title-input'] 内的 Lexical 编辑器（占位符是普通 div）。
    Lexical 只认真实键盘输入；旧版 cheetah-input 兜底。"""
    if page.locator("input.cheetah-input").count() > 0:
        page.click("input.cheetah-input")
        page.evaluate("() => document.execCommand('selectAll', false, null)")
        page.keyboard.insert_text(title)
        return
    ti = page.locator("[data-testid='news-title-input'] [data-lexical-editor='true']").first
    for _ in range(3):
        close_promo(page)
        ti.click(force=True)
        time.sleep(0.5)
        page.keyboard.insert_text(title)
        time.sleep(0.5)
        got = (ti.inner_text() or "").strip()
        if title[:4] in got:
            return
    # 三次都没写进去：最后用 DOM 直写兜底（Lexical 内部态可能不认，但存草稿接口多按 DOM 取值）
    page.evaluate(
        "(v) => { const el = document.querySelector(\"[data-testid='news-title-input'] [data-lexical-editor='true']\");"
        " if (el) { el.innerText = v;"
        " el.dispatchEvent(new InputEvent('input', {bubbles: true, data: v, inputType: 'insertText'})); } }",
        title,
    )


def lexical_body_locator(page):
    """正文编辑器 = 不在标题框里的那个 data-lexical-editor（标题/正文 class 同名）"""
    idx = page.evaluate(
        "() => [...document.querySelectorAll(\"[data-lexical-editor='true']\")]"
        "   .findIndex(e => !e.closest(\"[data-testid='news-title-input']\"))"
    )
    return page.locator("[data-lexical-editor='true']").nth(idx if idx >= 0 else 1)


def fill_body(page, html: str):
    """正文：Lexical 编辑器逐字键入纯文本（headless 下真实剪贴板 Ctrl+V 不触发 Lexical
    粘贴，富文本格式会被剥离——标题层级转全大写换行、加粗转原文保字）。旧版 UEditor 兜底。"""
    editor = lexical_body_locator(page)
    if editor.count() == 0:
        frame_el = page.wait_for_selector("#ueditor_0", timeout=15000)
        frame = frame_el.content_frame()
        frame.wait_for_function("() => window.editor !== undefined", timeout=15000)
        frame.evaluate("html => { window.editor.setContent(html);"
                       " window.editor.fireEvent('contentchange');"
                       " window.editor.sync(); }", html)
        return
    editor.first.wait_for(state="visible", timeout=20000)
    editor.first.scroll_into_view_if_needed()
    close_promo(page)
    editor.first.click(force=True)
    time.sleep(0.5)
    page.keyboard.insert_text(_plain(html))
    time.sleep(1)


def _plain(html: str) -> str:
    """HTML → 纯文本（块级标签换行，去其余标签，实体还原）"""
    import re
    import html as _html
    t = re.sub(r"<(br|/p|/h[1-6]|/li|/div)[^>]*>", "\n", html, flags=re.I)
    t = re.sub(r"<[^>]+>", "", t)
    return _html.unescape(t)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--html-file", required=True, help="渲染好的正文 HTML 文件")
    ap.add_argument("--cookie-file", required=True, help="浏览器整串 Cookie 文件")
    ap.add_argument("--mode", choices=["draft", "publish"], default="draft")
    ap.add_argument("--cover-file", default="", help="发布模式的封面图（本地上传）")
    args = ap.parse_args()

    with open(args.html_file, encoding="utf-8") as f:
        html = f.read()
    with open(args.cookie_file, encoding="utf-8") as f:
        cookie_text = f.read().strip()
    cookies = parse_cookie(cookie_text)
    if not any(c["name"] == "BDUSS" for c in cookies):
        print("[RESULT] failed: Cookie 里没有 BDUSS（不是百度登录态整串）")
        return 1

    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(headless=True)
        except Exception as e:
            # 新版 playwright headless 默认找 chrome-headless-shell，没装就降级用完整版 chromium
            print(f"提示：headless shell 启动失败（{e}），降级用完整版 chromium")
            import glob as _glob
            candidates = sorted(_glob.glob(
                "/root/.cache/ms-playwright/chromium-*/chrome-linux*/chrome"))
            if not candidates:
                print("[RESULT] failed: 未找到 chromium，执行 python3 -m playwright install chromium")
                return 1
            browser = p.chromium.launch(
                headless=True, executable_path=candidates[-1],
                args=["--headless=new", "--no-sandbox"])
        context = browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            viewport={"width": 1440, "height": 900},
        )
        context.add_cookies(cookies)
        page = context.new_page()
        try:
            page.goto(EDIT_URL, wait_until="networkidle", timeout=45000)
            # SPA 渲染慢：新版 FeEditorApp 编辑器（contenteditable）或旧版标题框出现前是白壳
            page.wait_for_selector(
                "[class*='FeEditorApp'][class*='editor'], input.cheetah-input", timeout=40000)
            time.sleep(1)
            hide_tour(page)
            close_promo(page)
            fill_title(page, args.title)
            fill_body(page, html)
            time.sleep(1)
            hide_tour(page)

            label = "发布" if args.mode == "publish" else "存草稿"
            if args.mode == "publish" and args.cover_file:
                # 官方发布流要求必选封面：点内联面板「选择封面」→ 对话框 file input 上传 → 确定
                try:
                    box = page.get_by_text("选择封面", exact=True).first
                    box.scroll_into_view_if_needed()
                    box.click(force=True)
                    time.sleep(2)
                    # 对话框里的文件 input（可能延迟出现，轮询几次）
                    finput = None
                    for _ in range(6):
                        fis = page.locator(".cheetah-modal input[type=file], [class*='dialog'] input[type=file], [class*='modal'] input[type=file]")
                        if fis.count() > 0:
                            finput = fis.first
                            break
                        time.sleep(1)
                    if finput is not None:
                        finput.set_input_files(args.cover_file)
                        time.sleep(3)
                        # 裁剪/预览确认：按钮文案可能带计数（如「确定 (1)」），用包含匹配
                        for lbl in ("确定", "完成", "确认"):
                            btn = page.locator(f"button:has-text('{lbl}')")
                            clicked = False
                            for i in range(btn.count()):
                                if btn.nth(i).is_visible():
                                    btn.nth(i).click()
                                    time.sleep(1.5)
                                    clicked = True
                                    break
                            if clicked:
                                break
                        print("封面已上传：", args.cover_file)
                    else:
                        print("⚠ 未找到封面上传 input（对话框未弹出），尝试继续发布")
                except Exception as e:
                    print(f"⚠ 封面上传流程异常（{e}），尝试继续发布")

            page.get_by_text(label, exact=True).first.click()
            time.sleep(2)

            if args.mode == "publish":
                # 官方发布流：点发布 → 封面选择（单图/三图）→ 确定 → 可能再有关键词/声明确认。
                # 循环处理：有可见弹窗就点「单图」/「确定」/「发布」，看到成功 toast 收工。
                success = False
                for _ in range(12):
                    time.sleep(2)
                    state = page.evaluate(
                        """() => {
                          const vis = e => e.offsetParent !== null;
                          const txt = [...document.querySelectorAll('.cheetah-modal, [class*=\\'dialog\\'], [class*=\\'modal\\']')]
                            .filter(vis).map(e => e.innerText || '').join('|');
                          const toasts = [...document.querySelectorAll('*')].filter(vis)
                            .filter(e => e.childElementCount === 0 && /发布成功|已发布|审核中/.test(e.textContent || ''))
                            .map(e => e.textContent).join('|');
                          return {txt: txt.slice(0, 300), toasts};
                        }"""
                    )
                    if state["toasts"]:
                        print("toast:", state["toasts"][:60])
                        success = True
                        break
                    modal_txt = state["txt"]
                    if not modal_txt:
                        if "builder/rc/edit" not in page.url:
                            success = True
                            break
                        continue
                    # 封面选择：选单图（无可选项就直接确定）；按钮文案可能带计数，用包含匹配
                    for label in ("单图", "确定", "发 布", "发布"):
                        try:
                            btn = page.locator(f"button:has-text('{label}'), [role='button']:has-text('{label}')")
                            clicked = False
                            for i in range(btn.count()):
                                if btn.nth(i).is_visible():
                                    btn.nth(i).click()
                                    time.sleep(1.5)
                                    clicked = True
                                    break
                            if clicked:
                                break
                        except Exception:
                            pass
                if not success:
                    print("[RESULT] failed: 点击发布后未见成功提示（可能缺封面/命中风控/待二次确认），请看截图 baijiahao_result.png")
                    page.screenshot(path="baijiahao_result.png")
                    return 1
                time.sleep(2)
                print(f"[RESULT] success: mode=publish page={page.url}")
                page.screenshot(path="baijiahao_result.png")
                return 0

            time.sleep(2)
            url = page.url
            in_edit = "builder/rc/edit" in url and "article_id" not in url
            # 空内容假成功防线：正文编辑器（不在标题框里的那个）必须有字，标题也要写上
            body_len = page.evaluate(
                "() => { const eds = [...document.querySelectorAll(\"[data-lexical-editor='true']\")]"
                "   .filter(e => !e.closest(\"[data-testid='news-title-input']\"));"
                " return eds.length ? (eds[0].innerText || '').trim().length : -1; }"
            )
            title_len = page.evaluate(
                "() => { const el = document.querySelector(\"[data-testid='news-title-input'] [data-lexical-editor='true']\");"
                " return el ? (el.innerText || '').trim().length : -1; }"
            )
            if in_edit and (body_len == 0 or title_len == 0):
                print(f"[RESULT] failed: 内容未写入成功（标题 {title_len} 字 / 正文 {body_len} 字），请看截图 baijiahao_result.png")
                page.screenshot(path="baijiahao_result.png")
                return 1
            if in_edit and args.mode == "publish":
                # 仍在编辑页且没有 article_id：多半被校验拦下
                print("[RESULT] failed: 点击发布后仍在编辑页（可能缺封面/命中风控提示），"
                      "请看截图 baijiahao_result.png")
                page.screenshot(path="baijiahao_result.png")
                return 1
            print(f"[RESULT] success: mode={args.mode} page={url}")
            page.screenshot(path="baijiahao_result.png")
            return 0
        except Exception as e:
            print(f"[RESULT] failed: {e}")
            try:
                page.screenshot(path="baijiahao_result.png")
            except Exception:
                pass
            return 1
        finally:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
