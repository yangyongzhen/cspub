/** 头条号发文：模拟 mp.toutiao.com 后台自用的 mp/agw 接口——Cookie + X-CSRFToken 鉴权，无签名。
 *
 * 探明的接口形状（2026-11 实测鉴权语义，见 docs/多平台发文调研.md §三）：
 *   POST /mp/agw/article/publish?source=mp&type=article&aid=13&device_platform=web
 *        无 Cookie → HTTP 200 {"code":100005,"message":"获取用户信息失败"}
 *   GET  /mp/agw/media/get_media_info
 *        无 Cookie → HTTP 200 {"code":100004,"message":"user not login"}
 *   POST /mp/agw/article_material/photo/upload_picture?type=ueditor&pgc_watermark=1&action=uploadimage&encode=utf-8
 *        无 Cookie → HTTP 200 {"code":1000,"message":"用户未登录"}（multipart 字段 upfile）
 *
 * 实测排除的假路径（别再试）：`article/publish_v2`、`article/upload_img`、`article/upload_image`、
 * `article/publish_draft`、`user/get_user_info` 全部 404；`tools/catch_picture/` 502。
 * 404 只代表网上流传的路径过期，不代表平台不支持。
 *
 * 头条最硬的一条约束：**正文里任何一张 <img> 只要指向非头条域名，整篇被拒「7115 图片uri非法」**。
 * 别的平台（CSDN/掘金/腾讯云）外链图能留用，头条不行——每张图必须先 multipart 传到头条 CDN，
 * 拿回 web_uri 后把 <img> 改写成 `<img src="<头条链接>" web_uri="<头条uri>">`。
 * 因此本地图与外链图在这里是同一套管线，不像别的平台只处理本地图。
 *
 * 草稿：publish 请求体的 save 字段，0=发布、1=存草稿（按社区实现惯例，**未经真机验证**——
 * 本机无头条登录态，端到端发布待凭证补齐后确认，见 CHANGELOG）。
 */
package cspub

import std.collection.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

public const TOUTIAO_PUBLISH_API: String = "https://mp.toutiao.com/mp/agw/article/publish?source=mp&type=article&aid=13&device_platform=web"
public const TOUTIAO_UPLOAD_API: String = "https://mp.toutiao.com/mp/agw/article_material/photo/upload_picture?type=ueditor&pgc_watermark=1&action=uploadimage&encode=utf-8"
public const TOUTIAO_MEDIA_API: String = "https://mp.toutiao.com/mp/agw/media/get_media_info"
public const TOUTIAO_SITE: String = "https://mp.toutiao.com"
/** 标题字符数区间：头条后台写死 5~30 字（外部资料 + 编辑器行为，本机无凭证未真验） */
public const TOUTIAO_TITLE_MIN: Int64 = 5
public const TOUTIAO_TITLE_MAX: Int64 = 30
const TOUTIAO_UA: String = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

/** 登录态判定：sessionid 或 tt_webid 有一个就算（其它 cookie 只是埋点/灰度标识） */
public func toutiaoCookieHasSession(cookie: String): Bool {
    return cookieValue(cookie, "sessionid").size > 0 || cookieValue(cookie, "tt_webid").size > 0
}

/** X-CSRFToken 头的值：取 cookie 里的 csrftoken；缺失时返回空串（调用方据此警告，不硬编造） */
public func toutiaoCsrfToken(cookie: String): String {
    let t = cookieValue(cookie, "csrftoken")
    if (t.size > 0) {
        return t
    }
    // 头条部分账号只在 csrf_sessionid 里带 token，退一步取它
    return cookieValue(cookie, "csrf_sessionid")
}

/** 标题字符数（按 UTF-8 字符，不按字节：切在汉字中间会算成 3 个字） */
public func toutiaoTitleChars(title: String): Int64 {
    return utf8CharCount(trimAscii(title))
}

/** 标题是否在头条允许的 5~30 字区间 */
public func toutiaoTitleOk(title: String): Bool {
    let n = toutiaoTitleChars(title)
    return n >= TOUTIAO_TITLE_MIN && n <= TOUTIAO_TITLE_MAX
}

/** publish 请求体（纯函数，单测覆盖）。
 * save: 0=发布、1=草稿；pgc_id 传 "0" 表示新建；封面走 pgc_feed_covers（空数组=不设封面，头条自动取正文首图）。 */
public func buildToutiaoArticleBody(title: String, html: String, save: Int64, coverJson: String): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    o.put("content", JsonString(html))
    o.put("article_ad_type", JsonInt(2))
    o.put("article_type", JsonInt(0))
    o.put("from_diagnosis", JsonInt(0))
    o.put("origin_debut_check_pgc_normal", JsonInt(0))
    o.put("tree_plan_article", JsonInt(0))
    o.put("save", JsonInt(save))
    o.put("pgc_id", JsonString("0"))
    let covers = if (coverJson.size > 0) { coverJson } else { "[]" }
    o.put("pgc_feed_covers", JsonString(covers))
    return o.toJsonString()
}

/** 解析 mp/agw 响应：返回 (code, message, pgc_id)。
 * 成功体形如 {"code":0,"data":{"pgc_id":"7031386221209256455"}}；未登录体 code 是 100004/100005。
 * 注意 code 在 JSON 里是**数字**，必须走 jsonScalar（只认字符串的 jsonStr 会取到空串，得 0 分不清成功失败）。 */
public func parseToutiaoResp(text: String): (Int64, String, String) {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var code: Int64 = 0
    var msg = ""
    var pgc = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let c = jsonScalar(root, "code")
            if (c.size > 0) {
                code = toutiaoNum(c)
            }
            msg = jsonScalar(root, "message")
            if (msg.size == 0) {
                msg = jsonScalar(root, "reason")
            }
            if (let Some(d) <- jsonObjField(root, "data")) {
                pgc = jsonScalar(d, "pgc_id")
            }
        case _ => ()
    }
    return (code, msg, pgc)
}

/** 登录类错误码：100004/100005 是 mp/agw 通用未登录，1000 是图片上传接口的未登录 */
public func toutiaoLoginCode(code: Int64): Bool {
    return code == 100004 || code == 100005 || code == 1000
}

/** 数字兜底解析：非数字返回 0 */
func toutiaoNum(s: String): Int64 {
    let t = trimAscii(s)
    if (t.size == 0) {
        return 0
    }
    let v = try {
        Int64.parse(t)
    } catch (e: Exception) {
        let _ = e
        Int64(0)
    }
    return v
}

/** 文章地址：头条正式文是 https://www.toutiao.com/article/{pgc_id}/，草稿只在后台可见 */
public func toutiaoArticleUrl(pgcId: String): String {
    return "https://www.toutiao.com/article/${pgcId}/"
}

/** 后台草稿编辑地址（save=1 时给出，供人工补封面/改分类） */
public func toutiaoDraftUrl(pgcId: String): String {
    return "${TOUTIAO_SITE}/profile_v3/graphic/publish?pgc_id=${pgcId}"
}

// ── 头条图片转存（头条唯一认可的是自家 CDN 的 web_uri，外链一律 7115） ──

/** 收集 HTML 正文里所有 <img src="...">（纯函数，单测覆盖）。按字节扫描，
 * 不用正则：mdToHtml 的输出格式固定为 `<img src="URL" alt="...">`，扫引号即可。 */
public func collectImgSrcs(html: String): Array<String> {
    let b = html.toArray()
    let marker = "<img src=\"".toArray()
    let n = Int64(b.size)
    let mlen = Int64(marker.size)
    let out = ArrayList<String>()
    var i: Int64 = 0
    while (i + mlen <= n) {
        var eq = true
        var j: Int64 = 0
        while (j < mlen) {
            if (b[i + j] != marker[j]) {
                eq = false
                break
            }
            j++
        }
        if (eq) {
            let start = i + mlen
            var end = start
            while (end < n && b[end] != UInt8(34)) {
                end++
            }
            if (end < n) {
                let u = String.fromUtf8(b[start..end])
                if (u.size > 0) {
                    out.add(u)
                }
                i = end + 1
                continue
            }
        }
        i++
    }
    return out.toArray()
}

/** 按 url → 替换前缀 的映射改写 img 标签（纯函数，单测覆盖）。
 * 替换串形如 `<img src="https://...toutiaoimg.com/..." web_uri="tos-cn-..."`，
 * 标签其余部分（`" alt="...">"`）原样保留，最终得到头条编辑器认的双属性形态。 */
public func rewriteHtmlImgs(html: String, map: HashMap<String, String>): String {
    let b = html.toArray()
    let marker = "<img src=\"".toArray()
    let n = Int64(b.size)
    let mlen = Int64(marker.size)
    let acc = StringBuilder()
    var last: Int64 = 0
    var i: Int64 = 0
    while (i + mlen <= n) {
        var eq = true
        var j: Int64 = 0
        while (j < mlen) {
            if (b[i + j] != marker[j]) {
                eq = false
                break
            }
            j++
        }
        if (eq) {
            let start = i + mlen
            var end = start
            while (end < n && b[end] != UInt8(34)) {
                end++
            }
            if (end < n) {
                let u = String.fromUtf8(b[start..end])
                if (let Some(repl) <- map.get(u)) {
                    acc.append(String.fromUtf8(b[last..i]))
                    acc.append(repl)
                    last = end
                }
                i = end + 1
                continue
            }
        }
        i++
    }
    acc.append(String.fromUtf8(b[last..n]))
    return acc.toString()
}

/** 上传一张图到头条 CDN：POST upload_picture（multipart，字段名 upfile）。
 * 返回 (web_uri, 可展示链接)；失败返回 ("", "")。
 * 失败不抛异常：调用方要能统计「几张传失败」再决定要不要拦发布——头条会整篇拒稿，
 * 提前说清楚比抛一个栈更接近用户的决策现场。 */
public func uploadToutiaoImage(cookie: String, csrf: String, data: Array<Byte>, ext: String,
    insecure: Bool): (String, String) {
    if (data.size == 0) {
        return ("", "")
    }
    let sfx = if (ext.size > 0) { ext } else { "png" }
    let boundary = "----cspub" + randomHex(20)
    let blob = buildMultipart(boundary, Array<StrKV>(), "upfile", "image.${sfx}",
        "image/${sfx}", data)
    let builder = HttpRequestBuilder()
        .url(TOUTIAO_UPLOAD_API)
        .post()
        .header("Content-Type", "multipart/form-data; boundary=${boundary}")
        .body(blob)
    let hs = ArrayList<StrKV>()
    hs.add(StrKV("User-Agent", TOUTIAO_UA))
    hs.add(StrKV("Accept", "application/json, text/plain, */*"))
    hs.add(StrKV("Referer", TOUTIAO_SITE + "/profile_v3/graphic/publish"))
    hs.add(StrKV("Origin", TOUTIAO_SITE))
    hs.add(StrKV("Cookie", cookie))
    if (csrf.size > 0) {
        hs.add(StrKV("X-CSRFToken", csrf))
    }
    let req = applyHeaders(builder, hs.toArray()).build()
    let r = execRequest(req, insecure)
    dbg("toutiao upload_picture HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        return ("", "")
    }
    let root = try {
        JsonValue.fromStr(r.text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var state = ""
    var uri = ""
    var pubUrl = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            state = jsonScalar(root, "state")
            uri = jsonScalar(root, "origin_web_uri")
            if (uri.size == 0) {
                uri = jsonScalar(root, "original")
            }
            if (uri.size == 0) {
                uri = jsonScalar(root, "web_uri")
            }
            pubUrl = jsonScalar(root, "url")
            if (pubUrl.size == 0) {
                pubUrl = jsonScalar(root, "origin_web_url")
            }
        case _ => ()
    }
    if (state != "SUCCESS" || uri.size == 0) {
        return ("", "")
    }
    if (pubUrl.size == 0) {
        pubUrl = uri
    }
    return (uri, pubUrl)
}

/** 把正文里**所有**图片转存到头条 CDN 并回写 web_uri（外链也转，头条不认外链）。
 * 返回 (新正文, 成功数, 失败数)。失败的单张保留原链接并提示——但要在发布前告知用户
 * 「头条会因此整篇拒稿（7115）」，让它成为用户的决定而不是我们的静默。 */
public func rehostToutiaoImages(cookie: String, csrf: String, html: String,
    insecure: Bool): (String, Int64, Int64) {
    let urls = collectImgSrcs(html)
    if (urls.size == 0) {
        return (html, 0, 0)
    }
    let map = HashMap<String, String>()
    var ok: Int64 = 0
    var fail: Int64 = 0
    for (u in urls) {
        if (map.contains(u)) {
            continue
        }
        var data: Array<Byte> = Array<Byte>(0, repeat: 0)
        if (u.startsWith("http://") || u.startsWith("https://")) {
            data = try {
                downloadImage(u)
            } catch (e: Exception) {
                let _ = e
                Array<Byte>(0, repeat: 0)
            }
        } else {
            data = try {
                readImageBytes(u)
            } catch (e: Exception) {
                let _ = e
                Array<Byte>(0, repeat: 0)
            }
        }
        if (data.size == 0) {
            fail++
            println("⚠ 读不到图片（头条会拒稿 7115）：${u}")
            continue
        }
        let (uri, pubUrl) = uploadToutiaoImage(cookie, csrf, data, extOf(u), insecure)
        if (uri.size == 0) {
            fail++
            println("⚠ 转存头条 CDN 失败，保留原链接（头条会拒稿 7115）：${u}")
            continue
        }
        map.add(u, "<img src=\"${pubUrl}\" web_uri=\"${uri}\"")
        ok++
    }
    println("图片（头条 CDN）：成功 ${ok}，失败 ${fail}")
    return (rewriteHtmlImgs(html, map), ok, fail)
}

/** 头条号发文入口。publishNow=true → save=0 发布；false → save=1 存草稿（草稿也校验图片）。
 * 图片与别的平台相反：**外链也要转存**，否则整篇被拒 7115。 */
public func publishToToutiao(cookie: String, csrf: String, a: Article, publishNow: Bool,
    insecure: Bool, atomgitToken: String, atomgitRepo: String, atomgitBranch: String,
    atomgitDir: String): Int64 {

    // ① 标题先拦：5~30 字是头条后台的硬区间，超了在编辑器里就存不进去
    let chars = toutiaoTitleChars(a.title)
    if (!toutiaoTitleOk(a.title)) {
        println("错误：标题 ${chars} 字，头条要求 ${TOUTIAO_TITLE_MIN}~${TOUTIAO_TITLE_MAX} 字（按字符计）")
        println("提示：头条标题有加权字符规则，中英文混排请留余量，别卡在 ${TOUTIAO_TITLE_MAX} 字上限")
        println("当前标题：${a.title}")
        return 1
    }

    // ② 本地图先转外链（配了 AtomGit 才做），再统一进头条 CDN
    var body = a.body
    if (atomgitToken.size > 0) {
        let (b1, ok1, fail1) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        if (ok1 > 0 || fail1 > 0) {
            body = b1
            println("图片（AtomGit 外链）：成功 ${ok1}，失败 ${fail1}")
        }
    }

    let html = mdToHtml(body)
    let (html2, ok2, fail2) = rehostToutiaoImages(cookie, csrf, html, insecure)
    if (fail2 > 0) {
        println("警告：${fail2} 张图未能转存到头条 CDN。头条对非头条域名的图片会整篇拒稿（7115 图片uri非法），")
        println("      这次提交很可能被拒——建议先用 cookie-export 确认登录态、或删掉这几张图再发。")
    }
    let _ = ok2

    let saveFlag: Int64 = if (publishNow) { 0 } else { 1 }
    let payload = buildToutiaoArticleBody(a.title, html2, saveFlag, "")
    let builder = HttpRequestBuilder()
        .url(TOUTIAO_PUBLISH_API)
        .post()
        .header("Content-Type", "application/json")
        .body(payload)
    let hs = ArrayList<StrKV>()
    hs.add(StrKV("User-Agent", TOUTIAO_UA))
    hs.add(StrKV("Accept", "application/json, text/plain, */*"))
    hs.add(StrKV("Referer", TOUTIAO_SITE + "/profile_v3/graphic/publish"))
    hs.add(StrKV("Origin", TOUTIAO_SITE))
    hs.add(StrKV("Cookie", cookie))
    if (csrf.size > 0) {
        hs.add(StrKV("X-CSRFToken", csrf))
    }
    let req = applyHeaders(builder, hs.toArray()).build()
    let r = execRequest(req, insecure)
    dbg("toutiao publish HTTP ${r.status}：${r.text}")

    let (code, msg, pgcId) = parseToutiaoResp(r.text)
    if (r.status == 401 || r.status == 403 || toutiaoLoginCode(code)) {
        println("错误：头条号未登录${if (msg.size > 0) { "（${msg}）" } else { "" }}")
        println("提示：Cookie 过期——重新登录 mp.toutiao.com 后复制整串（须含 sessionid / tt_webid）")
        println("      X-CSRFToken 取自 cookie 里的 csrftoken，缺了这个头会被风控挡下")
        return 1
    }
    if (code != 0 || pgcId.size == 0 || pgcId == "0") {
        println("错误：头条提交失败（code ${code}${if (msg.size > 0) { "，${msg}" } else { "" }}）")
        println(r.text)
        if (trimAscii(r.text).contains("7115")) {
            println("提示：7115 = 图片 uri 非法。正文里有非头条域名的图，必须先转存头条 CDN")
        }
        return 1
    }

    if (publishNow) {
        println("头条号：发布成功，pgc_id ${pgcId}")
        println("文章地址：${toutiaoArticleUrl(pgcId)}")
        println("提示：头条有审核队列，发布成功不等于已公开；每日发文约 4 篇上限")
    } else {
        println("头条号：草稿已保存，pgc_id ${pgcId}")
        println("草稿地址：${toutiaoDraftUrl(pgcId)}（封面/分类/首发声明在后台补）")
    }
    return 0
}

