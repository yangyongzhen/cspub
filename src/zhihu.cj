/** 知乎专栏发文客户端：知乎无官方发文 API，走 Cookie 模拟 Web 接口。
 * 流程（镜像 zhuanlan.zhihu.com 编辑器前端，与 ace skill 等参考实现一致）：
 * ①POST /api/articles/drafts 建空草稿 → ②PATCH /api/articles/{id}/draft 写标题与 HTML 正文
 * → ③PUT /api/articles/{id}/publish 发布（草稿模式止步于 ②）。
 * 鉴权：浏览器登录态 Cookie 整串（z_c0 是登录凭证，XSRF-TOKEN 会作 x-xsrftoken 头回传）。 */
package cspub

import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.base64.*
import stdx.encoding.hex.*
import stdx.encoding.json.*
import stdx.net.http.*

public const ZHIHU_BASE: String = "https://zhuanlan.zhihu.com"

/** 建草稿请求体（纯函数，供测试对账） */
public func buildZhihuCreateBody(title: String): String {
    let body = JsonObject()
    body.put("title", JsonString(title))
    body.put("content", JsonString(""))
    body.put("delta_time", JsonInt(0))
    return body.toJsonString()
}

/** 写正文请求体（纯函数，供测试对账） */
public func buildZhihuPatchBody(title: String, content: String): String {
    let body = JsonObject()
    body.put("title", JsonString(title))
    body.put("content", JsonString(content))
    body.put("delta_time", JsonInt(0))
    return body.toJsonString()
}

/** 知乎请求公共头：编辑器页面的 fetch 形状 */
func zhihuHeaders(cookie: String, xsrf: String): Array<StrKV> {
    var headers = [
        StrKV("Content-Type", "application/json"),
        StrKV("User-Agent", UA),
        StrKV("Accept", "*/*"),
        StrKV("Referer", "https://zhuanlan.zhihu.com/write"),
        StrKV("Origin", "https://zhuanlan.zhihu.com"),
        StrKV("Cookie", cookie),
        StrKV("x-requested-with", "fetch"),
    ]
    if (xsrf.size > 0) {
        var withXsrf = ArrayList<StrKV>()
        for (h in headers) {
            withXsrf.add(h)
        }
        withXsrf.add(StrKV("x-xsrftoken", xsrf))
        headers = withXsrf.toArray()
    }
    return headers
}

/** 组一个知乎 API 请求 */
func zhihuRequest(method: String, pathWithQuery: String, cookie: String, xsrf: String, payload: String): HttpRequest {
    let builder = HttpRequestBuilder()
        .url(ZHIHU_BASE + pathWithQuery)
        .method(method)
        .body(payload)
    return applyHeaders(builder, zhihuHeaders(cookie, xsrf)).build()
}

/** 从响应 JSON 里取草稿 id（知乎可能回数字或字符串；非 JSON 输入返回空串） */
public func parseZhihuDraftId(respText: String): String {
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                let obj = root.asObject()
                if (let Some(v) <- obj.get("id")) {
                    match (v.kind()) {
                        case JsonKind.JsInt => return v.asInt().getValue().toString()
                        case JsonKind.JsString => return v.asString().getValue()
                        case _ => ()
                    }
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return ""
}

/** 知乎发文入口。publishNow=false 只到草稿（后台 zhuanlan.zhihu.com/write 可见）。
 * 图片：知乎会剥离站外图床的外链（连 csdnimg 都可能剥），发文前建议确认链接可达；
 * 后续可接知乎素材上传。insecure 语义与 CSDN 相同（TrustAll，诊断用）。 */
public func publishToZhihu(cookie: String, a: Article, publishNow: Bool, insecure: Bool): Int64 {
    let xsrf = cookieValue(cookie, "XSRF-TOKEN")
    // 图片转存（发文前）：知乎保存时剥离非 zhimg.com 图源，站外图/本地图必须先进知乎 CDN。
    // best-effort：单张失败保留原链接并提示，不阻断发文。
    let bodyMd = rehostImagesZhihu(cookie, xsrf, a.body, insecure)
    let html = mdToHtml(bodyMd)

    // ① 建空草稿
    println("知乎：创建草稿…")
    let r1 = execRequest(zhihuRequest("POST", "/api/articles/drafts", cookie, xsrf, buildZhihuCreateBody(a.title)), insecure)
    dbg("drafts 响应 HTTP ${r1.status}：${r1.text}")
    if (r1.status == 401 || r1.status == 403) {
        println("错误：知乎返回 HTTP ${r1.status}——Cookie 多半过期了，重新从浏览器复制整串（须含 z_c0）")
        println(r1.text)
        return 1
    }
    if (r1.status != 200) {
        println("错误：知乎创建草稿返回 HTTP ${r1.status}")
        println(r1.text)
        return 1
    }
    let draftId = parseZhihuDraftId(r1.text)
    if (draftId.size == 0) {
        println("错误：知乎创建草稿响应里没有 id（登录态可能失效）")
        println(r1.text)
        return 1
    }

    // ② 写正文
    println("知乎：写入正文（draft ${draftId}）…")
    let r2 = execRequest(zhihuRequest("PATCH", "/api/articles/${draftId}/draft", cookie, xsrf, buildZhihuPatchBody(a.title, html)), insecure)
    if (r2.status != 200) {
        println("错误：知乎写正文返回 HTTP ${r2.status}")
        println(r2.text)
        return 1
    }

    if (!publishNow) {
        println("草稿已保存：https://zhuanlan.zhihu.com/write?draftId=${draftId}")
        println("draft id：${draftId}（知乎草稿直接在后台编辑发布，或重跑加 --live）")
        return 0
    }

    // ③ 发布
    println("知乎：发布…")
    let r3 = execRequest(zhihuRequest("PUT", "/api/articles/${draftId}/publish", cookie, xsrf, "{}"), insecure)
    if (r3.status != 200) {
        println("错误：知乎发布返回 HTTP ${r3.status}（草稿仍在，可去后台手动发布）")
        println(r3.text)
        return 1
    }
    println("文章链接：https://zhuanlan.zhihu.com/p/${draftId}")
    return 0
}

// ── 图片转存（知乎会剥离站外图，发文前必须 rehost 到 zhimg.com CDN）──
// 主路径（外链）：POST zhuanlan.zhihu.com/api/uploaded_images {url, source:"article"}，
// 知乎服务端自己抓取并转存（acedatacloud/skills blog.py 生产验证配方）；
// 本地图：MD5 → POST api.zhihu.com/images {image_hash, source} →
//   state=1（已存在，去重）GET /images/{id} 取 hash；state=2 拿 OSS STS token 签名 PUT。
// 规范链接：https://picx.zhimg.com/{hash}.png（uploaded_images）/ pic4（二进制）。

/** 从图片 src 提取扩展名（最后一个 '.' 到 '?'/'#' 前），缺省 png */
public func zhihuImgExt(src: String): String {
    let b = src.toArray()
    var end = b.size
    var q: Int64 = 0
    while (q < end) {
        if (b[q] == UInt8(63) || b[q] == UInt8(35)) {  // '?' '#'
            end = q
            break
        }
        q++
    }
    var dot: Int64 = -1
    var i: Int64 = end - 1
    while (i >= 0) {
        if (b[i] == UInt8(47)) {  // '/' —— 路径分隔符前无扩展名
            break
        }
        if (b[i] == UInt8(46)) {  // '.'
            dot = i
            break
        }
        i--
    }
    if (dot < 0 || dot + 1 >= end) {
        return "png"
    }
    let ext = trimAscii(String.fromUtf8(b[(dot + 1)..end]))
    if (ext.size == 0 || ext.size > 5) {
        return "png"
    }
    return ext
}

/** 规范化知乎图片链接：draft 域的 pic-private/带签名的临时 URL 归约为发布后长期有效的
 * 公共形式 https://picx.zhimg.com/{hash}.{ext}（hash 形如 v2-<hex>） */
public func zhihuCanonicalUrl(hash: String, src: String): String {
    if (hash.size == 0) {
        return ""
    }
    return "https://picx.zhimg.com/${hash}.${zhihuImgExt(src)}"
}

/** 表单字段值的百分号编码（unreserved 字母数字与 -_.~ 保留，其余转 %XX） */
public func zhihuPercentEncode(s: String): String {
    let b = s.toArray()
    let out = StringBuilder()
    for (c in b) {
        let u = UInt32(c)
        let isAlphaNum = (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
        if (isAlphaNum || c == UInt8(45) || c == UInt8(46) || c == UInt8(95) || c == UInt8(126)) {
            out.append(String.fromUtf8([c]))
        } else {
            out.append("%${hexByte(u)}")
        }
    }
    return out.toString()
}

/** 单字节转两位大写 hex */
func hexByte(u: UInt32): String {
    let digits: Array<Byte> = "0123456789ABCDEF".toArray()
    return String.fromUtf8([digits[Int64(u >> 4)], digits[Int64(u & 15)]])
}

/** Unix 时间戳 → RFC1123 GMT（OSS Date 头用；不依赖本地时区与日期库，civil 算法直算。
 * 1970-01-01 是周四：dow = (days + 3) % 7 → 0=Thu */
public func rfc1123FromUnix(unix: Int64): String {
    let days = unix / 86400
    var rem = unix % 86400
    if (rem < 0) {
        rem += 86400
        // days -= 1  // 负时间戳本工具用不到，不处理
    }
    let hour = rem / 3600
    let minute = (rem % 3600) / 60
    let second = rem % 60
    // civil 日历算法（Howard Hinnant）：days 从 1970-01-01 起
    var z = days + 719468
    let era = z / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    var y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    var m = mp + 3
    if (mp >= 10) {
        m -= 12
        y += 1
    }
    let dows = (days + 3) % 7  // 0=Mon（1970-01-01 周四 → Mon 为基的索引 3）
    let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let monNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    let dowName = dayNames[((dows % 7) + 7) % 7]
    return "${dowName}, ${pad2(d)} ${monNames[m - 1]} ${y} ${pad2(hour)}:${pad2(minute)}:${pad2(second)} GMT"
}

func pad2(n: Int64): String {
    if (n < 10) {
        return "0${n}"
    }
    return "${n}"
}

/** 按魔数判图片 Content-Type（OSS PUT 与知乎校验用） */
public func imgContentType(data: Array<Byte>): String {
    if (data.size >= 4 && data[0] == UInt8(0x89) && data[1] == UInt8(0x50)) {
        return "image/png"
    }
    if (data.size >= 3 && data[0] == UInt8(0xFF) && data[1] == UInt8(0xD8)) {
        return "image/jpeg"
    }
    if (data.size >= 3 && data[0] == UInt8(0x47) && data[1] == UInt8(0x49) && data[2] == UInt8(0x46)) {
        return "image/gif"
    }
    return "application/octet-stream"
}

/** 从响应 JSON 顶层取字符串字段（original_hash / src 等；非 JSON 返回空串） */
public func zhihuJsonTopString(respText: String, key: String): String {
    try {
        let root = JsonValue.fromStr(respText)
        match (root.kind()) {
            case JsonKind.JsObject =>
                if (let Some(v) <- root.asObject().get(key)) {
                    match (v.kind()) {
                        case JsonKind.JsString => return v.asString().getValue()
                        case _ => ()
                    }
                }
            case _ => ()
        }
    } catch (e: Exception) {
        let _ = e
    }
    return ""
}

/** MD5 hex（知乎二进制上传去重键） */
public func md5Hex(data: Array<Byte>): String {
    let d = MD5()
    d.write(data)
    return toHexString(d.finish())
}

/** HMAC-SHA1 → base64（OSS PUT 签名） */
func hmacSha1Base64(key: String, sts: String): String {
    let mac = HMAC(key.toArray(), HashType.SHA1)
    mac.write(sts.toArray())
    return toBase64String(mac.finish())
}

/** 外链图转存（主路径）：知乎服务端抓取 src 并转存，回 pic-private 临时 URL，
 * 规范化后返回公共 zhimg 链接；失败返回空串 */
func uploadZhihuImageByUrl(cookie: String, xsrf: String, src: String, insecure: Bool): String {
    let body = "url=${zhihuPercentEncode(src)}&source=article"
    let builder = HttpRequestBuilder()
        .url("https://zhuanlan.zhihu.com/api/uploaded_images")
        .post()
        .body(body)
        .header("Content-Type", "application/x-www-form-urlencoded")
    let req = applyHeaders(builder, zhihuHeaders(cookie, xsrf)).build()
    let resp = execRequest(req, insecure)
    dbg("uploaded_images HTTP ${resp.status}：${resp.text}")
    if (resp.status != 200) {
        return ""
    }
    let hash = zhihuJsonTopString(resp.text, "original_hash")
    return zhihuCanonicalUrl(hash, src)
}

/** 本地图二进制转存：MD5 → api.zhihu.com/images → 去重或 OSS STS 签名 PUT → pic4 链接 */
func uploadZhihuImageByBytes(cookie: String, xsrf: String, data: Array<Byte>, ext: String, insecure: Bool): String {
    let md5 = md5Hex(data)
    let body = JsonObject()
    body.put("image_hash", JsonString(md5))
    body.put("source", JsonString("article"))
    let builder = HttpRequestBuilder()
        .url("https://api.zhihu.com/images")
        .post()
        .body(body.toJsonString())
        .header("Content-Type", "application/json")
    let req = applyHeaders(builder, zhihuHeaders(cookie, xsrf)).build()
    let resp = execRequest(req, insecure)
    dbg("images HTTP ${resp.status}：${resp.text}")
    if (resp.status != 200) {
        return ""
    }
    // 解析 upload_file{state, image_id, object_key} + upload_token{access_*}
    var state: Int64 = -1
    var imageId = ""
    var objectKey = ""
    var accessId = ""
    var accessKey = ""
    var accessToken = ""
    try {
        let root = JsonValue.fromStr(resp.text)
        match (root.kind()) {
            case JsonKind.JsObject =>
                let obj = root.asObject()
                if (let Some(uf) <- obj.get("upload_file")) {
                    match (uf.kind()) {
                        case JsonKind.JsObject =>
                            let ufo = uf.asObject()
                            if (let Some(v) <- ufo.get("state")) {
                                match (v.kind()) {
                                    case JsonKind.JsInt => state = v.asInt().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(v) <- ufo.get("image_id")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => imageId = v.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(v) <- ufo.get("object_key")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => objectKey = v.asString().getValue()
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                }
                if (let Some(ut) <- obj.get("upload_token")) {
                    match (ut.kind()) {
                        case JsonKind.JsObject =>
                            let uto = ut.asObject()
                            if (let Some(v) <- uto.get("access_id")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => accessId = v.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(v) <- uto.get("access_key")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => accessKey = v.asString().getValue()
                                    case _ => ()
                                }
                            }
                            if (let Some(v) <- uto.get("access_token")) {
                                match (v.kind()) {
                                    case JsonKind.JsString => accessToken = v.asString().getValue()
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
    if (state == 1) {
        // 已在知乎 CDN（去重命中）：查 hash 即可
        let hash = waitZhihuImageReady(cookie, xsrf, imageId, insecure)
        if (hash.size > 0) {
            return "https://pic4.zhimg.com/${hash}.${ext}"
        }
        return ""
    }
    if (objectKey.size == 0 || accessId.size == 0 || accessKey.size == 0 || accessToken.size == 0) {
        return ""
    }
    // OSS STS 签名 PUT（canonical headers 按 key 排序：x-oss-date < x-oss-security-token < x-oss-user-agent）
    // 注意：不能用响应里的 access_timestamp 当请求时间——实测它比真实 UTC 快 1 小时，
    // OSS 报 RequestTimeTooSkewed（MaxAllowedSkew 900s）；必须用本机当前 UTC 时间。
    let ctype = imgContentType(data)
    let nowUnix = Int64(DateTime.now(timeZone: TimeZone.UTC).toUnixTimeStamp() / Duration.second)
    let ossDate = rfc1123FromUnix(nowUnix)
    let sts = "PUT\n\n${ctype}\n${ossDate}\nx-oss-date:${ossDate}\nx-oss-security-token:${accessToken}\nx-oss-user-agent:aliyun-sdk-js/6.8.0\n/zhihu-pics/${objectKey}"
    let sig = hmacSha1Base64(accessKey, sts)
    let putBuilder = HttpRequestBuilder()
        .url("https://zhihu-pics-upload.zhimg.com/${objectKey}")
        .put()
        .body(data)
        .header("Content-Type", ctype)
        .header("Authorization", "OSS ${accessId}:${sig}")
        .header("x-oss-date", ossDate)
        .header("x-oss-security-token", accessToken)
        .header("x-oss-user-agent", "aliyun-sdk-js/6.8.0")
    let putReq = putBuilder.build()
    let putResp = execRequest(putReq, insecure)
    dbg("OSS PUT HTTP ${putResp.status}：${putResp.text}")
    if (putResp.status != 200) {
        return ""
    }
    let gExt = if (ctype == "image/gif") { "gif" } else { ext }
    return "https://pic4.zhimg.com/${objectKey}.${gExt}"
}

/** 轮询知乎图片处理状态，回 original_hash（最多 10 次，间隔 1s） */
func waitZhihuImageReady(cookie: String, xsrf: String, imageId: String, insecure: Bool): String {
    var i = 0
    while (i < 10) {
        sleep(Duration.second)
        let builder = HttpRequestBuilder()
            .url("https://api.zhihu.com/images/${imageId}")
            .get()
        let req = applyHeaders(builder, zhihuHeaders(cookie, xsrf)).build()
        let resp = execRequest(req, insecure)
        if (resp.status == 200) {
            let hash = zhihuJsonTopString(resp.text, "original_hash")
            if (hash.size > 0) {
                return hash
            }
        }
        i++
    }
    return ""
}

/** 知乎正文图片转存：扫描 markdown 图片引用（从后往前替换不挪位），best-effort——
 * 单张失败保留原链接并提示，不阻断发文。已在 zhimg/pic-private 的与 data: 跳过。 */
public func rehostImagesZhihu(cookie: String, xsrf: String, md: String, insecure: Bool): String {
    let imgs = findExternalImages(md)
    var found = 0
    var ok = 0
    var fail = 0
    var out = md
    var i = Int64(imgs.size) - 1
    while (i >= 0) {
        let ref = imgs[i]
        let src = ref.url
        var skip = false
        if (src.startsWith("data:")) {
            skip = true
        } else if (hostOf(src).endsWith("zhimg.com")) {
            skip = true
        } else if (hostOf(src) == "pic-private.zhihu.com") {
            skip = true
        }
        if (!skip) {
            found++
            var newUrl = ""
            if (src.startsWith("http://") || src.startsWith("https://")) {
                newUrl = uploadZhihuImageByUrl(cookie, xsrf, src, insecure)
            } else {
                // 本地路径：读文件走二进制通道（遵循 images.cj 同样的文件读取）
                let data = try { readImageBytes(src) } catch (e: Exception) {
                    let _ = e
                    Array<Byte>(0, repeat: 0)
                }
                if (data.size > 0) {
                    newUrl = uploadZhihuImageByBytes(cookie, xsrf, data, zhihuImgExt(src), insecure)
                }
            }
            if (newUrl.size > 0) {
                ok++
                out = out[0..ref.urlStart] + newUrl + out[ref.urlEnd..out.size]
            } else {
                fail++
                println("⚠ 知乎图片转存失败，保留原链接（知乎可能剥离该图）：${src}")
            }
        }
        i--
    }
    if (found > 0) {
        println("图片转存：${found} 张待转，成功 ${ok}，失败 ${fail}")
    }
    return out
}

/** 读本地图片字节（binary 全量读，循环到 EOF） */
func readImageBytes(path: String): Array<Byte> {
    let f = File(path, OpenMode.Read)
    let buf = Array<Byte>(16384, repeat: 0)
    let acc = ArrayList<Byte>()
    while (true) {
        let n = f.read(buf)
        if (n <= 0) {
            break
        }
        var i: Int64 = 0
        while (i < n) {
            acc.add(buf[i])
            i++
        }
    }
    f.close()
    return acc.toArray()
}
