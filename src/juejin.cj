/** 掘金发文客户端：Cookie 鉴权两步流（写接口实测无需反爬签名，社区 2026-05 实测配方）。
 * ①POST /content_api/v1/article_draft/create（edit_type=10 Markdown 模式）→ draft_id
 * ②POST /content_api/v1/article/publish {draft_id} → article_id → juejin.cn/post/<id>
 * 坑点（社区实测）：brief_content 强制 50-100 字；category_id 必须字符串；
 * 判成功只看 err_no==0（err_msg 可能恒为 "success"）。
 * 分类/标签用 ID（config 里配 category_id 与 tag_ids；标签名→ID 需查询接口，暂不自动映射）。 */
package cspub

import std.collection.*
import std.convert.*
import std.fs.*
import std.process.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*
import stdx.encoding.json.*
import stdx.net.http.*

public const JUEJIN_API: String = "https://api.juejin.cn"
public const JUEJIN_AID: String = "2608"

/** 组建草稿请求体（纯函数，供测试对账）。categoryId/tagIds 传空串/空数组则省略字段。 */
public func buildJuejinDraftBody(title: String, markContent: String, brief: String,
    categoryId: String, tagIds: Array<String>, coverImage: String): String {
    let body = JsonObject()
    body.put("title", JsonString(title))
    body.put("mark_content", JsonString(markContent))
    body.put("brief_content", JsonString(brief))
    if (categoryId.size > 0) {
        body.put("category_id", JsonString(categoryId))
    }
    if (tagIds.size > 0) {
        let arr = JsonArray()
        for (t in tagIds) {
            arr.add(JsonString(t))
        }
        body.put("tag_ids", arr)
    }
    body.put("edit_type", JsonInt(10))
    body.put("cover_image", JsonString(coverImage))
    body.put("html_content", JsonString("deprecated"))
    return body.toJsonString()
}

/** 组发布请求体（纯函数） */
public func buildJuejinPublishBody(draftId: String): String {
    let body = JsonObject()
    body.put("draft_id", JsonString(draftId))
    body.put("sync_to_org", JsonBool(false))
    body.put("column_ids", JsonArray())
    body.put("theme_ids", JsonArray())
    return body.toJsonString()
}

/** 摘要规整：掘金硬性要求 50-100 字。front-matter desc 优先；不足 50 字时按社区配方
 * 从正文剥出的文本循环补齐（补齐内容取自正文自身，避免无意义填充）。 */
public func normalizeJuejinBrief(desc: String, body: String): String {
    var brief = trimAscii(desc)
    let filler = truncateUtf8(stripMarkdown(body), 300)
    if (brief.size == 0) {
        brief = filler
    }
    var guardCount = 0
    while (utf8CharCount(brief) < 50 && filler.size > 0 && guardCount < 20) {
        brief = brief + filler
        guardCount++
    }
    return truncateUtf8(brief, 300)
}

/** UTF-8 字符数（按首字节判界，踩坑 2） */
public func utf8CharCount(s: String): Int64 {
    let b = s.toArray()
    var n: Int64 = 0
    for (c in b) {
        if ((c & UInt8(0xC0)) != UInt8(0x80)) {
            n++
        }
    }
    return n
}

/** 从掘金响应取 err_no / err_msg / data 下某字符串字段（id / article_id / draft_id） */
public func parseJuejinResp(respText: String, dataKey: String): (Int64, String, String) {
    var errNo: Int64 = -1
    var errMsg = ""
    var dataVal = ""
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                let obj = root.asObject()
                if (let Some(v) <- obj.get("err_no")) {
                    match (v.kind()) {
                        case JsonKind.JsInt => errNo = v.asInt().getValue()
                        case _ => ()
                    }
                }
                if (let Some(v) <- obj.get("err_msg")) {
                    match (v.kind()) {
                        case JsonKind.JsString => errMsg = v.asString().getValue()
                        case _ => ()
                    }
                }
                if (let Some(d) <- obj.get("data")) {
                    match (d.kind()) {
                        case JsonKind.JsObject =>
                            if (let Some(v) <- d.asObject().get(dataKey)) {
                                match (v.kind()) {
                                    case JsonKind.JsString => dataVal = v.asString().getValue()
                                    case JsonKind.JsInt => dataVal = v.asInt().getValue().toString()
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
        errNo = -1
    }
    return (errNo, errMsg, dataVal)
}

/** 掘金请求公共头 */
func juejinHeaders(cookie: String): Array<StrKV> {
    return [
        StrKV("Content-Type", "application/json; charset=utf-8"),
        StrKV("User-Agent", UA),
        StrKV("Accept", "*/*"),
        StrKV("Origin", "https://juejin.cn"),
        StrKV("Referer", "https://juejin.cn/"),
        StrKV("Cookie", cookie),
    ]
}

/** 组带 aid/uuid query 的完整 URL */
func juejinUrl(path: String, uuid: String): String {
    var url = JUEJIN_API + path + "?aid=" + JUEJIN_AID
    if (uuid.size > 0) {
        url = url + "&uuid=" + uuid
    }
    return url
}

/** 从分类列表响应里选分类：按名称匹配 front-matter 的分类（逗号分隔），匹配不到取第一个。
 * 响应形状：data: [{category_id, category: {category_name, ...}, ...}] */
public func pickJuejinCategory(respText: String, frontMatterCategories: String): String {
    var firstId = ""
    var wanted: ArrayList<String> = ArrayList<String>()
    for (p in frontMatterCategories.split(",", -1)) {
        let t = trimAscii(p)
        if (t.size > 0) {
            wanted.add(t)
        }
    }
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                if (let Some(dv) <- root.asObject().get("data")) {
                    match (dv.kind()) {
                        case JsonKind.JsArray =>
                            let arr = dv.asArray()
                            var i: Int64 = 0
                            while (i < arr.size()) {
                                match (arr.get(i)) {
                                    case Some(item) =>
                                        match (item.kind()) {
                                            case JsonKind.JsObject =>
                                                let io = item.asObject()
                                                var cid = ""
                                                var name = ""
                                                if (let Some(v) <- io.get("category_id")) {
                                                    match (v.kind()) {
                                                        case JsonKind.JsString => cid = v.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (let Some(c) <- io.get("category")) {
                                                    match (c.kind()) {
                                                        case JsonKind.JsObject =>
                                                            if (let Some(v) <- c.asObject().get("category_name")) {
                                                                match (v.kind()) {
                                                                    case JsonKind.JsString => name = v.asString().getValue()
                                                                    case _ => ()
                                                                }
                                                            }
                                                        case _ => ()
                                                    }
                                                }
                                                if (cid.size > 0) {
                                                    if (firstId.size == 0) {
                                                        firstId = cid
                                                    }
                                                    for (w in wanted) {
                                                        if (name == w) {
                                                            return cid
                                                        }
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    case None => ()
                                }
                                i++
                            }
                        case _ => ()
                    }
            }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return firstId
}

/** 从分类列表响应里取所选分类的热门标签 ID（hot_tags[].tag_id，最多 3 个） */
public func pickJuejinHotTags(respText: String, chosenCatId: String): Array<String> {
    var out: ArrayList<String> = ArrayList<String>()
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                if (let Some(dv) <- root.asObject().get("data")) {
                    match (dv.kind()) {
                        case JsonKind.JsArray =>
                            let arr = dv.asArray()
                            var i: Int64 = 0
                            while (i < arr.size() && out.toArray().size == 0) {
                                match (arr.get(i)) {
                                    case Some(item) =>
                                        match (item.kind()) {
                                            case JsonKind.JsObject =>
                                                let io = item.asObject()
                                                var cid = ""
                                                if (let Some(v) <- io.get("category_id")) {
                                                    match (v.kind()) {
                                                        case JsonKind.JsString => cid = v.asString().getValue()
                                                        case _ => ()
                                                    }
                                                }
                                                if (cid == chosenCatId) {
                                                    if (let Some(ht) <- io.get("hot_tags")) {
                                                        match (ht.kind()) {
                                                            case JsonKind.JsArray =>
                                                                let tags = ht.asArray()
                                                                var j: Int64 = 0
                                                                while (j < tags.size() && j < 3) {
                                                                    match (tags.get(j)) {
                                                                        case Some(t) =>
                                                                            match (t.kind()) {
                                                                                case JsonKind.JsObject =>
                                                                                    if (let Some(v) <- t.asObject().get("tag_id")) {
                                                                                        match (v.kind()) {
                                                                                            case JsonKind.JsString => out.add(v.asString().getValue())
                                                                                            case _ => ()
                                                                                        }
                                                                                    }
                                                                                case _ => ()
                                                                            }
                                                                        case None => ()
                                                                    }
                                                                    j++
                                                                }
                                                            case _ => ()
                                                        }
                                                    }
                                                }
                                            case _ => ()
                                        }
                                    case None => ()
                                }
                                i++
                            }
                        case _ => ()
                    }
            }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return out.toArray()
}

// ── 图片上传：字节 ImageX 五步链（gen_token → ApplyImageUpload(SigV4) → CRC32 直传
// → CommitImageUpload → get_img_url），配方实测自掘金编辑器抓包 + 社区实现对齐。
// 本地图必须转存：掘金渲染相对路径会拼成 juejin.cn/root/... 死链。 ──

/** IEEE CRC32（多项式 0xEDB88320），8 位小写 hex（ImageX 直传的 Content-CRC32 头） */
public func crc32Hex(data: Array<Byte>): String {
    var table = Array<UInt32>(256, repeat: 0)
    var i: Int64 = 0
    while (i < 256) {
        var c: UInt32 = UInt32(i)
        var k: Int64 = 0
        while (k < 8) {
            if ((c & UInt32(1)) != 0) {
                c = UInt32(0xEDB88320) ^ (c >> 1)
            } else {
                c = c >> 1
            }
            k++
        }
        table[i] = c
        i++
    }
    var crc: UInt32 = 0xFFFFFFFF
    for (b in data) {
        crc = table[Int64((crc ^ UInt32(b)) & UInt32(0xFF))] ^ (crc >> 8)
    }
    crc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
    // 小端序 4 字节 → 8 位 hex（与 zlib.crc32 & 0xFFFFFFFF 的 %08x 等价）
    let bytes: Array<Byte> = [
        UInt8(crc & UInt32(0xFF)), UInt8((crc >> 8) & UInt32(0xFF)),
        UInt8((crc >> 16) & UInt32(0xFF)), UInt8((crc >> 24) & UInt32(0xFF)),
    ]
    return toHexString(bytes)
}

/** Unix 时间戳 → x-amz-date 格式（YYYYMMDDTHHMMSSZ，UTC） */
public func amzDateFromUnix(unix: Int64): String {
    let base = iso8601FromUnix(unix)  // "YYYYMMDDTHH:MM:SS"
    var out = StringBuilder()
    for (r in base.runes()) {
        if (r != r':') {
            out.append(r.toString())
        }
    }
    return out.toString() + "Z"
}

/** AWS SigV4：GET 请求签名（ImageX 用，SignedHeaders=host;x-amz-date;x-amz-security-token）。
 * 空载荷 sha256 常量；派生链带 AWS4 前缀（对齐社区跑通实现）。 */
func imagexSigv4Auth(ak: String, sk: String, stoken: String, amzDate: String,
    querySorted: String): String {
    let host = "imagex.bytedanceapi.com:443"
    // ⚠ 仓颉 http 客户端的 Host 头永远带端口（抓线实测：443 默认端口也发 host:xxx:443），
    // 服务器按收到的 Host 重算签名——签名里的 host 必须同样带 :443，否则 SignatureDoesNotMatch
    let emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let canonical = "GET\n/\n" + querySorted + "\nhost:" + host +
        "\nx-amz-date:" + amzDate + "\nx-amz-security-token:" + stoken +
        "\n\nhost;x-amz-date;x-amz-security-token\n" + emptySha
    let datestamp = amzDate[0..8]
    let region = "cn-north-1"
    let service = "imagex"
    let scope = ak + "/" + datestamp + "/" + region + "/" + service + "/aws4_request"
    let sts = "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" +
        sha256Hex(canonical)
    let kd = hmacSha256(("AWS4" + sk), datestamp)
    let kr = hmacSha256Bytes(kd, region)
    let ks = hmacSha256Bytes(kr, service)
    let ksig = hmacSha256Bytes(ks, "aws4_request")
    let sig = hmacSha256BytesHex(ksig, sts)
    return "AWS4-HMAC-SHA256 Credential=" + scope + ", SignedHeaders=host;x-amz-date;x-amz-security-token, Signature=" + sig
}

func sha256Hex(s: String): String {
    let d = SHA256()
    d.write(s.toArray())
    return toHexString(d.finish())
}

func hmacSha256(key: String, msg: String): Array<Byte> {
    let mac = HMAC(key.toArray(), HashType.SHA256)
    mac.write(msg.toArray())
    return mac.finish()
}

func hmacSha256Bytes(key: Array<Byte>, msg: String): Array<Byte> {
    let mac = HMAC(key, HashType.SHA256)
    mac.write(msg.toArray())
    return mac.finish()
}

func hmacSha256BytesHex(key: Array<Byte>, msg: String): String {
    let mac = HMAC(key, HashType.SHA256)
    mac.write(msg.toArray())
    return toHexString(mac.finish())
}

/** 解析 ApplyImageUpload 响应：Result.UploadAddress.{UploadHosts[0], StoreInfos[0], SessionKey} */
func parseJuejinApply(respText: String): (String, String, String, String) {
    var uploadHost = ""
    var storeUri = ""
    var storeAuth = ""
    var sessionKey = ""
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                if (let Some(r) <- root.asObject().get("Result")) {
                    match (r.kind()) {
                        case JsonKind.JsObject =>
                            if (let Some(ua) <- r.asObject().get("UploadAddress")) {
                                match (ua.kind()) {
                                    case JsonKind.JsObject =>
                                        let uo = ua.asObject()
                                        if (let Some(hs) <- uo.get("UploadHosts")) {
                                            match (hs.kind()) {
                                                case JsonKind.JsArray =>
                                                    match (hs.asArray().get(0)) {
                                                        case Some(h) =>
                                                            match (h.kind()) {
                                                                case JsonKind.JsString => uploadHost = h.asString().getValue()
                                                                case _ => ()
                                                            }
                                                        case None => ()
                                                    }
                                                case _ => ()
                                            }
                                        }
                                        if (let Some(si) <- uo.get("StoreInfos")) {
                                            match (si.kind()) {
                                                case JsonKind.JsArray =>
                                                    match (si.asArray().get(0)) {
                                                        case Some(s) =>
                                                            match (s.kind()) {
                                                                case JsonKind.JsObject =>
                                                                    if (let Some(v) <- s.asObject().get("StoreUri")) {
                                                                        match (v.kind()) {
                                                                            case JsonKind.JsString => storeUri = v.asString().getValue()
                                                                            case _ => ()
                                                                        }
                                                                    }
                                                                    if (let Some(v) <- s.asObject().get("Auth")) {
                                                                        match (v.kind()) {
                                                                            case JsonKind.JsString => storeAuth = v.asString().getValue()
                                                                            case _ => ()
                                                                        }
                                                                    }
                                                                case _ => ()
                                                            }
                                                        case None => ()
                                                    }
                                                case _ => ()
                                            }
                                        }
                                        if (let Some(v) <- uo.get("SessionKey")) {
                                            match (v.kind()) {
                                                case JsonKind.JsString => sessionKey = v.asString().getValue()
                                                case _ => ()
                                            }
                                        }
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
    }
    return (uploadHost, storeUri, storeAuth, sessionKey)
}

/** ImageX 五步链：本地图字节 → 掘金图床正式 URL（data.main_url）；失败返回空串。
 * ⚠ ImageX 网关的 SigV4 校验存在间歇性 SignatureDoesNotMatch（同一实现时好时坏，
 * 2026-11-05 实测：Python/仓颉同实现均偶发被拒）——整链重试最多 3 次，每次换新令牌。 */
public func uploadJuejinImage(cookie: String, uuid: String, data: Array<Byte>, insecure: Bool): String {
    var attempt = 0
    while (attempt < 3) {
        let url = uploadJuejinImageOnce(cookie, uuid, data, insecure)
        if (url.size > 0) {
            return url
        }
        attempt++
        println("⚠ ImageX 上传第 ${attempt} 次尝试失败，重试…")
    }
    return ""
}

func uploadJuejinImageOnce(cookie: String, uuid: String, data: Array<Byte>, insecure: Bool): String {
    // ① gen_token
    // ⚠ GET 不能带 Content-Type：带 CT 签发的 STS 令牌签名必然失效（服务端把 CT
    // 绑进令牌，Apply 按无 CT 重算必不匹配；参考实现同款注释「GET 不设 CT」）
    let b0 = HttpRequestBuilder()
        .url(juejinUrl("/imagex/v2/gen_token", uuid) + "&client=web")
        .method("GET")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Origin", "https://juejin.cn")
        .header("Referer", "https://juejin.cn/")
        .header("Cookie", cookie)
    let r0 = execRequest(b0.build(), insecure)
    let (err0, msg0, _) = parseJuejinResp(r0.text, "")
    if (err0 != 0) {
        println("⚠ ImageX gen_token 失败 err_no=${err0} ${msg0}")
        return ""
    }
    var ak = ""
    var sk = ""
    var stoken = ""
    try {
        let root = JsonValue.fromStr(r0.text)
        match (root.kind()) {
            case JsonKind.JsObject =>
                if (let Some(d) <- root.asObject().get("data")) {
                    match (d.kind()) {
                        case JsonKind.JsObject =>
                            if (let Some(t) <- d.asObject().get("token")) {
                                match (t.kind()) {
                                    case JsonKind.JsObject =>
                                        let to = t.asObject()
                                        if (let Some(v) <- to.get("AccessKeyId")) {
                                            match (v.kind()) {
                                                case JsonKind.JsString => ak = v.asString().getValue()
                                                case _ => ()
                                            }
                                        }
                                        if (let Some(v) <- to.get("SecretAccessKey")) {
                                            match (v.kind()) {
                                                case JsonKind.JsString => sk = v.asString().getValue()
                                                case _ => ()
                                            }
                                        }
                                        if (let Some(v) <- to.get("SessionToken")) {
                                            match (v.kind()) {
                                                case JsonKind.JsString => stoken = v.asString().getValue()
                                                case _ => ()
                                            }
                                        }
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
        return ""
    }
    if (ak.size == 0 || sk.size == 0 || stoken.size == 0) {
        println("⚠ ImageX STS 凭证解析失败")
        return ""
    }

    // ② ApplyImageUpload（SigV4 签名 GET，query 字母序）
    let amzDate = amzDateFromUnix(Int64(DateTime.now(timeZone: TimeZone.UTC).toUnixTimeStamp() / Duration.second))
    let q2 = "Action=ApplyImageUpload&ServiceId=73owjymdk6&Version=2018-08-01"
    let auth2 = imagexSigv4Auth(ak, sk, stoken, amzDate, q2)
    let b2 = HttpRequestBuilder()
        .url("https://imagex.bytedanceapi.com/?" + q2)
        .method("GET")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Origin", "https://juejin.cn")
        .header("Referer", "https://juejin.cn/")
        .header("Authorization", auth2)
        .header("x-amz-date", amzDate)
        .header("x-amz-security-token", stoken)
    let r2 = execRequest(b2.build(), insecure)
    let (host2, storeUri, storeAuth, sessionKey) = parseJuejinApply(r2.text)
    dbg("ImageX Apply HTTP ${r2.status} storeUri=${storeUri}")
    if (host2.size == 0 || storeUri.size == 0 || storeAuth.size == 0) {
        println("⚠ ImageX Apply 失败：${r2.text}")
        return ""
    }

    // ③ CRC32 直传
    let crc = crc32Hex(data)
    let b3 = HttpRequestBuilder()
        .url("https://" + host2 + "/" + storeUri)
        .post()
        .body(data)
        .header("authorization", storeAuth)
        .header("Content-CRC32", crc)
        .header("Content-Type", "application/octet-stream")
    let r3 = execRequest(b3.build(), insecure)
    dbg("ImageX 直传 HTTP ${r3.status}")
    if (r3.status != 200) {
        println("⚠ ImageX 直传失败 HTTP ${r3.status}（CRC32 校验或凭证过期）")
        return ""
    }

    // ④ CommitImageUpload（best-effort：偶发签名差异，不阻断——实测未 Commit 也能取 URL）
    let q4 = "Action=CommitImageUpload&ServiceId=73owjymdk6&Version=2018-08-01&SessionKey=" +
        zhihuPercentEncode(sessionKey)
    let auth4 = imagexSigv4Auth(ak, sk, stoken, amzDate, q4)
    let b4 = HttpRequestBuilder()
        .url("https://imagex.bytedanceapi.com/?" + q4)
        .method("GET")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Origin", "https://juejin.cn")
        .header("Referer", "https://juejin.cn/")
        .header("Authorization", auth4)
        .header("x-amz-date", amzDate)
        .header("x-amz-security-token", stoken)
    let r4 = execRequest(b4.build(), insecure)
    dbg("ImageX Commit HTTP ${r4.status}")

    // ⑤ get_img_url（同 gen_token：GET 不带 Content-Type）
    let b5 = HttpRequestBuilder()
        .url(juejinUrl("/imagex/v2/get_img_url", uuid) + "&img_type=private&uri=" + zhihuPercentEncode(storeUri))
        .method("GET")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Origin", "https://juejin.cn")
        .header("Referer", "https://juejin.cn/")
        .header("Cookie", cookie)
    let r5 = execRequest(b5.build(), insecure)
    let (err5, msg5, mainUrl) = parseJuejinResp(r5.text, "main_url")
    if (err5 != 0 || mainUrl.size == 0) {
        println("⚠ ImageX get_img_url 失败 err_no=${err5} ${msg5}")
        return ""
    }
    return mainUrl
}

/** 掘金正文图片转存：本地图 → 掘金图床 → 回写正式 URL（从后往前替换不挪位）。
 * 外链 http(s) 保留原样；失败保留原链接并提示（best-effort，不阻断发文）。
 * 优先走伴生脚本 scripts/juejin_upload.py（Python ImageX 五步链，实测稳定——仓颉纯
 * HTTP 实现签名与 Python 逐字节一致但被网关间歇性拒绝，见 CHANGELOG 踩坑）；
 * 脚本缺失时降级仓颉 ImageX 实现。 */
public func rehostJuejinImages(cookie: String, uuid: String, md: String, insecure: Bool): String {
    let imgs = findExternalImages(md)
    var localPaths: ArrayList<String> = ArrayList<String>()
    for (img in imgs) {
        let src = img.url
        if (!src.startsWith("http://") && !src.startsWith("https://") && !src.startsWith("data:")) {
            localPaths.add(src)
        }
    }
    // 伴生脚本可用：一次调用批量上传所有本地图，拿回路径→URL 映射
    var urlMap: ArrayList<StrKV> = ArrayList<StrKV>()
    let scriptPath = "scripts/juejin_upload.py"
    let probe = try { readTextFileAll(scriptPath) } catch (e: Exception) {
        let _ = e
        ""
    }
    if (probe.size > 0 && localPaths.size > 0) {
        let tmpCookie = "/tmp/cspub_juejin_${randomHex(8)}.cookie"
        let tmpMap = "/tmp/cspub_juejin_${randomHex(8)}.map.json"
        var argv: ArrayList<String> = ArrayList<String>()
        argv.add("scripts/juejin_upload.py")
        argv.add("--cookie-file")
        argv.add(tmpCookie)
        argv.add("--map-file")
        argv.add(tmpMap)
        for (p in localPaths) {
            argv.add(p)
        }
        try {
            writeFileTmp(tmpCookie, cookie)
            println("掘金：上传正文图片 ${localPaths.size} 张（伴生脚本 ImageX）…")
            let (exitCode, _, errBytes) = executeWithOutput("python3", argv.toArray())
            let errText = String.fromUtf8(errBytes)
            if (errText.size > 0) {
                dbg("juejin_upload stderr：${errText}")
            }
            if (exitCode == 0) {
                let mapText = readTextFileAll(tmpMap)
                let root = JsonValue.fromStr(mapText)
                match (root.kind()) {
                    case JsonKind.JsObject =>
                        for (p in localPaths) {
                            if (let Some(v) <- root.asObject().get(p)) {
                                match (v.kind()) {
                                    case JsonKind.JsString =>
                                        let u = v.asString().getValue()
                                        if (u.size > 0) {
                                            urlMap.add(StrKV(p, u))
                                        }
                                    case _ => ()
                                }
                            }
                        }
                    case _ => ()
                }
            } else {
                println("⚠ 掘金图片上传脚本退出码 ${exitCode}，降级仓颉内置 ImageX 实现")
            }
        } catch (e: Exception) {
            println("⚠ 掘金图片上传脚本执行失败（${e.message}），降级仓颉内置 ImageX 实现")
        } finally {
            try { remove(tmpCookie) } catch (e: Exception) { let _ = e }
            try { remove(tmpMap) } catch (e: Exception) { let _ = e }
        }
    }

    var found = 0
    var ok = 0
    var fail = 0
    var out = md
    var i = Int64(imgs.size) - 1
    while (i >= 0) {
        let ref = imgs[i]
        let src = ref.url
        var skip = false
        if (src.startsWith("http://") || src.startsWith("https://") || src.startsWith("data:")) {
            skip = true
        }
        if (!skip) {
            found++
            var newUrl = ""
            // 先查伴生脚本映射
            for (kv in urlMap) {
                if (kv.k == src && kv.v.size > 0) {
                    newUrl = kv.v
                    break
                }
            }
            // 映射没有：降级仓颉内置 ImageX 单图上传
            if (newUrl.size == 0) {
                let data = try { readImageBytes(src) } catch (e: Exception) {
                    let _ = e
                    Array<Byte>(0, repeat: 0)
                }
                if (data.size > 0) {
                    newUrl = uploadJuejinImage(cookie, uuid, data, insecure)
                }
            }
            if (newUrl.size > 0) {
                ok++
                out = out[0..ref.urlStart] + newUrl + out[ref.urlEnd..out.size]
            } else {
                fail++
                println("⚠ 掘金图片转存失败（保留原引用，网页上会显示死链）：${src}")
            }
        }
        i--
    }
    if (found > 0) {
        println("图片转存：${found} 张待转，成功 ${ok}，失败 ${fail}")
    }
    return out
}

/** 掘金发文入口。publishNow=false 只建草稿（后台 juejin.cn/editor/drafts 可见）。
 * categoryId 未配置时自动拉分类列表：优先按 front-matter 分类名匹配，匹配不到取第一个
 * （掘金发布强制至少一个分类，err_no=1002）。 */
public func publishToJuejin(cookie: String, uuid: String, categoryId: String, tagIds: Array<String>,
    a: Article, publishNow: Bool, insecure: Bool): Int64 {

    // uuid：掘金 api query 参数（imagex 链路实测需要，缺了报「请求路由不存在」）；
    // 未配置时用 19 位数字占位常量（探针实测可用，不影响鉴权——鉴权只看 Cookie）
    var jjUuid = trimAscii(uuid)
    if (jjUuid.size == 0) {
        jjUuid = "7301234567890123456"
    }

    var catId = trimAscii(categoryId)
    var finalTagIds = tagIds
    if (catId.size == 0) {
        // 自动选分类：拉列表 → 按名称匹配 → 兜底第一个
        println("掘金：未配置分类，自动拉取分类列表…")
        let b0 = HttpRequestBuilder()
            .url(juejinUrl("/tag_api/v1/query_category_list", jjUuid))
            .post()
            .body("{}")
        let r0 = execRequest(applyHeaders(b0, juejinHeaders(cookie)).build(), insecure)
        let (err0, msg0, _) = parseJuejinResp(r0.text, "")
        if (err0 != 0) {
            println("错误：掘金分类列表拉取失败 err_no=${err0} ${msg0}——请配置 CSPUB_JUEJIN_CATEGORY_ID")
            return 1
        }
        catId = pickJuejinCategory(r0.text, a.categories)
        if (catId.size == 0) {
            println("错误：分类列表里没有可选分类——请配置 CSPUB_JUEJIN_CATEGORY_ID")
            return 1
        }
        // 标签兜底：掘金发布强制至少一个标签（err_no=1003）——取所选分类的 hot_tags 前 3 个
        if (finalTagIds.size == 0) {
            finalTagIds = pickJuejinHotTags(r0.text, catId)
            dbg("hot_tags 兜底结果：${finalTagIds.size} 个")
            if (finalTagIds.size > 0) {
                println("掘金：未配置标签，自动选用分类热门标签 ${finalTagIds.size} 个")
            }
        }
        println("掘金：使用分类 category_id=${catId}")
    }

    if (cookieValue(cookie, "sessionid").size == 0) {
        println("错误：Cookie 里没有 sessionid——要浏览器登录 juejin.cn 后复制的整串 Cookie")
        return 1
    }
    // 图片转存（发文前）：掘金把相对路径渲染成 juejin.cn/<路径> 死链，本地图必须上传 ImageX。
    // best-effort：单张失败保留原引用并提示，不阻断发文。
    let bodyMd = rehostJuejinImages(cookie, jjUuid, a.body, insecure)
    let brief = normalizeJuejinBrief(a.desc, a.body)
    // 标题 ≤80 字（按字符数截断）
    var title = a.title
    if (utf8CharCount(title) > 80) {
        title = truncateUtf8(title, 240)
        println("⚠ 标题超 80 字，已截断")
    }

    // ① 建草稿
    println("掘金：创建草稿…")
    let draftBody = buildJuejinDraftBody(title, bodyMd, brief, catId, finalTagIds, "")
    let b1 = HttpRequestBuilder()
        .url(juejinUrl("/content_api/v1/article_draft/create", jjUuid))
        .post()
        .body(draftBody)
    let r1 = execRequest(applyHeaders(b1, juejinHeaders(cookie)).build(), insecure)
    dbg("draft create HTTP ${r1.status}：${r1.text}")
    if (r1.status == 401 || r1.status == 403) {
        println("错误：掘金返回 HTTP ${r1.status}——Cookie 多半过期了（重抓整串，须含 sessionid）")
        println(r1.text)
        return 1
    }
    let (err1, msg1, draftId) = parseJuejinResp(r1.text, "id")
    if (err1 != 0 || draftId.size == 0) {
        println("错误：掘金建草稿失败 err_no=${err1} ${msg1}")
        println(r1.text)
        return 1
    }

    if (!publishNow) {
        println("草稿已保存：https://juejin.cn/editor/drafts/${draftId}")
        println("draft_id：${draftId}（后台编辑发布，或重跑加 --live）")
        return 0
    }

    // ② 发布
    println("掘金：发布草稿…")
    let b2 = HttpRequestBuilder()
        .url(juejinUrl("/content_api/v1/article/publish", jjUuid))
        .post()
        .body(buildJuejinPublishBody(draftId))
    let r2 = execRequest(applyHeaders(b2, juejinHeaders(cookie)).build(), insecure)
    dbg("publish HTTP ${r2.status}：${r2.text}")
    let (err2, msg2, articleId) = parseJuejinResp(r2.text, "article_id")
    if (err2 != 0 || articleId.size == 0) {
        println("错误：掘金发布失败 err_no=${err2} ${msg2}（草稿仍在，后台可手动发布）")
        println(r2.text)
        return 1
    }
    println("文章链接：https://juejin.cn/post/${articleId}")
    println("article_id：${articleId}")
    return 0
}
