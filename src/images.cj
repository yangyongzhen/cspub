/** 图片转存：CSDN 对站外图有防盗链（典型形状「HTTP 200 + 0 字节」，AGENTS §4 同款）——
 * 外链图必须先传 CSDN 图床（csdnimg.cn）再发文。
 * 流程镜像 CSDN 编辑器前端：①签名接口（bizapi，网关 HMAC + Cookie）→ ②华为 OBS multipart
 * （policy 授权，免签名免 Cookie）→ ③回调返回 csdnimg.cn URL，回写进 Markdown。 */
package cspub

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/** CSPUB_DEBUG 置位时打诊断行（排查图床/发文链路用，不影响正常输出） */
public func dbg(msg: String): Unit {
    match (getVariable("CSPUB_DEBUG")) {
        case Some(_) => eprintln("[dbg] " + msg)
        case None => ()
    }
}

public const OBS_MAX_IMG_BYTES: Int64 = 12 * 1024 * 1024

/** 一处图片引用（字节偏移按原文计，供「从后往前」替换而不挪位） */
public class ImgRef {
    public var urlStart: Int64
    public var urlEnd: Int64
    public var url: String
    public init(urlStart: Int64, urlEnd: Int64, url: String) {
        this.urlStart = urlStart
        this.urlEnd = urlEnd
        this.url = url
    }
}

/** multipart 表单字段（避开元组索引的不确定性，类字段直取） */
public class StrKV {
    public var k: String
    public var v: String
    public init(k: String, v: String) {
        this.k = k
        this.v = v
    }
}

// ── URL / 主机 ──

/** 从 URL 取主机名（小写）：去 scheme / userinfo / 端口 / IPv6 方括号 */
public func hostOf(url: String): String {
    let b = url.toArray()
    var i: Int64 = 0
    while (i + 2 < b.size && !(b[i] == UInt8(58) && b[i + 1] == UInt8(47) && b[i + 2] == UInt8(47))) {
        i++
    }
    if (i + 3 > b.size) {
        return ""
    }
    var e = i + 3
    while (e < b.size && b[e] != UInt8(47) && b[e] != UInt8(63) && b[e] != UInt8(35)) {
        e++
    }
    var seg = b[(i + 3)..e]
    // userinfo：最后一个 '@' 之后
    var k: Int64 = 0
    var at: Int64 = -1
    while (k < seg.size) {
        if (seg[k] == UInt8(64)) {
            at = k
        }
        k++
    }
    if (at >= 0) {
        seg = seg[(at + 1)..seg.size]
    }
    // IPv6 [..]
    if (seg.size > 0 && seg[0] == UInt8(91)) {
        var m: Int64 = 1
        while (m < seg.size && seg[m] != UInt8(93)) {
            m++
        }
        if (m >= seg.size) {
            return ""
        }
        return lowerAscii(String.fromUtf8(seg[1..m]))
    }
    // 端口：第一个 ':' 之前
    var p: Int64 = 0
    while (p < seg.size && seg[p] != UInt8(58)) {
        p++
    }
    if (p < seg.size) {
        seg = seg[0..p]
    }
    return lowerAscii(String.fromUtf8(seg))
}

func lowerAscii(s: String): String {
    let b = s.toArray()
    var i: Int64 = 0
    while (i < b.size) {
        if (b[i] >= UInt8(65) && b[i] <= UInt8(90)) {
            b[i] = b[i] + UInt8(32)
        }
        i++
    }
    return String.fromUtf8(b)
}

func sameOrSub(host: String, suffix: String): Bool {
    return host == suffix || host.endsWith("." + suffix)
}

/** 已是 CSDN 图床（转存无意义也不该动） */
public func isCsdnImageHost(host: String): Bool {
    return sameOrSub(host, "csdnimg.cn") || sameOrSub(host, "csdn.net")
}

/** 非公网主机字面量拦截（回环 / 内网段 / 链路本地 / 组播保留段）。
 * 如实记：未做「域名解析后再判 IP」一层（防 DNS rebinding 需 std.net 解域名的 API 形状，未核）；
 * 这是本机单用户 CLI、图源来自用户自己写的文章文件，风险面与多租户服务不同，先按字面量拦。 */
public func isBlockedHost(host: String): Bool {
    if (host.size == 0) {
        return true
    }
    if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) {
        return true
    }
    if (host.contains(":")) {
        // IPv6 形状
        let h = host.replace("[", "").replace("]", "")
        if (h == "::1" || h == "::") {
            return true
        }
        if (h.startsWith("fc") || h.startsWith("fd")) {
            return true  // fc00::/7 unique local
        }
        if (h.startsWith("fe8") || h.startsWith("fe9") || h.startsWith("fea") || h.startsWith("feb")) {
            return true  // fe80::/10 link local
        }
        return false
    }
    let parts = host.split(".", -1)
    if (parts.size != 4) {
        return false  // 普通域名
    }
    var oc = [0, 0, 0, 0]
    var i: Int64 = 0
    while (i < 4) {
        try {
            oc[i] = Int64.parse(parts[i])
        } catch (e: Exception) {
            let _ = e
            return false  // 非纯数字段（怪主机名），不拦
        }
        i++
    }
    if (oc[0] == 0 || oc[0] == 10 || oc[0] == 127) {
        return true
    }
    if (oc[0] == 169 && oc[1] == 254) {
        return true
    }
    if (oc[0] == 172 && oc[1] >= 16 && oc[1] <= 31) {
        return true
    }
    if (oc[0] == 192 && oc[1] == 168) {
        return true
    }
    if (oc[0] == 100 && oc[1] >= 64 && oc[1] <= 127) {
        return true  // CGNAT
    }
    if (oc[0] >= 224) {
        return true  // 组播 + 保留
    }
    return false
}

// ── 扫描 ──

/** 找出 Markdown 里的图片引用（代码围栏内跳过；data:/CSDN 图床的照常返回，由调用方按主机分流） */
public func findExternalImages(md: String): Array<ImgRef> {
    let out = ArrayList<ImgRef>()
    let lines = md.split("\n", -1)
    var base: Int64 = 0
    var inCode = false
    for (line in lines) {
        if (trimAscii(line).startsWith("```")) {
            inCode = !inCode
            base += line.size + 1
            continue
        }
        if (!inCode) {
            scanLineImages(line, base, out)
        }
        base += line.size + 1
    }
    return out.toArray()
}

func scanLineImages(line: String, base: Int64, out: ArrayList<ImgRef>): Unit {
    let b = line.toArray()
    var i: Int64 = 0
    while (i + 1 < b.size) {
        if (b[i] == UInt8(33) && b[i + 1] == UInt8(91)) {  // "![" 
            var j = i + 2
            var found = false
            while (j + 1 < b.size) {
                if (b[j] == UInt8(93) && b[j + 1] == UInt8(40)) {  // "]("
                    found = true
                    break
                }
                j++
            }
            if (found) {
                var u = j + 2
                var urlEndRel = -1
                var urlLen: Int64 = 0
                while (u < b.size) {
                    let c = b[u]
                    if (c == UInt8(41)) {  // ')'
                        urlEndRel = u
                        break
                    }
                    if (c == UInt8(32) || c == UInt8(9)) {
                        break  // 空白（title 语法不支持——保持原样）
                    }
                    urlLen++
                    if (urlLen > 2000) {
                        break
                    }
                    u++
                }
                if (urlEndRel > j + 2) {
                    let url = String.fromUtf8(b[(j + 2)..urlEndRel])
                    out.add(ImgRef(base + j + 2, base + urlEndRel, url))
                    i = urlEndRel
                    continue
                }
                i = j + 2
                continue
            }
            i += 2
            continue
        }
        i++
    }
}

// ── 下载 / 上传 ──

/** raw.gitcode.com 直链的 api.gitcode.com 等价端点（纯函数，单测覆盖）。
 *
 * **实测**：本机访问 `raw.gitcode.com` 会被 CloudWAF 拦成 `HTTP 418`（3223 字节挑战页），
 * 同一张图换 api 端点 `HTTP 200 / 286732 bytes` —— 转存全失败的根因常常是这个，不是图床挂了。
 * 形如 `https://raw.gitcode.com/u/r/raw/main/a/b.png`
 *  → `https://api.gitcode.com/api/v5/repos/u/r/raw/a/b.png?ref=main`
 * 非 raw.gitcode.com 或段数不够时返回空串（表示没有备用端点，别造坏 URL）。 */
public func atomgitApiFallbackUrl(url: String): String {
    let parts = url.split("/")
    // ["https:", "", "raw.gitcode.com", user, repo, "raw", branch, path...]
    if (parts.size < 8) {
        return ""
    }
    if (parts[2] != "raw.gitcode.com" || parts[5] != "raw") {
        return ""
    }
    var path = ""
    var i: Int64 = 7
    while (i < parts.size) {
        if (path.size > 0) {
            path = path + "/"
        }
        path = path + parts[i]
        i++
    }
    if (path.size == 0) {
        return ""
    }
    return "https://api.gitcode.com/api/v5/repos/${parts[3]}/${parts[4]}/raw/${path}?ref=${parts[6]}"
}

/** 单次下载尝试：**不抛异常**，失败原因放第三个返回值——主/备端点要靠返回值串起来，
 * 用异常串会让「备用也失败」这类错误信息丢掉原始原因。 */
func downloadImageTry(url: String): (Bool, Array<Byte>, String) {
    var cb = ClientBuilder()
        .autoRedirect(false)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
    if (url.startsWith("https://")) {
        cb = cb.tlsConfig(TlsClientConfig())
    }
    let client = cb.build()
    let out = ArrayListByte()
    let empty = Array<Byte>(0, repeat: 0)
    var errMsg = ""
    try {
        let resp = client.send(HttpRequestBuilder().url(url).get().header("User-Agent", UA).build())
        let status = Int64(resp.status)
        if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
            resp.close()
            return (false, empty, "图片地址重定向被拒绝（HTTP ${status}）")
        }
        if (status != 200) {
            resp.close()
            return (false, empty, "图片下载 HTTP ${status}")
        }
        let chunk = Array<Byte>(16384, repeat: 0)
        var total: Int64 = 0
        while (true) {
            let n = resp.body.read(chunk)
            if (n <= 0) {
                break
            }
            total += n
            if (total > OBS_MAX_IMG_BYTES) {
                resp.close()
                return (false, empty, "图片超过 ${OBS_MAX_IMG_BYTES} 字节上限")
            }
            var i: Int64 = 0
            while (i < n) {
                out.add(chunk[i])
                i++
            }
        }
        resp.close()
    } catch (e: Exception) {
        errMsg = e.message
    } finally {
        client.close()
    }
    if (errMsg.size > 0) {
        return (false, empty, errMsg)
    }
    if (out.inner.size == 0) {
        return (false, empty, "图片 0 字节（典型防盗链形状）")
    }
    return (true, out.toArray(), "")
}

/** 下载图片（拒 30x：重定向可能把请求带到没检查过的主机；限 12 MiB）。
 * 主端点失败且是 raw.gitcode.com 直链时，自动换 api.gitcode.com 重试一次——
 * 见 atomgitApiFallbackUrl 的实测说明。备用也失败则抛**备用端点的**原因并保留主端点信息。 */
public func downloadImage(url: String): Array<Byte> {
    let (ok, bytes, err) = downloadImageTry(url)
    if (ok) {
        return bytes
    }
    let fb = atomgitApiFallbackUrl(url)
    if (fb.size == 0) {
        throw PubError(err)
    }
    println("  [图片下载] 主端点失败（${err}），改走备用端点 api.gitcode.com")
    let (ok2, bytes2, err2) = downloadImageTry(fb)
    if (ok2) {
        return bytes2
    }
    throw PubError("${err2}（主端点：${err}）")
}

/** 图片扩展名（URL 尾段推断；不在白名单按 png——OBS 侧只影响 Content-Type 与文件名） */
public func extOf(url: String): String {
    let b = url.toArray()
    var lastSlash: Int64 = -1
    var qmark: Int64 = b.size
    var i: Int64 = 0
    while (i < b.size) {
        if (b[i] == UInt8(47)) {
            lastSlash = i
        }
        if (b[i] == UInt8(63) || b[i] == UInt8(35)) {
            qmark = i
            break
        }
        i++
    }
    if (lastSlash + 1 >= qmark) {
        return "png"
    }
    let tail = String.fromUtf8(b[(lastSlash + 1)..qmark])
    let tb = tail.toArray()
    var dot: Int64 = -1
    var j: Int64 = 0
    while (j < tb.size) {
        if (tb[j] == UInt8(46)) {
            dot = j
        }
        j++
    }
    if (dot < 0 || dot + 1 >= tb.size) {
        return "png"
    }
    let e = lowerAscii(String.fromUtf8(tb[(dot + 1)..tb.size]))
    if (e == "jpg" || e == "jpeg" || e == "png" || e == "gif" || e == "webp") {
        return e
    }
    return "png"
}

func appendBytes(acc: ArrayListByte, arr: Array<Byte>): Unit {
    var i: Int64 = 0
    while (i < arr.size) {
        acc.add(arr[i])
        i++
    }
}

/** 组 multipart 表单体：普通字段在前、文件字段收尾（与 CSDN 前端一致的形状） */
public func buildMultipart(boundary: String, fields: Array<StrKV>, fileField: String, filename: String, ctype: String, blob: Array<Byte>): Array<Byte> {
    let acc = ArrayListByte()
    for (kv in fields) {
        appendBytes(acc, ("--${boundary}\r\nContent-Disposition: form-data; name=\"${kv.k}\"\r\n\r\n${kv.v}\r\n").toArray())
    }
    appendBytes(acc, ("--${boundary}\r\nContent-Disposition: form-data; name=\"${fileField}\"; filename=\"${filename}\"\r\nContent-Type: ${ctype}\r\n\r\n").toArray())
    appendBytes(acc, blob)
    appendBytes(acc, ("\r\n--${boundary}--\r\n").toArray())
    return acc.toArray()
}

// ── JSON 取字段（JsonValue 是类，导航必须 match kind()，AGENTS §4） ──

func jsonObjField(v: JsonValue, key: String): Option<JsonValue> {
    match (v.kind()) {
        case JsonKind.JsObject =>
            return v.asObject().get(key)
        case _ =>
            return Option<JsonValue>.None
    }
}

func jsonStr(v: JsonValue, key: String): String {
    if (let Some(x) <- jsonObjField(v, key)) {
        match (x.kind()) {
            case JsonKind.JsString =>
                return x.asString().getValue()
            case _ =>
                return ""
        }
    }
    return ""
}

func jsonInt(v: JsonValue, key: String): Option<Int64> {
    if (let Some(x) <- jsonObjField(v, key)) {
        match (x.kind()) {
            case JsonKind.JsInt =>
                return Option<Int64>.Some(x.asInt().getValue())
            case _ =>
                return Option<Int64>.None
        }
    }
    return Option<Int64>.None
}

/** 取字段的「标量文本」：字符串原样返回，数字/布尔转字面量。
 * 图床签名响应的 customParam 里 isAudit 是数字 1，用 jsonStr 取会得空串，
 * 空串当 x:isAudit 发给 OBS，OBS 就回 HTTP 200 + 0 字节（实测对照过），图也就传不上去。 */
func jsonScalar(v: JsonValue, key: String): String {
    if (let Some(x) <- jsonObjField(v, key)) {
        match (x.kind()) {
            case JsonKind.JsString =>
                return x.asString().getValue()
            case JsonKind.JsInt =>
                return x.asInt().getValue().toString()
            case JsonKind.JsFloat =>
                return x.asFloat().getValue().toString()
            case JsonKind.JsBool =>
                if (x.asBool().getValue()) {
                    return "1"
                }
                return "0"
            case _ =>
                return ""
        }
    }
    return ""
}

/** 上传单张图到 CSDN 图床，返回 csdnimg.cn URL */
public func uploadImage(cookie: String, img: Array<Byte>, ext: String, insecure: Bool): String {
    // ① 签名接口：bizapi（网关 x-ca 签名 + Cookie）
    let sigPath = "/resource-api/v1/image/direct/upload/signature"
    let sign = caSign("POST", sigPath, "application/json")
    let bodyJson = JsonObject()
    bodyJson.put("imageTemplate", JsonString(""))
    bodyJson.put("appName", JsonString("direct_blog_markdown"))
    bodyJson.put("imageSuffix", JsonString(ext))
    var sb = HttpRequestBuilder()
        .url(BIZ + sigPath)
        .post()
        .body(bodyJson.toJsonString())
        .header("Content-Type", "application/json")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Referer", "https://editor.csdn.net/")
        .header("Origin", "https://editor.csdn.net")
        .header("Cookie", cookie)
    if (let Some(v) <- sign.get("x-ca-key")) {
        sb = sb.header("x-ca-key", v)
    }
    if (let Some(v) <- sign.get("x-ca-nonce")) {
        sb = sb.header("x-ca-nonce", v)
    }
    if (let Some(v) <- sign.get("x-ca-signature")) {
        sb = sb.header("x-ca-signature", v)
    }
    if (let Some(v) <- sign.get("x-ca-signature-headers")) {
        sb = sb.header("x-ca-signature-headers", v)
    }
    var cfg = TlsClientConfig()
    if (insecure) {
        cfg.verifyMode = CertificateVerifyMode.TrustAll
    }
    let client = ClientBuilder()
        .tlsConfig(cfg)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
        .build()
    var text = ""
    var status: Int64 = 0
    try {
        let resp = client.send(sb.build())
        status = Int64(resp.status)
        text = readRespText(resp)
        resp.close()
    } finally {
        client.close()
    }
    if (status != 200) {
        throw PubError("图床签名 HTTP ${status}：${truncateUtf8(text, 200)}")
    }
    if (text.size == 0) {
        throw PubError("图床签名响应为空（HTTP 200 但 0 字节，多半被网关/WAF 吞了）")
    }
    let root = JsonValue.fromStr(text)
    var imageUrl = ""
    if (let Some(d) <- jsonObjField(root, "data")) {
        let host = jsonStr(d, "host")
        let filePath = jsonStr(d, "filePath")
        let policy = jsonStr(d, "policy")
        let signature = jsonStr(d, "signature")
        let callbackBody = jsonStr(d, "callbackBody")
        let callbackBodyType = jsonStr(d, "callbackBodyType")
        let callbackUrl = jsonStr(d, "callbackUrl")
        let accessId = jsonStr(d, "accessId")
        var cpRtype = ""
        var cpFilePath = ""
        var cpIsAudit = "0"
        var cpApp = ""
        var cpType = ""
        var cpSuffix = ""
        var cpUser = ""
        if (let Some(c) <- jsonObjField(d, "customParam")) {
            cpRtype = jsonScalar(c, "rtype")
            cpFilePath = jsonScalar(c, "filePath")
            cpIsAudit = jsonScalar(c, "isAudit")
            cpApp = jsonScalar(c, "x-image-app")
            cpType = jsonScalar(c, "type")
            cpSuffix = jsonScalar(c, "x-image-suffix")
            cpUser = jsonScalar(c, "username")
        }
        if (host.size == 0 || policy.size == 0 || filePath.size == 0) {
            throw PubError("图床签名响应缺字段：${truncateUtf8(text, 200)}")
        }
        // ② OBS multipart：policy 授权，免签名免 Cookie
        let boundary = "----cspub" + randomHex(20)
        let fields = [
            StrKV("key", filePath),
            StrKV("policy", policy),
            StrKV("signature", signature),
            StrKV("callbackBody", callbackBody),
            StrKV("callbackBodyType", callbackBodyType),
            StrKV("callbackUrl", callbackUrl),
            StrKV("AccessKeyId", accessId),
            StrKV("x:rtype", cpRtype),
            StrKV("x:filePath", cpFilePath),
            StrKV("x:isAudit", cpIsAudit),
            StrKV("x:x-image-app", cpApp),
            StrKV("x:type", cpType),
            StrKV("x:x-image-suffix", cpSuffix),
            StrKV("x:username", cpUser)
        ]
        let body = buildMultipart(boundary, fields, "file", "image.${ext}", "image/${ext}", img)
        dbg("obs host=${host} body=${body.size}B img=${img.size}B boundary=${boundary}")
        dbg("obs callbackUrl=${callbackUrl} callbackBodyType=${callbackBodyType} accessId=${accessId}")
        dbg("obs callbackBody=${truncateUtf8(callbackBody, 200)}")
        var ocb = ClientBuilder()
            .readTimeout(Duration.second * 60)
            .writeTimeout(Duration.second * 60)
        if (host.startsWith("https://")) {
            ocb = ocb.tlsConfig(TlsClientConfig())
        }
        let oc = ocb.build()
        try {
            let resp = oc.send(HttpRequestBuilder()
                .url(host)
                .post()
                .body(body)
                .header("Content-Type", "multipart/form-data; boundary=${boundary}")
                .header("User-Agent", UA)
                .build())
            let ost = Int64(resp.status)
            let otext = readRespText(resp)
            resp.close()
            dbg("obs status=${ost} respLen=${otext.size} respHead=${truncateUtf8(otext, 300)}")
            if (ost != 200) {
                throw PubError("图床上传 HTTP ${ost}：${truncateUtf8(otext, 200)}")
            }
            if (otext.size == 0) {
                throw PubError("图床上传响应为空（HTTP 200 但 0 字节）")
            }
            // ③ 回调响应：{"code":200,"data":{"imageUrl":"..."}}
            let oroot = JsonValue.fromStr(otext)
            var ocode: Int64 = -1
            if (let Some(c) <- jsonInt(oroot, "code")) {
                ocode = c
            }
            if (let Some(od) <- jsonObjField(oroot, "data")) {
                imageUrl = jsonStr(od, "imageUrl")
            }
            if (ocode != 200 || imageUrl.size == 0) {
                throw PubError("图床上传响应异常：${truncateUtf8(otext, 200)}")
            }
        } finally {
            oc.close()
        }
    }
    if (imageUrl.size == 0) {
        throw PubError("图床签名响应缺 data：${truncateUtf8(text, 200)}")
    }
    return imageUrl
}

/** `imgs` 预演的处置标签（纯函数，单测覆盖）。
 * 本地绝对路径在 publish 时会被读文件上传（rehostImages 的 `/` 分支），
 * 所以不能标成 skip——那会让人误判「这张图不会转存」。 */
public func imgPreviewAction(url: String): String {
    let host = hostOf(url)
    if (isCsdnImageHost(host)) {
        return "skip (already csdn)"
    }
    if (!url.startsWith("http://") && !url.startsWith("https://")) {
        if (url.startsWith("/")) {
            return "upload (local file)"
        }
        return "skip (not http)"
    }
    if (isBlockedHost(host)) {
        return "BLOCKED (non-public)"
    }
    return "rehost"
}

/** 正文里残留的本地图片张数（非 http、非 data:）——转存收尾仍有残留＝页面上是死链 */
public func localImageCount(md: String): Int64 {
    var n: Int64 = 0
    for (img in findExternalImages(md)) {
        let src = img.url
        if (!src.startsWith("http://") && !src.startsWith("https://") && !src.startsWith("data:")) {
            n++
        }
    }
    return n
}

/** 严格图片门禁：CSPUB_STRICT_IMAGES=1/true/yes 时，图片没转存成功就中止发布。
 * 默认不是严格模式——单张失败照发（AGENTS：图片 best-effort 不阻断发文）。 */
public func strictImagesEnabled(): Bool {
    match (getVariable("CSPUB_STRICT_IMAGES")) {
        case Some(v) =>
            let t = trimAscii(v)
            return t == "1" || t == "true" || t == "yes"
        case None => return false
    }
}

/** 图片转存收口：残留本地图片时打醒目告警（现状：全失败也只打一行「失败 N」，文章照发成死链）。
 * 返回 true＝调用方应中止发布（仅 strict 时），false＝best-effort 继续。
 * strict 由调用方传 strictImagesEnabled()，让本函数保持纯逻辑、可单测。 */
public func imagesRemainGate(platform: String, md: String, strict: Bool): Bool {
    let n = localImageCount(md)
    if (n <= 0) {
        return false
    }
    println("⚠⚠ 图片未转存成功：正文仍有 ${n} 张本地图片（${platform}），发布后这些图是死链/裂图")
    println("     排查：图床凭证过期？掘金/知乎建议配 CSPUB_ATOMGIT_TOKEN 走外链；ImageX 签名失配见 docs 踩坑记录")
    if (strict) {
        println("     已按 CSPUB_STRICT_IMAGES 中止发布；去掉该环境变量即按 best-effort 继续")
        return true
    }
    return false
}

/** 图片转存「部分失败」门禁（纯函数，单测覆盖）：头条这类平台只要有一张图不在自家 CDN
 * 就整篇拒稿（7115），明知必败还提交等于白烧一次每日发文额度（头条约 4 篇/天）。
 * 默认中止，`--force` 才继续。返回 true＝调用方应中止。 */
public func rehostFailGate(platform: String, failCount: Int64, force: Bool): Bool {
    if (failCount <= 0) {
        return false
    }
    println("✗ 图片转存未全部成功：${failCount} 张失败（${platform}）")
    println("  ${platform} 对非本平台域名的图会整篇拒稿（头条 7115），提交很可能白费一次发文额度")
    if (force) {
        println("  已按 --force 继续提交——若被拒稿，先查登录态与图床连通性，别往文章上找原因")
        return false
    }
    println("  选择：① 直接重跑（图床上传带重传，瞬时失败常能过）")
    println("        ② 删掉或替换这几张图后重发")
    println("        ③ 明知有风险仍要提交：加 --force")
    return true
}

/** 把 Markdown 里的站外图全部转存到 CSDN 图床并回写 URL（从后往前替换，偏移不挪位）。
 * best-effort：单张失败保留原链接并提示，不阻断发文。 */
public func rehostImages(cookie: String, md: String, insecure: Bool): String {
    let imgs = findExternalImages(md)
    var done: Int64 = 0
    var failed: Int64 = 0
    var skipped: Int64 = 0
    var result = md
    var idx: Int64 = imgs.size - 1
    while (idx >= 0) {
        let m = imgs[idx]
        idx--
        let host = hostOf(m.url)
        if (isCsdnImageHost(host)) {
            skipped++
            continue
        }
        if (!m.url.startsWith("http://") && !m.url.startsWith("https://")) {
            // 本地绝对路径：由外部先落盘（如 curl 下载——stdx TLS 栈与部分站点握手不兼容时的
            // 兜底通路），这里直接读文件走同一条图床链路。其余（data: 等）原样保留。
            if (m.url.startsWith("/")) {
                try {
                    let img = File.readFrom(m.url)
                    let newUrl = uploadImage(cookie, img, extOf(m.url), insecure)
                    result = result[0..m.urlStart] + newUrl + result[m.urlEnd..result.size]
                    done++
                    println("图片转存(本地) ${done}: ${m.url} -> ${newUrl}")
                } catch (e: Exception) {
                    failed++
                    println("⚠ 本地图片转存失败：${m.url} — ${e.message}")
                }
                continue
            }
            skipped++  // data: 等原样保留
            continue
        }
        if (isBlockedHost(host)) {
            failed++
            println("⚠ 跳过非公网图片地址：${m.url}")
            continue
        }
        try {
            let img = downloadImage(m.url)
            let ext = extOf(m.url)
            let newUrl = uploadImage(cookie, img, ext, insecure)
            result = result[0..m.urlStart] + newUrl + result[m.urlEnd..result.size]
            done++
            println("图片转存 ${done}: ${host} -> ${newUrl}")
        } catch (e: Exception) {
            failed++
            println("⚠ 图片转存失败（保留原链接）：${m.url} — ${e.message}")
        }
    }
    if (done + failed > 0) {
        println("图片转存完成：成功 ${done} / 失败 ${failed} / 无需处理 ${skipped}")
    } else if (skipped > 0) {
        println("图片无需转存（${skipped} 张已在 CSDN 图床）")
    }
    return result
}
