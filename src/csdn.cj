/** CSDN bizapi 客户端：阿里云网关风格 HMAC-SHA256 签名 + saveArticle 调用 */
package cspub

import stdx.crypto.digest.*
import stdx.crypto.x509.*
import stdx.encoding.base64.*
import std.collection.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*

/**
 * CSDN 链的根是 Certum（小众 CA）：stdx 的默认信任集（Default 模式走 systemRootCerts 的
 * bundle 路径）没吃进系统哈希目录里的它——实测 /etc/ssl/certs/ca-certificates.crt 里 0 处
 * Certum，而 /etc/ssl/certs/48bec511.0 软链指向的根与 CSDN 链上那张逐字节相同（sha256 同）。
 * 正解是 CustomCA 模式：在系统根集**之外追加**这张公开根证书（stdx handshake.cj 的
 * CustomCA 分支 = 自定义 CA + systemRootCerts 一起装）。公开根证书非机密，随源码内嵌。
 */
public const CERTUM_ROOT_PEM: String = """
-----BEGIN CERTIFICATE-----
MIIDuzCCAqOgAwIBAgIDBETAMA0GCSqGSIb3DQEBBQUAMH4xCzAJBgNVBAYTAlBM
MSIwIAYDVQQKExlVbml6ZXRvIFRlY2hub2xvZ2llcyBTLkEuMScwJQYDVQQLEx5D
ZXJ0dW0gQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxIjAgBgNVBAMTGUNlcnR1bSBU
cnVzdGVkIE5ldHdvcmsgQ0EwHhcNMDgxMDIyMTIwNzM3WhcNMjkxMjMxMTIwNzM3
WjB+MQswCQYDVQQGEwJQTDEiMCAGA1UEChMZVW5pemV0byBUZWNobm9sb2dpZXMg
Uy5BLjEnMCUGA1UECxMeQ2VydHVtIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MSIw
IAYDVQQDExlDZXJ0dW0gVHJ1c3RlZCBOZXR3b3JrIENBMIIBIjANBgkqhkiG9w0B
AQEFAAOCAQ8AMIIBCgKCAQEA4/t9o3K6wvDJFIf1awFO4W5AB7ptJ11/91sts1rH
UV+rpDKmYYe2bg+G0jACl/jXaVehGDldamR5xgFZrDwxSjh80gTSSyjoIF87B6LM
TXPb865Px1bVWqeWifrzq2jUI4ZZJ88JJ7ysbnKDHDBy3+Ci6dLhdHUZvSqeexVU
BBvXQzmtVSjF4hq79MDkrjhJM8x2hZ85RdKknvISjFH4fOQtf/WsX+sWn7Et0brM
kUJ3TCXJkDhv2/DM+44el1k+1WBO5gUo7Ul5E0u6SNsv+XLTOcr+H9g0cvW0QM8x
AcPs3hEtF10fuFDRXhmnad4HMyjKUJX5p1TLVIZQRan5SQIDAQABo0IwQDAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBQIds3LB/8k9sXN7buQvOKEN0Z19zAOBgNV
HQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQEFBQADggEBAKaorSLOAT2mo/9i0Eidi15y
sHhE49wcrwn9I0j6vSrEuVUEtRCjjSfeC4Jj0O7eDDd5QVsisrCaQVymcODU0HfL
I9MA4GxWL+FpDQ3Zqr8hgVDZBqWo/5U30Kr+4rP1mS1FhIrlQgnXdAIv94nYmem8
J9RHjboNRhx3zxSkHLmkMcScKHQDNP8zGSal6Q10tz6XxnboJ5ajZt3hrvJBW8qY
VoNzcOSGGtIxQbovvi0TWnZvTuhOgQ4/WwMioBK+ZlgRSssDxLQqKi2WF+A5VLxI
03YnnZotBqbJ7DnSq9ufmgsnAjUpsUCV5/nonFWIGUbWtzT1fs45mtk48VH3Tyw=
-----END CERTIFICATE-----
"""

/** x-ca 签名常量：烙在 CSDN 公开的前端 JS 里（非账号机密） */
public const CA_KEY: String = "203803574"
public const CA_SECRET: String = "9znpamsyl2c7cdrr9sas0le9vbc3r6ba"

public const BIZ: String = "https://bizapi.csdn.net"
public const UA: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

/** 阿里云 API 网关风格的 StringToSign：方法 + Accept + Content-Type + 签名头 + path?query */
public func caSign(method: String, pathWithQuery: String, contentType: String): HashMap<String, String> {
    return caSignWithNonce(method, pathWithQuery, contentType, randomHex(16))
}

/** 签名的确定性版本（nonce 由调用方给）：`sig` 调试命令走它，与 Python 逐字节对账用 */
public func caSignWithNonce(method: String, pathWithQuery: String, contentType: String, nonce: String): HashMap<String, String> {
    let sts = method + "\n*/*\n\n" + contentType + "\n\n" +
        "x-ca-key:" + CA_KEY + "\nx-ca-nonce:" + nonce + "\n" + pathWithQuery
    let mac = HMAC(CA_SECRET.toArray(), HashType.SHA256)
    mac.write(sts.toArray())
    let sig = toBase64String(mac.finish())
    let m = HashMap<String, String>()
    m.add("x-ca-key", CA_KEY)
    m.add("x-ca-nonce", nonce)
    m.add("x-ca-signature", sig)
    m.add("x-ca-signature-headers", "x-ca-key,x-ca-nonce")
    return m
}

/** 发布结果：成功给文章 URL 与 id */
public class PublishResult {
    public var url: String
    public var id: String
    public init(url: String, id: String) {
        this.url = url
        this.id = id
    }
}

/** 组 saveArticle 请求体并发送；updateId 非空 = 原地更新。
 * insecure = TrustAll（跳过 TLS CA 校验）：仅用于诊断/自担风险——本机 CustomCA/Default 两种模式
 * 对 CSDN 链（Certum 根）都报 unknown CA，而系统 curl 验同一条链 OK，疑 stdx 动态加载的 OpenSSL
 * 验证行为问题（已记录待查）；发正式文章时请优先试默认模式，401/403 再考虑 --insecure。 */
public func publishToCsdn(cookie: String, a: Article, updateId: String, publishNow: Bool, insecure: Bool): Int64 {
    let path = "/blog-console-api/v3/mdeditor/saveArticle"
    let html = mdToHtml(a.body)
    // 摘要：front-matter 的 desc 优先；没有就从正文剥 Markdown 取前 200 字
    var desc = a.desc
    if (desc.size == 0) {
        desc = truncateUtf8(stripMarkdown(a.body), 200)
    }
    let body = JsonObject()
    if (updateId.size > 0) {
        body.put("id", JsonInt(Int64.parse(updateId)))
    }
    body.put("title", JsonString(a.title))
    // content 必须是**渲染后的 HTML**（发 markdown 原文会显示字面 ##/![]()）；markdowncontent 存编辑器源
    body.put("content", JsonString(html))
    body.put("markdowncontent", JsonString(a.body))
    body.put("readType", JsonString("public"))
    body.put("status", JsonInt(if (publishNow) { 0 } else { 2 }))
    body.put("categories", JsonString(a.categories))
    body.put("tags", JsonString(a.tags))
    body.put("type", JsonString("original"))
    body.put("original_link", JsonString(""))
    body.put("authorized_status", JsonBool(false))
    body.put("Description", JsonString(desc))
    body.put("not_auto_saved", JsonString("1"))
    body.put("source", JsonString("pc_mdeditor"))
    body.put("cover_images", JsonArray())
    body.put("cover_type", JsonInt(0))
    body.put("is_new", JsonInt(if (updateId.size > 0) { 0 } else { 1 }))
    body.put("vote_id", JsonInt(0))
    body.put("pubStatus", JsonString(if (publishNow) { "publish" } else { "draft" }))
    let payload = body.toJsonString()

    let sign = caSign("POST", path, "application/json")
    var builder = HttpRequestBuilder()
        .url(BIZ + path)
        .post()
        .body(payload)
        .header("Content-Type", "application/json")
        .header("User-Agent", UA)
        .header("Accept", "*/*")
        .header("Referer", "https://editor.csdn.net/")
        .header("Origin", "https://editor.csdn.net")
        .header("Cookie", cookie)
    match (sign.get("x-ca-key")) {
        case Some(v) => builder = builder.header("x-ca-key", v)
        case None => ()
    }
    match (sign.get("x-ca-nonce")) {
        case Some(v) => builder = builder.header("x-ca-nonce", v)
        case None => ()
    }
    match (sign.get("x-ca-signature")) {
        case Some(v) => builder = builder.header("x-ca-signature", v)
        case None => ()
    }
    match (sign.get("x-ca-signature-headers")) {
        case Some(v) => builder = builder.header("x-ca-signature-headers", v)
        case None => ()
    }

    // TLS：显式配（仓颉 HTTP 客户端不带默认 TLS）。默认 CustomCA(系统 Certum 根)；
    // --insecure 走 TrustAll（跳过校验，自担风险）。
    var cfg = TlsClientConfig()
    if (insecure) {
        cfg.verifyMode = TrustAll
    } else {
        let roots = X509Certificate.decodeFromPem(CERTUM_ROOT_PEM)
        cfg.verifyMode = CustomCA(roots)
    }
    let client = ClientBuilder()
        .tlsConfig(cfg)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
        .build()
    var status: Int64 = 0
    var respText = ""
    try {
        let resp = client.send(builder.build())
        status = Int64(resp.status)
        let chunk = Array<Byte>(8192, repeat: 0)
        let acc = ArrayListByte()
        var n = resp.body.read(chunk)
        while (n > 0) {
            var i: Int64 = 0
            while (i < n) {
                acc.add(chunk[i])
                i++
            }
            n = resp.body.read(chunk)
        }
        respText = String.fromUtf8(acc.toArray())
        resp.close()
    } finally {
        client.close()
    }

    if (status != 200) {
        println("错误：CSDN 返回 HTTP ${status}")
        println(respText)
        if (status == 401 || status == 403) {
            println("提示：Cookie 多半过期了——重新从浏览器复制（whoami 只验格式，不验有效性）")
        }
        return 1
    }
    // 解析响应 { code, data: { url, id, title }, msg }
    let root = JsonValue.fromStr(respText)
    var code: Int64 = -1
    var url = ""
    var id = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let obj = root.asObject()
            if (let Some(c) <- obj.get("code")) {
                match (c.kind()) {
                    case JsonKind.JsInt => code = c.asInt().getValue()
                    case _ => ()
                }
            }
            if (let Some(d) <- obj.get("data")) {
                match (d.kind()) {
                    case JsonKind.JsObject =>
                        let dobj = d.asObject()
                        if (let Some(u) <- dobj.get("url")) {
                            match (u.kind()) {
                                case JsonKind.JsString => url = u.asString().getValue()
                                case _ => ()
                            }
                        }
                        if (let Some(i) <- dobj.get("id")) {
                            match (i.kind()) {
                                case JsonKind.JsInt => id = i.asInt().getValue().toString()
                                case _ => ()
                            }
                        }
                    case _ => ()
                }
            }
        case _ => ()
    }
    if (code != 200) {
        println("错误：CSDN 业务返回 code=${code}")
        println(respText)
        return 1
    }
    if (url.size > 0) {
        println("文章链接：${url}")
    } else {
        println("已保存（草稿在 CSDN 后台可见）")
    }
    if (id.size > 0) {
        println("文章 id  ：${id}（更新用：--update ${id}）")
    }
    return 0
}
