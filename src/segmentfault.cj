/** SegmentFault 思否发文：走前端自用的 `/gateway` 网关——Cookie 取页内 Token、双头鉴权、零签名。
 *
 * 探明的接口形状（2026-11 实测，见 docs/多平台发文调研.md §九）：
 *   POST https://segmentfault.com/gateway/article     发文      无 Cookie → 401 "Unauthorized"
 *   POST https://segmentfault.com/gateway/draft       存草稿    无 Cookie → 401
 *   PUT  https://segmentfault.com/gateway/draft/{id}  改草稿
 *   GET  https://segmentfault.com/gateway/user/@me    当前用户
 *   POST https://segmentfault.com/gateway/image       图片（multipart）
 *   对照：GET /gateway/service/time?query=current → 200 {"time":1793916562}（公开接口，探活用）
 *
 * 三条实测出来的硬规矩，违反任意一条都发不出去：
 * ① **所有业务路径都要拼在 `/gateway` 后面**（前端 `let T = "/gateway" + m`）。
 *    网上流传的 `/api/article/create`、`/api/articles` 一类路径实测 404，别再用。
 * ② **403 不是登录问题，是 CSRF**：缺 `Referer`/`Origin` 会先被网关拦下，回
 *    「非法请求，请刷新页面后重试」。看到 403 先补 Referer，别去换 Cookie。
 * ③ **Token 与 Authorization 必须同值**（`Token: C` + `Authorization: "Bearer " + C`），
 *    缺一个都可能被拒；而这个 Token 思否**不放在 Cookie 里**，得先从写文章页的
 *    `__NEXT_DATA__` 里取 `serverData.Token`（未登录时该值是空串）。
 *
 * 正文形态：`text` 字段是 **HTML 富文本**（编辑器产出），不是 Markdown；本模块用 mdToHtml 渲染。
 * 因此图片必须是公网可访问的 URL——思否不像头条那样强制搬进自家 CDN，外链可直接留用，
 * 所以本地图走 AtomGit 图床转外链（复用 rehostImagesAtomGit），失败只警告不阻断。
 *
 * 草稿与发布是两个不同端点（/draft 与 /article），不是同一个接口的开关字段——
 * 所以 --draft 真能存草稿，不像腾讯云那样只能 dry-run。
 *
 * 未能离线确定的一项：**成功响应体的具体形状**（登录后才拿得到）。
 * 因此成功判据做成「HTTP 200 即算提交成功，能抠到 id 就打印，抠不到也不判失败」——
 * 宁可少判一次失败，也不要因为猜错字段名把已经发出去的文章报成失败。
 */
package cspub

import std.collection.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

public const SEGMENTFAULT_SITE: String = "https://segmentfault.com"
public const SEGMENTFAULT_WRITE_PAGE: String = "https://segmentfault.com/write"
public const SEGMENTFAULT_ARTICLE_API: String = "https://segmentfault.com/gateway/article"
public const SEGMENTFAULT_DRAFT_API: String = "https://segmentfault.com/gateway/draft"
public const SEGMENTFAULT_USER_API: String = "https://segmentfault.com/gateway/user/@me"
public const SEGMENTFAULT_IMAGE_API: String = "https://segmentfault.com/gateway/image"
/** 写文章页 `__NEXT_DATA__` 里 token 的锚点。用整段锚点而不是只认 `"Token":"`，
 * 避免页面别处出现同名键时取错（实测该页只有 serverData 这一处）。 */
const SEGMENTFAULT_TOKEN_ANCHOR: String = "\"serverData\":{\"Token\":\""
const SEGMENTFAULT_UA: String = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

/** 在字节数组里找子串，返回偏移（-1 = 没找到）。手写而非依赖 String API：
 * 页面 HTML 动辄几百 KB，按字节扫既省一次编码又不会在汉字中间切界。 */
func sfFindBytes(hay: Array<Byte>, needle: Array<Byte>): Int64 {
    let n = Int64(hay.size)
    let m = Int64(needle.size)
    if (m == 0 || m > n) {
        return -1
    }
    var i: Int64 = 0
    while (i + m <= n) {
        var j: Int64 = 0
        var eq = true
        while (j < m) {
            if (hay[i + j] != needle[j]) {
                eq = false
                break
            }
            j++
        }
        if (eq) {
            return i
        }
        i++
    }
    return -1
}

/** 从写文章页 HTML 抠 `serverData.Token`（纯函数，单测覆盖）。
 * 未登录时页面里的值是空串，这里如实返回 ""——调用方据此报「Cookie 失效」，
 * 而不是带着空 Token 去撞一个看不懂的 401。 */
public func extractSegmentfaultToken(html: String): String {
    let b = html.toArray()
    let anchor = SEGMENTFAULT_TOKEN_ANCHOR.toArray()
    let at = sfFindBytes(b, anchor)
    if (at < 0) {
        return ""
    }
    let start = at + Int64(anchor.size)
    let n = Int64(b.size)
    var end = start
    while (end < n && b[end] != UInt8(34)) {
        end++
    }
    if (end <= start) {
        return ""
    }
    // 整段转码，不逐字节 append（逐字节会把多字节字符拆成非法序列，AGENTS §4）
    return String.fromUtf8(b[start..end])
}

/** front-matter 的 tags（逗号分隔）→ 标签名数组。空项丢弃；
 * 思否的标签在编辑器里是按名字选的，所以传名字不传 id（若后端要 id 会回参数错误）。 */
public func parseSegmentfaultTags(tags: String): Array<String> {
    let list = ArrayList<String>()
    for (p in tags.split(",", -1)) {
        let t = trimAscii(p)
        if (t.size > 0) {
            list.add(t)
        }
    }
    return list.toArray()
}

/** 发文/草稿请求体（纯函数，单测覆盖）：字段构成取自思否编辑器源码
 * `{title, tags, text, object_id, type, language, ...(type==="article" ? {cover} : {})}`。
 * object_id 空串 = 新建；cover 只在非空时带（空串塞进去容易被判非法封面）。 */
public func buildSegmentfaultArticleBody(title: String, text: String, tags: Array<String>,
    objectId: String, docType: String, language: String, cover: String): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    let arr = JsonArray()
    for (t in tags) {
        arr.add(JsonString(t))
    }
    o.put("tags", arr)
    o.put("text", JsonString(text))
    o.put("object_id", JsonString(objectId))
    o.put("type", JsonString(docType))
    o.put("language", JsonString(language))
    if (cover.size > 0) {
        o.put("cover", JsonString(cover))
    }
    return o.toJsonString()
}

/** 解析响应：返回 (code, msg, id)。
 * 成功形状未经真机确认，所以这里做**宽进**：对象取 id/uuid 与 message/msg，
 * 纯字符串（如 401 的 `"Unauthorized"`）当成 msg。抠不到 id 不算失败——
 * 判成功的责任在调用方（HTTP 200 即视为已提交）。 */
public func parseSegmentfaultResp(text: String): (Int64, String, String) {
    let body = trimAscii(text)
    if (body.size == 0) {
        return (0, "", "")
    }
    let root = try {
        JsonValue.fromStr(body)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var code: Int64 = 0
    var msg = ""
    var id = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let c = jsonScalar(root, "code")
            if (c.size > 0) {
                code = try {
                    Int64.parse(trimAscii(c))
                } catch (e: Exception) {
                    let _ = e
                    Int64(0)
                }
            }
            msg = jsonScalar(root, "message")
            if (msg.size == 0) {
                msg = jsonScalar(root, "msg")
            }
            id = jsonScalar(root, "id")
            if (id.size == 0) {
                id = jsonScalar(root, "uuid")
            }
        case JsonKind.JsString =>
            // 网关的错误体就是一个 JSON 字符串："Unauthorized"
            msg = root.asString().getValue()
        case _ => ()
    }
    return (code, msg, id)
}

/** 取写文章页里的 Token。返回 (token, HTTP 状态)；token 为空串即未登录/页面结构变了。
 * 这一步同时也是一次登录态检查：思否没有能单独校验的 cookie 字段，
 * 登录与否只能看这个 token 是否非空。 */
public func fetchSegmentfaultToken(cookie: String, insecure: Bool): (String, Int64) {
    let builder = HttpRequestBuilder()
        .url(SEGMENTFAULT_WRITE_PAGE)
        .get()
    let req = applyHeaders(builder, [
        StrKV("User-Agent", SEGMENTFAULT_UA),
        StrKV("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
        StrKV("Referer", SEGMENTFAULT_SITE + "/"),
        StrKV("Cookie", cookie),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("segmentfault /write HTTP ${r.status}（${r.text.size} 字节）")
    if (r.status != 200) {
        return ("", r.status)
    }
    return (extractSegmentfaultToken(r.text), r.status)
}

/** 思否发文入口。publishNow=true → /gateway/article 直接发；false → /gateway/draft 存草稿。
 * 图片：正文必须是公网 URL，本地图先转 AtomGit 外链；没配令牌就只警告（页面会破图但不阻断）。 */
public func publishToSegmentfault(cookie: String, a: Article, publishNow: Bool, insecure: Bool,
    atomgitToken: String, atomgitRepo: String, atomgitBranch: String, atomgitDir: String): Int64 {

    if (trimAscii(a.title).size == 0) {
        println("错误：标题为空。思否标题必填")
        return 1
    }

    // ① 图片：本地图转公网外链（思否正文是 HTML，图必须是可访问 URL）
    var body = a.body
    if (atomgitToken.size > 0) {
        let (b1, ok1, fail1) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        if (ok1 > 0 || fail1 > 0) {
            body = b1
            println("图片（AtomGit 外链）：成功 ${ok1}，失败 ${fail1}")
        }
    }
    let locals = localImageCount(body)
    if (locals > 0) {
        println("警告：正文还有 ${locals} 张本地图片没有公网 URL，思否页面上会显示成破图。")
        println("      配 CSPUB_ATOMGIT_TOKEN 可让本地图自动上传图床（见 help 的「图片外链」）")
    }

    // ② Token：思否不放 Cookie，只能从写文章页实时取
    let (token, pageStatus) = fetchSegmentfaultToken(cookie, insecure)
    if (token.size == 0) {
        if (pageStatus != 200) {
            println("错误：取写文章页失败（HTTP ${pageStatus}）")
            println("提示：网络不通或被拦；如果本机证书链有问题可加 --insecure 重试")
        } else {
            println("错误：写文章页里没有 Token（值是空串）——Cookie 不是登录态")
            println("提示：浏览器登录 segmentfault.com 后复制整串 Cookie，再 export CSPUB_SEGMENTFAULT_COOKIE='<整串>'")
        }
        return 1
    }

    // ③ 组装并提交
    let html = mdToHtml(body)
    let payload = buildSegmentfaultArticleBody(a.title, html, parseSegmentfaultTags(a.tags),
        "", "article", "zh-CN", "")
    let api = if (publishNow) { SEGMENTFAULT_ARTICLE_API } else { SEGMENTFAULT_DRAFT_API }
    let builder = HttpRequestBuilder()
        .url(api)
        .post()
        .header("Content-Type", "application/json")
        .body(payload)
    // Token 与 Authorization 同值、Origin/Referer 必带（缺 Referer 会被 CSRF 网关 403 拦下）
    let req = applyHeaders(builder, [
        StrKV("User-Agent", SEGMENTFAULT_UA),
        StrKV("Accept", "application/json, text/plain, */*"),
        StrKV("Origin", SEGMENTFAULT_SITE),
        StrKV("Referer", SEGMENTFAULT_WRITE_PAGE),
        StrKV("Cookie", cookie),
        StrKV("Token", token),
        StrKV("Authorization", "Bearer " + token),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("segmentfault ${api} HTTP ${r.status}：${r.text}")

    let (code, msg, articleId) = parseSegmentfaultResp(r.text)
    if (r.status == 401 || r.status == 403) {
        let why = if (r.status == 401) {
            "未登录/Token 失效"
        } else {
            "CSRF 校验未过"
        }
        println("错误：思否拒绝（HTTP ${r.status}，${why}${if (msg.size > 0) { "，${msg}" } else { "" }}）")
        if (r.status == 403) {
            println("提示：403 通常是 Referer/Origin 或 Token 不配套——Token 与 Authorization 必须同值")
        } else {
            println("提示：重新登录 segmentfault.com 后复制整串 Cookie（Token 每次从写文章页实时取）")
        }
        return 1
    }
    if (r.status == 404) {
        println("错误：接口 404（HTTP 404）——请求路径不存在，可能是思否改了网关前缀")
        println("提示：这是实现该更新，不是 Cookie 问题；请反馈 docs/多平台发文调研.md §九 的实测端点")
        return 1
    }
    if (r.status != 200) {
        println("错误：思否提交失败（HTTP ${r.status}${if (code != 0) { "，code ${code}" } else { "" }}${if (msg.size > 0) { "，${msg}" } else { "" }}）")
        println(r.text)
        return 1
    }

    // ④ 成功：响应形状未经真机确认，故以 HTTP 200 为准，抠到 id 就顺带打印
    let what = if (publishNow) { "发布成功" } else { "草稿已保存" }
    if (articleId.size > 0) {
        println("思否：${what}，id ${articleId}")
    } else {
        println("思否：${what}（响应里没有 id 字段，形状待真机确认）")
    }
    if (publishNow) {
        println("提示：文章管理 https://segmentfault.com/user/articles（思否有审核队列，发布成功≠已公开）")
    } else {
        println("草稿箱：https://segmentfault.com/user/draft")
    }
    return 0
}
