/** 开源中国（OSCHINA）博客发文：走站点编辑器自用的 apiv1 接口，Cookie 鉴权，纯 HTTP 零浏览器。
 *
 * 探明的接口形状（2026-11-05，从 www.oschina.net 编辑器 JS bundle 反查 + 实测）：
 *   鉴权：Cookie 里的 oscid（整串 Cookie 透传即可，须带 Referer: https://www.oschina.net/）
 *   GET  https://apiv1.oschina.net/oschinapi/user/myDetails              → result.userId
 *   GET  https://apiv1.oschina.net/oschinapi/blog_catalog/list_by_user   → 分类（catalog id）
 *   POST https://apiv1.oschina.net/oschinapi/api/draft/save_draft        → 草稿，result.id
 *   POST https://apiv1.oschina.net/oschinapi/blog/web/add               → 发布，result = 博客 id
 *   POST https://apiv1.oschina.net/oschinapi/upload/img                → 自带图床，multipart 字段 file，result 即直链
 * 正文 contentType：0 = 富文本，1 = Markdown。Markdown 原文提交，**不要预渲染成 HTML**。
 * 成功判据：code == 200（并 success == true）；错误结构里 message 带中文原因。
 *
 * 与官方 OpenAPI 的区别：`/action/openapi/blog_pub` 要先注册应用拿 client_id/secret 再走
 * oauth2 换 access_token（授权范围还要 password），个人自用不现实；站点自用 apiv1 用登录
 * Cookie 直通，与浏览器编辑器是同一套请求。
 */
package cspub

import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

public const OSCHINA_API: String = "https://apiv1.oschina.net/oschinapi"
public const OSCHINA_SITE: String = "https://www.oschina.net"
const OSCHINA_UA: String = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

/** 登录态判定：Cookie 里要有 oscid（其它字段无关） */
public func oschinaCookieHasSession(cookie: String): Bool {
    return cookieValue(cookie, "oscid").size > 0
}

/** 数字字段兜底解析：配置里是字符串，接口要数字；非法值返回 0（分类 0 = 账号默认分类） */
public func oschinaNum(s: String): Int64 {
    let t = trimAscii(s)
    if (t.size == 0) {
        return 0
    }
    let v = try { Int64.parse(t) } catch (e: Exception) {
        let _ = e
        Int64(0)
    }
    return v
}

/** 草稿请求体（纯函数）：/api/draft/save_draft。Markdown 模式 contentType=1。 */
public func buildOschinaDraftBody(title: String, content: String, userId: String, catalog: String,
    privacy: Bool, disableComment: Bool): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    o.put("user", JsonInt(oschinaNum(userId)))
    o.put("content", JsonString(content))
    o.put("contentType", JsonInt(1))
    o.put("catalog", JsonInt(oschinaNum(catalog)))
    o.put("originUrl", JsonString(""))
    o.put("privacy", JsonBool(privacy))
    o.put("disableComment", JsonBool(disableComment))
    return o.toJsonString()
}

/** 发布请求体（纯函数）：/blog/web/add。type 1=原创 4=转载；draft 0 表示正式发布。 */
public func buildOschinaPublishBody(title: String, content: String, userId: String, catalog: String,
    originUrl: String, privacy: Bool, disableComment: Bool): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    o.put("user", JsonInt(oschinaNum(userId)))
    o.put("content", JsonString(content))
    o.put("contentType", JsonInt(1))
    // 转载：正文有 origin_url 就按转载提交（type=4），否则原创（type=1）
    o.put("type", JsonString(if (originUrl.size > 0) { "4" } else { "1" }))
    o.put("originUrl", JsonString(originUrl))
    o.put("catalog", JsonInt(oschinaNum(catalog)))
    o.put("privacy", JsonBool(privacy))
    o.put("disableComment", JsonBool(disableComment))
    o.put("draft", JsonInt(0))
    o.put("isAiRelated", JsonBool(false))
    return o.toJsonString()
}

/** 解析 apiv1 统一响应：返回 (code, message, id)。
 * result 可能是对象（草稿：result.id）也可能是标量（发布：result 就是博客 id）。 */
public func parseOschinaResp(text: String): (Int64, String, String) {
    let root = try { JsonValue.fromStr(text) } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var code: Int64 = -1
    var msg = ""
    var id = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let o = root.asObject()
            let c = jsonScalar(root, "code")
            if (c.size > 0) {
                code = oschinaNum(c)
            }
            msg = jsonScalar(root, "message")
            if (let Some(r) <- o.get("result")) {
                match (r.kind()) {
                    case JsonKind.JsObject =>
                        id = jsonScalar(r, "id")
                    case JsonKind.JsInt =>
                        id = jsonScalar(root, "result")
                    case JsonKind.JsString =>
                        id = jsonScalar(root, "result")
                    case _ => ()
                }
            }
        case _ => ()
    }
    return (code, msg, id)
}

/** 从 blog_catalog/list_by_user 响应里挑分类：配置优先；否则按名称匹配；否则取第一个。
 * 开源中国的分类名默认是「工作日志/日常记录/转贴的文章」，front-matter 的 categories 可覆盖。 */
public func pickOschinaCatalog(respText: String, wantName: String, configuredId: String): String {
    if (trimAscii(configuredId).size > 0) {
        return trimAscii(configuredId)
    }
    let root = try { JsonValue.fromStr(respText) } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    match (root.kind()) {
        case JsonKind.JsObject =>
            if (let Some(r) <- root.asObject().get("result")) {
                match (r.kind()) {
                    case JsonKind.JsArray =>
                        let arr = r.asArray()
                        var first = ""
                        var i = 0
                        while (i < arr.size()) {
                            if (let Some(item) <- arr.get(i)) {
                                match (item.kind()) {
                                    case JsonKind.JsObject =>
                                        let id = jsonScalar(item, "id")
                                        let name = jsonScalar(item, "name")
                                        if (first.size == 0) {
                                            first = id
                                        }
                                        if (wantName.size > 0 && name == wantName) {
                                            return id
                                        }
                                    case _ => ()
                                }
                            }
                            i++
                        }
                        return first
                    case _ => ()
                }
            }
        case _ => ()
    }
    return ""
}

/** 标题兜底：front-matter 没写标题时取正文首个非空行（剥掉行首 Markdown 标记），再兜底「无标题草稿」。
 * 不能用 stripMarkdown：它把多行拼成一行，会把整篇正文前半段当成标题。 */
public func oschinaTitleOrDefault(title: String, content: String): String {
    let t = trimAscii(title)
    if (t.size > 0) {
        return t
    }
    var inCode = false
    for (line in content.split("\n", -1)) {
        let w = trimAscii(line)
        if (w.startsWith("```")) {
            inCode = !inCode
            continue
        }
        if (inCode || w.size == 0) {
            continue
        }
        var s = w
        while (s.size > 0 && (s.startsWith("#") || s.startsWith(">") || s.startsWith("- ") ||
            s.startsWith("* "))) {
            s = trimAscii(s[1..s.size])
        }
        if (s.size > 0) {
            return truncateUtf8(s, 60)
        }
    }
    return "无标题草稿"
}

/** 已发布文章地址（草稿没有稳定 URL，只回显 id）。
 * 实测 /u/{userId}/blog/{id} 是服务端 404，SPA 路由是 /blog/{id}；
 * 注意该路由对不存在的 id 也回 200 + 同一个 SPA 外壳，判「文章是否可见」只能靠浏览器渲染或 blog/detail 接口。 */
public func oschinaArticleUrl(id: String): String {
    return "${OSCHINA_SITE}/blog/${id}"
}

func oschinaGet(path: String, cookie: String, insecure: Bool): HttpResp {
    let builder = HttpRequestBuilder()
        .url(OSCHINA_API + path)
        .get()
    let req = applyHeaders(builder, [
        StrKV("User-Agent", OSCHINA_UA),
        StrKV("Accept", "application/json, text/plain, */*"),
        StrKV("Referer", OSCHINA_SITE + "/"),
        StrKV("Cookie", cookie),
    ]).build()
    return execRequest(req, insecure)
}

func oschinaPostJson(path: String, cookie: String, body: String, insecure: Bool): HttpResp {
    let builder = HttpRequestBuilder()
        .url(OSCHINA_API + path)
        .post()
        .header("Content-Type", "application/json")
        .body(body)
    let req = applyHeaders(builder, [
        StrKV("User-Agent", OSCHINA_UA),
        StrKV("Accept", "application/json, text/plain, */*"),
        StrKV("Referer", OSCHINA_SITE + "/"),
        StrKV("Origin", OSCHINA_SITE),
        StrKV("Cookie", cookie),
    ]).build()
    return execRequest(req, insecure)
}

/** 上传一张图到开源中国自带图床：POST /upload/img（multipart，字段名 file），返回直链；失败返回空串。
 * 实测 2MB 图单请求即可（分片接口 /upload/init 是给大文件用的，图片用不上）。
 * 返回的直链形如 https://oscimg.oschina.net//null/up-<md5>.png：中间//null/ 段是服务端未用的桶位，
 * 链接本身有效（浏览器 UA 取回 200 + 字节一致；裸 curl 会被 CDN 403，不是链接失效）。 */
public func uploadOschinaImage(cookie: String, data: Array<Byte>, ext: String, insecure: Bool): String {
    if (data.size == 0) {
        return ""
    }
    let boundary = "----cspub" + randomHex(20)
    let body = buildMultipart(boundary, Array<StrKV>(), "file", "image.${ext}", "image/${ext}", data)
    let builder = HttpRequestBuilder()
        .url(OSCHINA_API + "/upload/img")
        .post()
        .header("Content-Type", "multipart/form-data; boundary=${boundary}")
        .body(body)
    let req = applyHeaders(builder, [
        StrKV("User-Agent", OSCHINA_UA),
        StrKV("Accept", "application/json, text/plain, */*"),
        StrKV("Referer", OSCHINA_SITE + "/"),
        StrKV("Origin", OSCHINA_SITE),
        StrKV("Cookie", cookie),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("oschina /upload/img HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        return ""
    }
    let (code, _, url) = parseOschinaResp(r.text)
    if (code != 200 || !url.startsWith("http")) {
        return ""
    }
    return url
}

/** 把正文里的本地图批量传到开源中国自带图床并回写直链。
 * 返回 (新正文, 成功数, 失败数)；外链原样保留，失败保留原引用（best-effort，交给调用方兜底）。 */
public func rehostImagesOschina(md: String, cookie: String, insecure: Bool): (String, Int64, Int64) {
    let imgs = findExternalImages(md)
    var ok: Int64 = 0
    var fail: Int64 = 0
    var out = md
    var i = Int64(imgs.size) - 1
    while (i >= 0) {
        let ref = imgs[i]
        let src = ref.url
        i--
        if (src.startsWith("http://") || src.startsWith("https://") || src.startsWith("data:")) {
            continue
        }
        let data = try { readImageBytes(src) } catch (e: Exception) {
            let _ = e
            Array<Byte>(0, repeat: 0)
        }
        if (data.size == 0) {
            fail++
            println("⚠ 读不到本地图片，保留原引用：${src}")
            continue
        }
        let url = uploadOschinaImage(cookie, data, extOf(src), insecure)
        if (url.size == 0) {
            fail++
            println("⚠ 开源中国图床上传失败，保留原引用：${src}")
            continue
        }
        out = out[0..ref.urlStart] + url + out[ref.urlEnd..out.size]
        ok++
    }
    return (out, ok, fail)
}

/** 取当前登录用户的 userId（文章 URL 与请求体的 user 字段都要它） */
public func fetchOschinaUserId(cookie: String, insecure: Bool): String {
    let r = oschinaGet("/user/myDetails", cookie, insecure)
    if (r.status != 200) {
        println("错误：开源中国 user/myDetails 返回 HTTP ${r.status}")
        println(r.text)
        return ""
    }
    let (code, msg, _) = parseOschinaResp(r.text)
    if (code != 200) {
        println("错误：开源中国未登录或会话失效（code ${code}${if (msg.size > 0) { "：" + msg } else { "" }}）")
        println("提示：重新登录 oschina.net 后复制 Cookie 整串（须含 oscid）")
        return ""
    }
    // userId 在 result.userId 里，先取 result 再取字段
    let root = try { JsonValue.fromStr(r.text) } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    if (let Some(res) <- jsonObjField(root, "result")) {
        return jsonScalar(res, "userId")
    }
    return ""
}

/** 提交正文：publishNow=false 存草稿（/api/draft/save_draft），true 正式发布（/blog/web/add）。
 * 成功打印 id 并返回 0；失败返回 1。 */
public func submitOschina(cookie: String, userId: String, title: String, body: String,
    catalog: String, originUrl: String, publishNow: Bool, privacy: Bool, disableComment: Bool,
    insecure: Bool): Int64 {
    let path = if (publishNow) { "/blog/web/add" } else { "/api/draft/save_draft" }
    let payload = if (publishNow) {
        buildOschinaPublishBody(title, body, userId, catalog, originUrl, privacy, disableComment)
    } else {
        buildOschinaDraftBody(title, body, userId, catalog, privacy, disableComment)
    }
    let r = oschinaPostJson(path, cookie, payload, insecure)
    dbg("oschina ${path} HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        println("错误：开源中国返回 HTTP ${r.status}")
        println(r.text)
        if (r.status == 403) {
            println("提示：403 多为请求头缺 Referer/Origin 或 Cookie 失效")
        }
        return 1
    }
    let (code, msg, id) = parseOschinaResp(r.text)
    if (code != 200 || id.size == 0) {
        println("错误：开源中国提交失败（code ${code}）：${msg}")
        println(r.text)
        return 1
    }
    if (publishNow) {
        println("开源中国：发布成功，博客 id ${id}")
        println("文章地址：${oschinaArticleUrl(id)}")
    } else {
        println("开源中国：草稿已保存，id ${id}")
        println("草稿箱：${OSCHINA_SITE}/blog/drafts")
    }
    return 0
}

/** 开源中国发文入口。默认存草稿；publishNow=true 才正式发布。
 * 图片：外链原样保留（开源中国认外链）；本地图在配了 AtomGit 令牌时上传成外链，否则保留原引用并提示
 * （best-effort，不阻断发文）。 */
public func publishToOschina(cookie: String, userIdCfg: String, catalogCfg: String, privacy: Bool,
    a: Article, publishNow: Bool, insecure: Bool, atomgitToken: String, atomgitRepo: String,
    atomgitBranch: String, atomgitDir: String): Int64 {

    let mode = if (publishNow) { "publish" } else { "draft" }
    println("开源中国：提交（${mode}）…")

    // ① 用户 id：配置优先，否则问接口要（草稿/发布请求体与文章 URL 都依赖它）
    var userId = userIdCfg
    if (userId.size == 0) {
        userId = fetchOschinaUserId(cookie, insecure)
        if (userId.size == 0) {
            return 1
        }
    }

    // ② 分类：配置 > front-matter 分类名匹配 > 账号第一个分类
    let catResp = oschinaGet("/blog_catalog/list_by_user", cookie, insecure)
    if (catResp.status != 200) {
        println("错误：开源中国分类列表返回 HTTP ${catResp.status}")
        println(catResp.text)
        return 1
    }
    let wantCat = trimAscii(a.categories.split(",", -1)[0])
    var catalog = pickOschinaCatalog(catResp.text, wantCat, catalogCfg)
    if (catalog.size == 0) {
        println("错误：没取到博客分类（catalog）。可在配置里指定 CSPUB_OSCHINA_CATALOG")
        println(catResp.text)
        return 1
    }
    println("分类 catalog：${catalog}${if (wantCat.size > 0) { "（front-matter：${wantCat}）" } else { "" }}")

    // ③ 正文图片：优先平台自带图床（自带 CDN，无外部依赖）；失败的本地图再用 AtomGit 外链兜底
    var body = a.body
    let (b1, ok1, fail1) = rehostImagesOschina(body, cookie, insecure)
    body = b1
    if (ok1 > 0 || fail1 > 0) {
        println("图片（oschina 图床）：成功 ${ok1}，失败 ${fail1}")
    }
    if (fail1 > 0 && atomgitToken.size > 0) {
        let (b2, ok2, fail2) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        body = b2
        println("图片（AtomGit 兜底）：成功 ${ok2}，失败 ${fail2}")
    }
    if (hasLocalImages(body)) {
        println("⚠ 仍有本地图片没转存成功，开源中国页面上会显示死链")
    }

    let title = oschinaTitleOrDefault(a.title, body)
    return submitOschina(cookie, userId, title, body, catalog, trimAscii(a.originUrl),
        publishNow, privacy, false, insecure)
}
