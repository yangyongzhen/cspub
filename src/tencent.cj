/** 腾讯云开发者社区发文：走社区编辑器自用的 RPC 网关——Cookie 鉴权、零签名、零浏览器。
 *
 * 接口形状（2026-11 真机抓包，见 docs/多平台发文调研.md §十一）：
 *   POST https://cloud.tencent.com/developer/services/ajax/column/article?action=<Action>&uin=<uin>
 *   体：{"action":"<Action>","payload":{...}}
 *   草稿：CreateArticleDraft -> {"code":0,"msg":"ok","data":{"articleId":0,"draftId":N}}
 *   发布：CreateArticle      -> 带 draftId / columnId 正式发文
 *   csrfCode 可选（实测不带也 code:0），只靠 Cookie 就够。
 *
 * 为什么必须重写：老的 POST /developer/api/article/addArticle 在前端 bundle（aw.js / common.js）
 * 里出现 **0 次**，是被前端淘汰的接口，打过去只会 400「参数错误」。真正的提交走上面这个 RPC。
 *
 * `content` 不是 HTML 也不是裸 JSON，是
 *   base64(urlencode(JSON.stringify(jsonpack.pack(rawDraft))))
 * rawDraft 是 Draft.js 的 RawDraftContentState。jsonpack 见 jsonpack.cj（与线上真包逐字节一致）。
 *
 * 硬约束：
 * ① **参数校验先于登录校验**：只发 `{}` 得到 400「参数错误」而不是 401「未登录」，别把 400 误读成 Cookie 失效。
 * ② 正文不少于 140 字是**发布**要求（草稿不卡：实测 6 个字符的草稿照样 code:0）。
 * ③ 发布必须有专栏：空专栏提交必失败（草稿阶段可以先空着）。
 */
package cspub

import std.collection.*
import std.convert.*
import stdx.encoding.base64.*
import stdx.encoding.json.*
import stdx.net.http.*

/** RPC 网关前缀：注意是 /developer/services/ajax/...，少一级就 501 Not Implemented */
public const TENCENT_RPC: String = "https://cloud.tencent.com/developer/services/ajax/column/article"
public const TENCENT_SITE: String = "https://cloud.tencent.com"
/** 默认专栏 id 149 = 技术。发布时文章必须归属专栏，空数组必失败。 */
public const TENCENT_DEFAULT_CLASSIFY: Int64 = 149
/** 官方明示的正文下限（字符数，按纯文本计）——只对**发布**生效，草稿不受此限 */
public const TENCENT_MIN_PLAIN: Int64 = 140
/** 文章来源类型。前端枚举 `{ORIGINAL:1, REPRODUCED:2, TRANSLATED:3}`（原创/转载/翻译外文）。
 * 传 0 建草稿能过，但**发布会回 -9996「抱歉，文章来源类型错误」**（真机踩过），故一律发 1=原创。 */
public const TENCENT_SOURCE_ORIGINAL: Int64 = 1
const TENCENT_UA: String = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

/** 登录态判定：skey 或 qcommunity_session 有一个就算（qcloud_uid 只是身份标识，不单独成立） */
public func tencentCookieHasSession(cookie: String): Bool {
    return cookieValue(cookie, "skey").size > 0 || cookieValue(cookie, "qcommunity_session").size > 0
}

/** 从 Cookie 取 uin：`uin=o100009199133` 前导 o 要去掉，RPC 的 query 用的是裸数字 */
public func tencentUin(cookie: String): String {
    var v = trimAscii(cookieValue(cookie, "uin"))
    if (v.size > 0 && (v[0] == UInt8(0x6F) || v[0] == UInt8(0x4F))) {
        v = v[1..]
    }
    if (v.size > 0) {
        return v
    }
    // 退而求其次：qcstats_ouin-<uin> 或 ownerUin
    let owner = trimAscii(cookieValue(cookie, "ownerUin"))
    var w = owner
    if (w.size > 0 && (w[0] == UInt8(0x6F) || w[0] == UInt8(0x4F))) {
        w = w[1..]
    }
    if (w.size > 0 && (w[w.size - 1] == UInt8(0x47) || w[w.size - 1] == UInt8(0x67))) {
        w = w[0..w.size - 1]
    }
    return w
}

/** RPC 地址（纯函数，单测覆盖）：uin 为空时省略该参数，别拼出 uin= 空值 */
public func tencentRpcUrl(action: String, uin: String): String {
    if (uin.size == 0) {
        return "${TENCENT_RPC}?action=${action}"
    }
    return "${TENCENT_RPC}?action=${action}&uin=${uin}"
}

/** 解析专栏 id 配置（逗号分隔）：非法项丢弃；全空或全非法时回落到默认专栏。 */
public func parseTencentClassifyIds(cfg: String): Array<Int64> {
    let list = ArrayList<Int64>()
    for (p in cfg.split(",", -1)) {
        let t = trimAscii(p)
        if (t.size == 0) {
            continue
        }
        let v = try {
            Int64.parse(t)
        } catch (e: Exception) {
            let _ = e
            Int64(0)
        }
        if (v > 0) {
            list.add(v)
        }
    }
    if (list.size == 0) {
        list.add(TENCENT_DEFAULT_CLASSIFY)
    }
    return list.toArray()
}

/** 解析文章标签 id（逗号分隔）。腾讯云发布**必须**至少一个标签：空 tagIds 实测回 -9993「请选择文章标签」，
 * 所以这里不给默认值——由发布前显式校验并提示，避免把"没配标签"伪装成服务端怪错。 */
public func parseTencentTagIds(cfg: String): Array<Int64> {
    let list = ArrayList<Int64>()
    for (p in cfg.split(",", -1)) {
        let t = trimAscii(p)
        if (t.size == 0) {
            continue
        }
        let v = try {
            Int64.parse(t)
        } catch (e: Exception) {
            let _ = e
            Int64(0)
        }
        if (v > 0) {
            list.add(v)
        }
    }
    return list.toArray()
}

/** encodeURIComponent 等价实现：保留 A-Za-z0-9 -_.!~*'()，其余按 UTF-8 字节 %XX 大写。
 * 与 jsonpack 的 _encode 是两件事——这里是整串再做一次 URL 编码（真包里的 %22 / %7C 就来自这一步）。 */
public func urlEncodeComponent(s: String): String {
    let b = s.toArray()
    let sb = StringBuilder()
    for (x in b) {
        if (urlSafeByte(x)) {
            sb.append(String.fromUtf8([x]))
        } else {
            sb.append("%")
            sb.append(hexDigit(x >> 4))
            sb.append(hexDigit(x & UInt8(0x0F)))
        }
    }
    return sb.toString()
}

func urlSafeByte(x: UInt8): Bool {
    if (x >= UInt8(0x41) && x <= UInt8(0x5A)) {
        return true // A-Z
    }
    if (x >= UInt8(0x61) && x <= UInt8(0x7A)) {
        return true // a-z
    }
    if (x >= UInt8(0x30) && x <= UInt8(0x39)) {
        return true // 0-9
    }
    // - _ . ! ~ * ' ( )
    return x == UInt8(0x2D) || x == UInt8(0x5F) || x == UInt8(0x2E) || x == UInt8(0x21) ||
        x == UInt8(0x7E) || x == UInt8(0x2A) || x == UInt8(0x27) || x == UInt8(0x28) ||
        x == UInt8(0x29)
}

func hexDigit(v: UInt8): String {
    let n = Int64(v)
    if (n < 10) {
        return String.fromUtf8([UInt8(48 + n)])
    }
    return String.fromUtf8([UInt8(55 + n)])
}

/** JSON 字符串字面量（JSON.stringify(str) 的等价）：packed 串里可能残留裸双引号与反斜杠 */
func jsonQuoteString(s: String): String {
    let b = s.toArray()
    let out = ArrayList<Byte>()
    out.add(UInt8(0x22))
    for (x in b) {
        if (x == UInt8(0x22)) {
            out.add(UInt8(0x5C))
            out.add(UInt8(0x22))
        } else if (x == UInt8(0x5C)) {
            out.add(UInt8(0x5C))
            out.add(UInt8(0x5C))
        } else if (x == UInt8(0x0A)) {
            out.add(UInt8(0x5C))
            out.add(UInt8(0x6E))
        } else if (x == UInt8(0x0D)) {
            out.add(UInt8(0x5C))
            out.add(UInt8(0x72))
        } else if (x == UInt8(0x09)) {
            out.add(UInt8(0x5C))
            out.add(UInt8(0x74))
        } else {
            out.add(x)
        }
    }
    out.add(UInt8(0x22))
    return String.fromUtf8(out.toArray())
}

/** 整条 content / plain 的最终编码：base64(urlencode(JSON.stringify(x))) */
public func tencentEncodeField(x: String): String {
    return toBase64String(urlEncodeComponent(jsonQuoteString(x)).toArray())
}

/** Markdown 里的块类型映射（Draft.js 的 type 字段） */
func draftBlockType(line: String): String {
    if (line.startsWith("### ")) {
        return "header-three"
    }
    if (line.startsWith("## ")) {
        return "header-two"
    }
    if (line.startsWith("# ")) {
        return "header-one"
    }
    if (line.startsWith("- ") || line.startsWith("* ")) {
        return "unordered-list-item"
    }
    return "unstyled"
}

/** 去掉行首的块标记，只留可见文本 */
func draftBlockText(line: String, btype: String): String {
    if (btype == "header-one") {
        return line[2..]
    }
    if (btype == "header-two") {
        return line[3..]
    }
    if (btype == "header-three") {
        return line[4..]
    }
    if (btype == "unordered-list-item") {
        return line[2..]
    }
    return line
}

/** 整行只有一个图片时返回 URL，否则空串 */
func draftImageLine(line: String): String {
    let t = trimAscii(line)
    if (!t.startsWith("![")) {
        return ""
    }
    let close = t.indexOf("](")
    if (let Some(i) <- close) {
        if (!t.endsWith(")")) {
            return ""
        }
        return t[i + 2..t.size - 1]
    }
    return ""
}

/** 造一个 Draft.js raw block（键序与线上真包一致：key,text,type,depth,inlineStyleRanges,entityRanges,data） */
func draftBlock(key: String, text: String, btype: String, entityKey: Int64): JpNode {
    let b = jpObj()
    jpPut(b, "key", jpStr(key))
    jpPut(b, "text", jpStr(text))
    jpPut(b, "type", jpStr(btype))
    jpPut(b, "depth", jpInt(0))
    jpPut(b, "inlineStyleRanges", jpArr())
    let ranges = jpArr()
    if (entityKey >= 0) {
        let r = jpObj()
        jpPut(r, "offset", jpInt(0))
        jpPut(r, "length", jpInt(1))
        jpPut(r, "key", jpInt(entityKey))
        jpAdd(ranges, r)
    }
    jpPut(b, "entityRanges", ranges)
    jpPut(b, "data", jpObj())
    return b
}

/** Markdown -> RawDraftContentState，同时给出纯文本。
 * 图片独占一行时转成 atomic block + IMAGE entity（Draft.js 标准形态）。 */
public func mdToDraftRoot(md: String): (JpNode, String) {
    let blocks = jpArr()
    let entityMap = jpObj()
    let plain = StringBuilder()
    var entityCount: Int64 = 0
    var blockCount: Int64 = 0
    var inCode = false
    for (rawLine in md.split("\n", -1)) {
        var line = rawLine
        if (line.endsWith("\r")) {
            line = line[0..line.size - 1]
        }
        let trimmed = trimAscii(line)
        if (trimmed.startsWith("```")) {
            inCode = !inCode
            continue
        }
        if (trimmed.size == 0) {
            continue
        }
        // 图片独占一行：atomic block + entityMap 登记
        let img = draftImageLine(trimmed)
        if (img.size > 0 && !inCode) {
            let key = "k${blockCount}"
            let entKey = "e${entityCount}"
            let ent = jpObj()
            jpPut(ent, "type", jpStr("IMAGE"))
            jpPut(ent, "mutability", jpStr("IMMUTABLE"))
            let data = jpObj()
            // 前端读的是 data.imageUrl（bundle 里 `n.data.imageUrl` 后直接 `.startsWith(...)`）；
            // 只给 Draft.js 官方惯例的 src 会让服务端拿到 undefined，发布时崩成
            // 500「Cannot read property 'startsWith' of undefined」。两个都给：imageUrl 给腾讯云，src 给 Draft.js 渲染。
            jpPut(data, "imageUrl", jpStr(img))
            jpPut(data, "src", jpStr(img))
            jpPut(ent, "data", data)
            jpPut(entityMap, entKey, ent)
            jpAdd(blocks, draftBlock(key, " ", "atomic", entityCount))
            entityCount++
            blockCount++
            continue
        }
        let btype = if (inCode) {
            "code-block"
        } else {
            draftBlockType(line)
        }
        let text = if (inCode) {
            line
        } else {
            draftBlockText(line, btype)
        }
        if (plain.size > 0) {
            plain.append("\n")
        }
        plain.append(text)
        jpAdd(blocks, draftBlock("k${blockCount}", text, btype, -1))
        blockCount++
    }
    let root = jpObj()
    jpPut(root, "blocks", blocks)
    jpPut(root, "entityMap", entityMap)
    return (root, plain.toString())
}

/** CreateArticleDraft / CreateArticle 的请求体（纯函数，单测覆盖） */
public func buildTencentRpcBody(action: String, payload: String): String {
    let o = JsonObject()
    o.put("action", JsonString(action))
    o.put("payload", JsonValue.fromStr(payload))
    return o.toJsonString()
}

/** 草稿 payload：字段集照抄线上真包，多一个少一个都可能被判参数错误 */
public func buildTencentDraftPayload(title: String, contentEnc: String, plainEnc: String,
    classifyIds: Array<Int64>, columnIds: Array<Int64>, keywords: Array<String>): String {
    let o = JsonObject()
    o.put("articleId", JsonInt(0))
    o.put("title", JsonString(title))
    o.put("content", JsonString(contentEnc))
    o.put("plain", JsonString(plainEnc))
    let cols = JsonArray()
    for (id in columnIds) {
        cols.add(JsonInt(id))
    }
    o.put("columnIds", cols)
    let tags = JsonArray()
    o.put("tagIds", tags)
    let kws = JsonArray()
    for (k in keywords) {
        kws.add(JsonString(k))
    }
    o.put("keywords", kws)
    o.put("sourceType", JsonInt(TENCENT_SOURCE_ORIGINAL))
    o.put("openComment", JsonInt(1))
    o.put("focusReadTotalAfterFollowAuthor", JsonInt(0))
    o.put("closeTextLink", JsonInt(0))
    let cls = JsonArray()
    for (id in classifyIds) {
        cls.add(JsonInt(id))
    }
    o.put("classifyIds", cls)
    return o.toJsonString()
}

/** 解析 RPC 响应：成功 {"code":0,...,"data":{"draftId":N}}，失败带 code/msg。
 * 注意 code 是 **JSON 数字**，必须按 Kind 取（见 AGENTS 踩坑 §1）。 */
public func parseTencentRpcResp(text: String): (Int64, String, String, String) {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var code: Int64 = 0
    var msg = ""
    var draftId = ""
    var articleId = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let c = jsonScalar(root, "code")
            if (c.size > 0) {
                code = tencentNum(c)
            }
            msg = jsonScalar(root, "msg")
            if (let Some(d) <- jsonObjField(root, "data")) {
                draftId = jsonScalar(d, "draftId")
                articleId = jsonScalar(d, "articleId")
            }
        case _ => ()
    }
    return (code, msg, draftId, articleId)
}

/** 数字兜底解析：非数字返回 0 */
func tencentNum(s: String): Int64 {
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

/** 已发布文章地址 */
public func tencentArticleUrl(id: String): String {
    return "${TENCENT_SITE}/developer/article/${id}"
}

/** 草稿编辑地址（存草稿后直接给用户点开核验，比只回一个 id 有用） */
public func tencentDraftUrl(id: String): String {
    return "${TENCENT_SITE}/developer/article/write?draftId=${id}"
}

/** 专栏 id 串的展示形态（日志用） */
func joinIds(ids: Array<Int64>): String {
    var out = ""
    for (id in ids) {
        if (out.size > 0) {
            out = out + ","
        }
        out = out + id.toString()
    }
    return out
}

/** 通用 RPC 发送（任意 namespace 都能用）：鉴权只要 Cookie，但 UA/Origin/Referer 缺一个
 * 就会吃到反爬挑战页（裸 curl 实测），所以四个头固定带齐。 */
func tencentRpcPost(cookie: String, url: String, action: String, payload: String,
    insecure: Bool): (Int64, String) {
    let body = buildTencentRpcBody(action, payload)
    let builder = HttpRequestBuilder()
        .url(url)
        .post()
        .header("Content-Type", "application/json")
        .body(body)
    let req = applyHeaders(builder, [
        StrKV("User-Agent", TENCENT_UA),
        StrKV("Accept", "*/*"),
        StrKV("Origin", TENCENT_SITE),
        StrKV("Referer", TENCENT_SITE + "/developer/article/write"),
        StrKV("Cookie", cookie),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("tencent ${action} HTTP ${r.status}：${r.text}")
    return (r.status, r.text)
}

/** 发一次 RPC，返回 (HTTP 状态, 响应体) */
func tencentRpcCall(cookie: String, uin: String, action: String, payload: String,
    insecure: Bool): (Int64, String) {
    return tencentRpcPost(cookie, tencentRpcUrl(action, uin), action, payload, insecure)
}

/** 图片 RPC 的 namespace 是 `image`，发文是 `column/article`——两者不能混用（混用回 501）。 */
public func tencentImageRpcUrl(action: String, uin: String): String {
    return TENCENT_SITE + "/developer/services/ajax/image?action=" + action + "&uin=" + uin
}

/** 从响应里取 data.url（SaveHttpImageCommon 成功时 {"code":0,"data":{"url":"https://developer.qcloudimg.com/..."}}） */
func tencentDataUrl(text: String): String {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        return ""
    }
    match (root.kind()) {
        case JsonKind.JsObject =>
            match (root.asObject().get("data")) {
                case Some(d) =>
                    match (d.kind()) {
                        case JsonKind.JsObject => return jsonScalar(d, "url")
                        case _ => return ""
                    }
                case None => return ""
            }
        case _ => return ""
    }
}

/** 把一张外链图转存到腾讯云自己的图床，成功返回 qcloudimg 直链，失败返回空串（调用方保留原链接）。
 *
 * **实测**：payload 只给 `url` 就行，`regionKey` / `bucketConfigKey` 不传同样 `code:0` 并返回
 * `data.url`——这两个参数在 bundle 里只是形参，本来也取不到真实常量，实测省掉不影响。
 * 转存结果可直连：HTTP 200 / 130318 bytes / PNG 1770x840。 */
public func saveTencentHttpImage(url: String, cookie: String, uin: String,
    insecure: Bool): String {
    if (url.size == 0 || cookie.size == 0 || uin.size == 0) {
        return ""
    }
    let o = JsonObject()
    o.put("url", JsonString(url))
    let body = buildTencentRpcBody("SaveHttpImageCommon", o.toJsonString())
    let builder = HttpRequestBuilder()
        .url(tencentImageRpcUrl("SaveHttpImageCommon", uin))
        .post()
        .header("Content-Type", "application/json")
        .body(body)
    let req = applyHeaders(builder, [
        StrKV("User-Agent", TENCENT_UA),
        StrKV("Accept", "*/*"),
        StrKV("Origin", TENCENT_SITE),
        StrKV("Referer", TENCENT_SITE + "/developer/article/write"),
        StrKV("Cookie", cookie),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("tencent SaveHttpImageCommon HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        return ""
    }
    let (code, msg, _, _) = parseTencentRpcResp(r.text)
    if (code != 0) {
        dbg("tencent SaveHttpImageCommon code=${code} msg=${msg}")
        return ""
    }
    return tencentDataUrl(r.text)
}

/** 把正文里的外链图逐张转存到腾讯云图床并改写链接。best-effort：失败保留原链接，不阻断发文。
 * 本地图不在此处理（要先把图变成公网 URL，那一步由 `rehostImagesAtomGit` 负责）。 */
public func rehostTencentImages(md: String, cookie: String, uin: String,
    insecure: Bool): (String, Int64, Int64) {
    let imgs = findExternalImages(md)
    if (imgs.size == 0) {
        return (md, 0, 0)
    }
    var out = md
    var ok: Int64 = 0
    var fail: Int64 = 0
    // 从后往前替换，避免前面的改写把后面的区间偏移搞乱
    var i = Int64(imgs.size) - 1
    while (i >= 0) {
        let ref = imgs[i]
        let src = ref.url
        i--
        if (!(src.startsWith("http://") || src.startsWith("https://"))) {
            continue
        }
        // 已经是腾讯云自家图床的图没必要再转一次
        if (src.contains("qcloudimg.com") || src.contains("cloud.tencent.com")) {
            continue
        }
        // 注意：这里是**腾讯云服务端**去抓这个 URL（SaveHttpImageCommon 只收 url），
        // 不走本机 downloadImage——所以 raw.gitcode.com 的 WAF 问题必须在这里换掉：
        // 实测 raw 端点本机 418、腾讯云侧同样取不到，换成 api.gitcode.com 等价端点才拿得到图。
        let fb = atomgitApiFallbackUrl(src)
        let fetchUrl = if (fb.size > 0) {
            fb
        } else {
            src
        }
        let url = saveTencentHttpImage(fetchUrl, cookie, uin, insecure)
        if (url.size == 0) {
            fail++
            println("⚠ 腾讯云图床转存失败，保留原链接：${src}")
            continue
        }
        out = out[0..ref.urlStart] + url + out[ref.urlEnd..out.size]
        ok++
    }
    return (out, ok, fail)
}

/** 腾讯云发文入口。publishNow=false 存草稿（可逆，有 draftId 回显）；true 则建草稿后转发布。 */
public func publishToTencent(cookie: String, classifyCfg: String, tagCfg: String, a: Article,
    publishNow: Bool,
    insecure: Bool, atomgitToken: String, atomgitRepo: String, atomgitBranch: String,
    atomgitDir: String): Int64 {

    let uin = tencentUin(cookie)
    if (uin.size == 0) {
        println("错误：Cookie 里取不到 uin，无法确定发文账号")
        println("提示：重新登录 cloud.tencent.com 后复制整串（须含 uin / skey / qcommunity_session）")
        return 1
    }

    // ① 图片：本地图转外链（best-effort，失败保留原引用）
    var body = a.body
    if (atomgitToken.size > 0) {
        let (b1, ok1, fail1) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        if (ok1 > 0 || fail1 > 0) {
            body = b1
            println("图片（AtomGit 外链）：成功 ${ok1}，失败 ${fail1}")
        }
    }

    // ② 外链图转腾讯云自家图床（SaveHttpImageCommon 实测只认 url，返回 qcloudimg 直链）
    let (b2, ok2, fail2) = rehostTencentImages(body, cookie, uin, insecure)
    if (ok2 > 0 || fail2 > 0) {
        body = b2
        println("图片（腾讯云图床）：成功 ${ok2}，失败 ${fail2}")
    }

    // ③ Markdown -> Draft.js raw -> jsonpack -> base64(urlencode(JSON))
    let (raw, plain) = mdToDraftRoot(body)
    let contentEnc = tencentEncodeField(jsonpackPack(raw))
    let plainEnc = tencentEncodeField(plain)
    let chars = utf8CharCount(plain)
    let classifyIds = parseTencentClassifyIds(classifyCfg)
    let tagIds = parseTencentTagIds(tagCfg)

    // 发布才卡 140 字下限；草稿实测 6 个字符也能存
    if (publishNow && chars < TENCENT_MIN_PLAIN) {
        println("错误：正文纯文本只有 ${chars} 字，腾讯云要求不少于 ${TENCENT_MIN_PLAIN} 字")
        println("提示：这是社区官方下限（发布时校验），补足正文再来")
        return 1
    }

    if (!publishNow) {
        println("腾讯云：存草稿")
    }
    println("  标题    ：${a.title}")
    println("  正文字数：${chars} 字")
    println("  专栏    ：${joinIds(classifyIds)}")

    let draftPayload = buildTencentDraftPayload(a.title, contentEnc, plainEnc, classifyIds,
        Array<Int64>(0, repeat: 0), Array<String>(0, repeat: ""))
    let (st, txt) = tencentRpcCall(cookie, uin, "CreateArticleDraft", draftPayload, insecure)
    let (code, msg, draftId, _) = parseTencentRpcResp(txt)
    if (st != 200 || code != 0 || draftId.size == 0) {
        if (st == 401 || code == 401) {
            println("错误：腾讯云未登录${if (msg.size > 0) { "（${msg}）" } else { "" }}")
            println("提示：Cookie 过期——重新登录 cloud.tencent.com 后复制整串")
            return 1
        }
        println("错误：腾讯云草稿创建失败（HTTP ${st}，code ${code}）")
        if (msg.size > 0) {
            println("  接口信息：${msg}")
        }
        println("  排查：content 编码错会回 400「文章草稿创建失败」——那是 jsonpack 串不对，不是登录问题")
        println(txt)
        return 1
    }
    println("草稿已保存：draftId ${draftId}")
    println("编辑地址：${tencentDraftUrl(draftId)}")

    if (!publishNow) {
        println("（草稿可逆，确认无误后加 --live 正式发布）")
        return 0
    }

    // ④ 转正式发布：草稿 -> CreateArticle（字段组取自前端 bundle 真实调用）
    if (tagIds.size == 0) {
        println("错误：腾讯云发布必须至少一个文章标签（空 tagIds 服务端回 -9993「请选择文章标签」）")
        println("提示：CSPUB_TENCENT_TAG_IDS=10757,17183（专栏标签 id，逗号分隔）")
        println("  草稿已保存，可手动发布：${tencentDraftUrl(draftId)}")
        return 1
    }
    let pubPayload = buildTencentPublishPayload(a.title, contentEnc, plainEnc, draftId,
        classifyIds[0], Array<String>(0, repeat: ""), tagIds)
    // 排查用：CSPUB_DEBUG=1 时把真实发布 payload 打到 stderr（含 base64 content，别在正式环境常开）
    dbg("tencent CreateArticle payload: " + pubPayload)
    let (st2, txt2) = tencentRpcCall(cookie, uin, "CreateArticle", pubPayload, insecure)
    let (code2, msg2, _, articleId2) = parseTencentRpcResp(txt2)
    if (st2 != 200 || code2 != 0) {
        println("错误：腾讯云发布失败（HTTP ${st2}，code ${code2}）")
        if (msg2.size > 0) {
            println("  接口信息：${msg2}")
        }
        println("  草稿仍在，可手动发布：${tencentDraftUrl(draftId)}")
        println(txt2)
        return 1
    }
    let aid = if (articleId2.size > 0) {
        articleId2
    } else {
        draftId
    }
    println("腾讯云：发布成功，articleId ${aid}")
    println("文章地址：${tencentArticleUrl(aid)}")
    return 0
}

/** CreateArticle payload：字段组取自前端 bundle 的真实调用（`d.call("CreateArticle", m)`，m 含
 * columnId / columnIds / draftId / title / content / plain / sourceType / sourceDetail / tagIds /
 * picture / keywords —— **没有** classifyIds，也没有 articleId），并用探测请求验证过形状：
 * 空 payload 回 500「内容解码失败」，补齐这 11 个字段后回 -9997「文章内容不能少于 140 字」，
 * 说明 content/plain 解码与字段校验都过了，只剩业务规则。 */
public func buildTencentPublishPayload(title: String, contentEnc: String, plainEnc: String,
    draftId: String, columnId: Int64, keywords: Array<String>, tagIds: Array<Int64>): String {
    let o = JsonObject()
    o.put("columnId", JsonInt(columnId))
    let cols = JsonArray()
    cols.add(JsonInt(columnId))
    o.put("columnIds", cols)
    o.put("draftId", JsonInt(tencentNum(draftId)))
    o.put("title", JsonString(title))
    o.put("content", JsonString(contentEnc))
    o.put("plain", JsonString(plainEnc))
    o.put("sourceType", JsonInt(TENCENT_SOURCE_ORIGINAL))
    // 原创**不能**带 sourceDetail：实测传空串会被判 400「参数错误」，去掉该字段后参数校验才通过
    // （同样的 payload 只去掉 sourceDetail 就变成业务码 300031/-9993，说明校验过了）。
    // 转载/翻译才需要 sourceDetail，届时非空才 put。
    // tagIds 同理不能空：空数组回 -9993「请选择文章标签」，由调用方发布前校验。
    let tags = JsonArray()
    for (t in tagIds) {
        tags.add(JsonInt(t))
    }
    o.put("tagIds", tags)
    o.put("picture", JsonString(""))
    let kws = JsonArray()
    for (k in keywords) {
        kws.add(JsonString(k))
    }
    o.put("keywords", kws)
    return o.toJsonString()
}

/** 专栏/标签 RPC 的 namespace 是 `column/column`（发文是 column/article、图片是 image）：
 * 挂错 namespace 直接 501——实测 FetchJoinedColumnList / FetchColumnTags 必须走这个。 */
public func tencentColumnRpcUrl(action: String, uin: String): String {
    let base = TENCENT_SITE + "/developer/services/ajax/column/column"
    if (uin.size == 0) {
        return "${base}?action=${action}"
    }
    return "${base}?action=${action}&uin=${uin}"
}

/** 从 RPC 响应里取业务码（纯函数）：签名响应里的 code 是 **JSON 数字**，
 * 用只认字符串的 jsonStr 会取到空串，一律走 jsonScalar 按 Kind 取。 */
public func tencentRespCode(text: String): String {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        return ""
    }
    match (root.kind()) {
        case JsonKind.JsObject => return jsonScalar(root, "code")
        case _ => return ""
    }
}

/** 是否是 JSON 对象（避免对枚举直接用 !=，本机 1.2.0 上枚举比较写法各异） */
func jsonIsObject(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsObject => return true
        case _ => return false
    }
}

/** 取响应里的条目数组（纯函数，单测覆盖）：data 可能是数组本身，也可能包一层
 * {list|items|columns|tags|result|records:[...]}；顶层直接带数组的也认。 */
public func tencentItemArray(text: String): Array<JsonValue> {
    let out = ArrayList<JsonValue>()
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        return out.toArray()
    }
    var node = root
    match (root.kind()) {
        case JsonKind.JsObject =>
            match (root.asObject().get("data")) {
                case Some(d) => node = d
                case None => ()
            }
        case _ => ()
    }
    tencentCollectItems(node, out)
    return out.toArray()
}

/** 递归收一层容器里的条目：数组全收；对象则找常见键再下一层 */
func tencentCollectItems(node: JsonValue, out: ArrayList<JsonValue>): Unit {
    match (node.kind()) {
        case JsonKind.JsArray =>
            let arr = node.asArray()
            var i: Int64 = 0
            while (i < arr.size()) {
                match (arr.get(i)) {
                    case Some(item) => out.add(item)
                    case None => ()
                }
                i++
            }
        case JsonKind.JsObject =>
            let obj = node.asObject()
            for (k in ["list", "items", "columns", "tags", "tagList", "result", "records"]) {
                match (obj.get(k)) {
                    case Some(v) =>
                        match (v.kind()) {
                            case JsonKind.JsArray => tencentCollectItems(v, out)
                            case _ => ()
                        }
                    case None => ()
                }
            }
        case _ => ()
    }
}

/** 按候选键顺序取第一个非空标量（不同 RPC 版本字段名不一致） */
func tencentFirstScalar(obj: JsonValue, keys: Array<String>): String {
    for (k in keys) {
        let v = jsonScalar(obj, k)
        if (v.size > 0) {
            return v
        }
    }
    return ""
}

/** 解析专栏列表 → (id, 名称)。纯函数，单测覆盖。 */
public func parseTencentColumns(text: String): Array<(String, String)> {
    let out = ArrayList<(String, String)>()
    for (item in tencentItemArray(text)) {
        if (!jsonIsObject(item)) {
            continue
        }
        let id = tencentFirstScalar(item, ["columnId", "classifyId", "id"])
        if (id.size == 0) {
            continue
        }
        let nm = tencentFirstScalar(item, ["columnName", "name", "title", "classifyName"])
        out.add((id, nm))
    }
    return out.toArray()
}

/** 解析标签列表 → (id, 名称)。纯函数，单测覆盖。 */
public func parseTencentTags(text: String): Array<(String, String)> {
    let out = ArrayList<(String, String)>()
    for (item in tencentItemArray(text)) {
        if (!jsonIsObject(item)) {
            continue
        }
        let id = tencentFirstScalar(item, ["tagId", "tag_id", "id"])
        if (id.size == 0) {
            continue
        }
        let nm = tencentFirstScalar(item, ["tagName", "tag_name", "name", "title", "tag"])
        out.add((id, nm))
    }
    return out.toArray()
}

/** 命令：tags —— 查本账号已加入的专栏与可用标签，直接给出可复制的环境变量。
 * 发布前跑这个，比撞 300031（专栏未加入）/ -9993（标签空）/ 9003（columnId 缺失）再回头排查省事。 */
public func cmdTencentTags(cookie: String, insecure: Bool): Int64 {
    let uin = tencentUin(cookie)
    if (uin.size == 0) {
        println("错误：Cookie 里取不到 uin，无法确定账号")
        println("提示：重新登录 cloud.tencent.com 后复制整串（须含 uin / skey）")
        return 1
    }
    let (st, body) = tencentRpcPost(cookie, tencentColumnRpcUrl("FetchJoinedColumnList", uin),
        "FetchJoinedColumnList", "{}", insecure)
    let code = tencentRespCode(body)
    if (st != 200 || code != "0") {
        println("错误：查询已加入专栏失败（HTTP ${st}，code ${code}）")
        println(body)
        println("提示：501 = namespace 挂错；业务码非 0 多半是登录态失效")
        return 1
    }
    let cols = parseTencentColumns(body)
    if (cols.size == 0) {
        println("未查到已加入的专栏——未加入专栏时发布会被拒（300031）")
        println("原始响应：${body}")
        return 1
    }
    println("账号 uin：${uin}")
    println("已加入专栏（${cols.size} 个）：")
    for (c in cols) {
        println("  [${c[0]}] ${c[1]}")
    }
    println("")
    // 标签挂在专栏下：逐个查会打一串请求，先探前 5 个
    var suggested = ""
    var idx: Int64 = 0
    while (idx < cols.size && idx < 5) {
        let (cid, cname) = cols[idx]
        idx++
        let (ts, tb) = tencentRpcPost(cookie, tencentColumnRpcUrl("FetchColumnTags", uin),
            "FetchColumnTags", "{\"columnId\":${cid}}", insecure)
        let tc = tencentRespCode(tb)
        if (ts != 200 || tc != "0") {
            println("  专栏 ${cid}（${cname}）：标签查询失败（code ${tc}）")
            continue
        }
        let tags = parseTencentTags(tb)
        println("  专栏 ${cid}（${cname}）：共 ${tags.size} 个标签")
        let shown = if (tags.size > 12) { 12 } else { tags.size }
        var line = ""
        var j: Int64 = 0
        while (j < shown) {
            if (line.size > 0) {
                line = line + "  "
            }
            line = line + "[${tags[j][0]}] ${tags[j][1]}"
            j++
        }
        if (line.size > 0) {
            println("    " + line)
            if (tags.size > shown) {
                println("    …（其余 ${tags.size - shown} 个省略）")
            }
        }
        if (suggested.size == 0 && tags.size > 0) {
            let n = if (tags.size > 2) { 2 } else { tags.size }
            var s = ""
            var k: Int64 = 0
            while (k < n) {
                if (s.size > 0) {
                    s = s + ","
                }
                s = s + tags[k][0]
                k++
            }
            suggested = "export CSPUB_TENCENT_CLASSIFY_IDS=${cid}\nexport CSPUB_TENCENT_TAG_IDS=${s}"
        }
    }
    if (suggested.size > 0) {
        println("")
        println("建议配置（覆盖默认专栏 149，避免 300031）：")
        println(suggested)
    }
    return 0
}
