/** 图片转存：CSDN 对站外图有防盗链（典型形状「HTTP 200 + 0 字节」，AGENTS §4 同款）——
 * 外链图必须先传 CSDN 图床（csdnimg.cn）再发文。
 * 流程镜像 CSDN 编辑器前端：①签名接口（bizapi，网关 HMAC + Cookie）→ ②华为 OBS multipart
 * （policy 授权，免签名免 Cookie）→ ③回调返回 csdnimg.cn URL，回写进 Markdown。 */
package cspub

import std.collection.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*

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

/** 下载图片（拒 30x：重定向可能把请求带到没检查过的主机；限 12 MiB） */
public func downloadImage(url: String): Array<Byte> {
    var cb = ClientBuilder()
        .autoRedirect(false)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
    if (url.startsWith("https://")) {
        cb = cb.tlsConfig(TlsClientConfig())
    }
    let client = cb.build()
    let out = ArrayListByte()
    try {
        let resp = client.send(HttpRequestBuilder().url(url).get().header("User-Agent", UA).build())
        let status = Int64(resp.status)
        if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
            resp.close()
            throw PubError("图片地址重定向被拒绝（HTTP ${status}）")
        }
        if (status != 200) {
            resp.close()
            throw PubError("图片下载 HTTP ${status}")
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
                throw PubError("图片超过 ${OBS_MAX_IMG_BYTES} 字节上限")
            }
            var i: Int64 = 0
            while (i < n) {
                out.add(chunk[i])
                i++
            }
        }
        resp.close()
    } finally {
        client.close()
    }
    if (out.inner.size == 0) {
        throw PubError("图片 0 字节（典型防盗链形状）")
    }
    return out.toArray()
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
        cfg.verifyMode = TrustAll
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
            cpRtype = jsonStr(c, "rtype")
            cpFilePath = jsonStr(c, "filePath")
            cpIsAudit = jsonStr(c, "isAudit")
            cpApp = jsonStr(c, "x-image-app")
            cpType = jsonStr(c, "type")
            cpSuffix = jsonStr(c, "x-image-suffix")
            cpUser = jsonStr(c, "username")
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
            if (ost != 200) {
                throw PubError("图床上传 HTTP ${ost}：${truncateUtf8(otext, 200)}")
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
