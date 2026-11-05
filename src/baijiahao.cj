/** 百家号发文客户端：走官方开发者接口 builderinner（后台「开发」菜单一次性拿
 * app_id + app_token，个人账号可开通；凭证与 Cookie 一样只存本地配置）。
 * 说明：纯 Cookie 直调后台编辑器发布接口（/rest/2.0/elite/article/publish）需 CSRF
 * 等完整参数，缺了直接 500，社区也无可靠先例——故百家号用官方 token 通道。
 * 接口约束（官方文档）：标题 8-40 字符、正文富文本 ≤20000 字符、origin_url 必填、
 * 无封面图的内容将进入草稿（草稿模式就不传 cover_images）。 */
package cspub

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*
import stdx.net.http.*

public const BJH_PUBLISH_URL: String = "https://baijiahao.baidu.com/builderinner/open/resource/article/publish"

/** 组发布请求体。coverSrc 非空 = 带 1 张封面（publish 模式用正文第一张图）；
 * 空 = 不带封面（按官方规则落到草稿）。纯函数，供测试对账。 */
public func buildBjhPayload(appId: String, appToken: String, title: String, content: String,
    originUrl: String, coverSrc: String, isOriginal: Bool): String {
    let body = JsonObject()
    body.put("app_id", JsonString(appId))
    body.put("app_token", JsonString(appToken))
    body.put("title", JsonString(title))
    body.put("content", JsonString(content))
    body.put("origin_url", JsonString(originUrl))
    if (coverSrc.size > 0) {
        let item = JsonObject()
        item.put("src", JsonString(coverSrc))
        let arr = JsonArray()
        arr.add(item)
        // 官方要求 cover_images 是 JSON 字符串字段（内嵌转义），不是 JSON 数组字段
        body.put("cover_images", JsonString(arr.toJsonString()))
    }
    body.put("is_original", JsonInt(if (isOriginal) { 1 } else { 0 }))
    return body.toJsonString()
}

/** 标题长度校验：官方限 8-40 个中英文字符（字节数判断过宽，按字符数——汉字在仓颉
 * String 迭代里就是一个元素；这里用字节数/3 的近似下界 + 字节数上界，两边都过才警告） */
public func bjhTitleValid(title: String): Bool {
    let n = title.size
    // 全 ASCII：字节数即字符数；含汉字：字节数在 [8, 120] 之间才可能满足 8-40 字符
    if (n >= 8 && n <= 40) {
        return true
    }
    // 粗放处理：交给平台最终校验，这里只拦明显越界（字节数 < 8 或 > 120 一定不合法）
    return n >= 8 && n <= 120 && n / 3 >= 8
}

/** 从响应 JSON 里取 errno / errmsg / data.article_id（非 JSON 输入返回 errno=-1） */
public func parseBjhResp(respText: String): (Int64, String, String) {
    var errno: Int64 = -1
    var errmsg = ""
    var articleId = ""
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                let obj = root.asObject()
                if (let Some(v) <- obj.get("errno")) {
                    match (v.kind()) {
                        case JsonKind.JsInt => errno = v.asInt().getValue()
                        case _ => ()
                    }
                }
                if (let Some(v) <- obj.get("errmsg")) {
                    match (v.kind()) {
                        case JsonKind.JsString => errmsg = v.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(d) <- obj.get("data")) {
                    match (d.kind()) {
                        case JsonKind.JsObject =>
                            if (let Some(v) <- d.asObject().get("article_id")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => articleId = v.asString().getValue()
                                    case JsonKind.JsInt => articleId = v.asInt().getValue().toString()
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
        errno = -1
    }
    return (errno, errmsg, articleId)
}

/** Cookie 浏览器自动化通道：百家号发布按钮是 React 组件（preCheck→paramProxy 事件链），
 * 纯 HTTP 直调必 500，社区可用实现全走浏览器自动化——故 Cookie 通道经 Playwright 伴生
 * 脚本发文（scripts/baijiahao_publish.py，宿主机需 python3 + playwright + chromium）。
 * 凭证经临时文件传递（用完即删），避免经 argv/ps 泄露。 */
public func publishToBaijiahaoCookie(cookie: String, a: Article, publishNow: Bool): Int64 {
    // 伴生脚本就位检查：CSPUB_SCRIPT_DIR → 当前目录 → 可执行文件目录向上回溯（util.cj 统一实现）
    let scriptPath = resolveCompanionScript("scripts/baijiahao_publish.py")
    if (scriptPath.size == 0) {
        println("错误：找不到伴生脚本 scripts/baijiahao_publish.py")
        println("     已查找：CSPUB_SCRIPT_DIR / 当前工作目录 / 可执行文件目录向上 5 级")
        println("     修复：cd 到 cspub 仓库根目录再跑，或 export CSPUB_SCRIPT_DIR=<仓库根>")
        return 1
    }
    // 写正文 HTML 与 Cookie 临时文件（File.create 对已存在文件抛异常，先删）
    let tmpHtml = "/tmp/cspub_bjh_${randomHex(8)}.html"
    let tmpCookie = "/tmp/cspub_bjh_${randomHex(8)}.cookie"
    try {
        writeFileTmp(tmpHtml, mdToHtml(a.body))
        writeFileTmp(tmpCookie, cookie)
        let mode = if (publishNow) { "publish" } else { "draft" }
        println("百家号：调起浏览器自动化（${mode}）…")
        // 发布模式官方要求必选封面：取正文第一张本地图作封面（无则脚本端继续尝试并如实报告）
        var coverFile = ""
        if (publishNow) {
            let imgs = findExternalImages(a.body)
            var i = 0
            while (i < imgs.size) {
                let u = imgs[i].url
                if (!u.startsWith("http://") && !u.startsWith("https://") && !u.startsWith("data:")) {
                    coverFile = u
                    break
                }
                i++
            }
        }
        var scriptArgs: ArrayList<String> = ArrayList<String>()
        scriptArgs.add(scriptPath)
        scriptArgs.add("--title")
        scriptArgs.add(a.title)
        scriptArgs.add("--html-file")
        scriptArgs.add(tmpHtml)
        scriptArgs.add("--cookie-file")
        scriptArgs.add(tmpCookie)
        scriptArgs.add("--mode")
        scriptArgs.add(mode)
        if (coverFile.size > 0) {
            scriptArgs.add("--cover-file")
            scriptArgs.add(coverFile)
        }
        let (exitCode, outBytes, errBytes) = executeWithOutput("python3", scriptArgs.toArray())
        println(String.fromUtf8(outBytes))
        let errText = String.fromUtf8(errBytes)
        if (errText.size > 0) {
            println(errText)
        }
        if (exitCode != 0) {
            println("提示：浏览器自动化失败——常见原因：Cookie 过期（重导整串，须含 BDUSS）、playwright/chromium 未装（pip install playwright && playwright install chromium）、前端改版选择器失效")
        }
        return exitCode
    } catch (e: Exception) {
        println("错误：百家号浏览器通道执行失败（${e.message}）")
        return 1
    } finally {
        // 凭证临时文件用完即删（best-effort）
        try { remove(tmpHtml) } catch (e: Exception) { let _ = e }
        try { remove(tmpCookie) } catch (e: Exception) { let _ = e }
    }
}

/** 临时文件写入：File.create 对已存在文件会抛异常，故先删再建 */
func writeFileTmp(path: String, content: String): Unit {
    try {
        remove(path)
    } catch (e: Exception) {
        let _ = e
    }
    let f = File.create(path)
    f.write(content.toArray())
    f.close()
}

/** 百家号官方 token 通道入口。publishNow=false 不传 cover_images（官方规则：无封面直接进草稿）；
 * publishNow=true 取正文第一张图作封面（无图则同样落草稿并提示）。
 * origin_url 官方必填：front-matter 加 origin_url: <原文地址>（首发链接即可）。 */
public func publishToBaijiahao(appId: String, appToken: String, a: Article, publishNow: Bool, insecure: Bool): Int64 {
    let html = mdToHtml(a.body)
    if (html.size > 20000 * 3) {
        println("⚠ 正文渲染后接近/超过 20000 字符上限（${html.size} 字节），可能被百家号拒收")
    }
    if (!bjhTitleValid(a.title)) {
        println("⚠ 标题「${a.title}」可能不满足百家号 8-40 字符要求（平台会最终校验）")
    }
    if (a.originUrl.size == 0) {
        println("错误：百家号接口要求 origin_url（原文地址）必填——front-matter 里加一行：origin_url: https://…（首发链接即可）")
        return 1
    }
    var coverSrc = ""
    if (publishNow) {
        let imgs = findExternalImages(a.body)
        if (imgs.size > 0) {
            coverSrc = imgs[0].url
            println("百家号：取正文第一张图作封面：${coverSrc}")
        } else {
            println("⚠ 正文无图：无封面的内容按官方规则会进入草稿（草稿模式或去后台补图后发布）")
        }
    }
    let payload = buildBjhPayload(appId, appToken, a.title, html, a.originUrl, coverSrc, true)

    let builder = HttpRequestBuilder()
        .url(BJH_PUBLISH_URL)
        .post()
        .body(payload)
    let req = applyHeaders(builder, [
        StrKV("Content-Type", "application/json"),
        StrKV("User-Agent", UA),
        StrKV("Accept", "*/*"),
        StrKV("Referer", "https://baijiahao.baidu.com/builder/rc/edit?type=news"),
        StrKV("Origin", "https://baijiahao.baidu.com"),
    ]).build()
    println("百家号：提交（${if (publishNow) { "publish" } else { "draft" } }）…")
    let resp = execRequest(req, insecure)
    dbg("百家号响应 HTTP ${resp.status}：${resp.text}")
    if (resp.status != 200) {
        println("错误：百家号返回 HTTP ${resp.status}")
        println(resp.text)
        return 1
    }
    let (errno, errmsg, articleId) = parseBjhResp(resp.text)
    if (errno != 0) {
        println("错误：百家号业务返回 errno=${errno} ${errmsg}")
        if (errno == 60001001) {
            println("提示：授权校验失败——检查 app_id / app_token 是否从后台「开发 → 基本配置」复制的最新值")
        } else if (errno == 60001009 || errno == 60001008) {
            println("提示：当日发文篇数已用完（存草稿同算），明天再试")
        }
        println(resp.text)
        return 1
    }
    if (articleId.size > 0) {
        println("文章链接：https://baijiahao.baidu.com/s?id=${articleId}")
        println("article id：${articleId}")
    } else {
        println("已提交（无封面图按官方规则进入草稿，去后台「内容管理 → 草稿」补图发布）")
    }
    return 0
}
