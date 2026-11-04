/** 通用小工具：文件读取 / ASCII 修剪 / Cookie 取值 / 随机 nonce / UTF-8 安全截断 */
package cspub

import std.collection.*
import std.fs.*
import std.random.*
import stdx.crypto.common.*
import stdx.crypto.x509.*
import stdx.encoding.hex.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/** 业务级失败（带可读信息，rehost 的 best-effort 链路靠它传递原因） */
public class PubError <: Exception {
    public init(msg: String) {
        super(msg)
    }
}

/** 读整个响应体为文本（csdn.cj 与 images.cj 共用） */
public func readRespText(resp: HttpResponse): String {
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
    return String.fromUtf8(acc.toArray())
}

/** 整文件读为文本（循环读到 EOF 再拼 UTF-8；异常抛给调用方给可行动报错） */
public func readTextFileAll(path: String): String {
    let f = File(path, OpenMode.Read)
    let buf = Array<Byte>(16384, repeat: 0)
    let acc = ArrayListByte()
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
    return String.fromUtf8(acc.toArray())
}

/** ArrayList<Byte> 的薄包装：跨函数传递时少写泛型 */
public class ArrayListByte {
    public let inner: ArrayList<Byte>
    public init() {
        inner = ArrayList<Byte>()
    }
    public func add(b: Byte): Unit {
        inner.add(b)
    }
    public func toArray(): Array<Byte> {
        return inner.toArray()
    }
}

/** 修剪两端 ASCII 空白（空格/制表/回车/换行）；边界都是 ASCII 字节，不会切开多字节字符 */
public func trimAscii(s: String): String {
    let b = s.toArray()
    var i: Int64 = 0
    var j: Int64 = Int64(b.size)
    while (i < j && isWs(b[i])) {
        i++
    }
    while (j > i && isWs(b[j - 1])) {
        j--
    }
    if (i >= j) {
        return ""
    }
    return String.fromUtf8(b[i..j])
}

func isWs(b: Byte): Bool {
    return b == UInt8(32) || b == UInt8(9) || b == UInt8(13) || b == UInt8(10)
}

/** 从 Cookie 串里取某个 cookie 的值（按「name=」前缀找，分号分隔） */
public func cookieValue(cookie: String, name: String): String {
    for (p in cookie.split(";")) {
        let t = trimAscii(p)
        if (t.startsWith(name + "=")) {
            return t[(name.size + 1)..t.size]
        }
    }
    return ""
}

/** 随机 n 字节的 hex 串（x-ca-nonce 用；v4 UUID 形状，不需要真时间戳） */
public func randomHex(nBytes: Int64): String {
    let r = Random()
    let buf = Array<Byte>(nBytes, repeat: 0)
    r.nextBytes(buf)
    return toHexString(buf)
}

/** UTF-8 安全截断：最多 maxBytes 字节，且不在多字节字符中间切开（按首字节判界，AGENTS §4） */
public func truncateUtf8(s: String, maxBytes: Int64): String {
    if (s.size <= maxBytes) {
        return s
    }
    let b = s.toArray()
    var cut: Int64 = maxBytes
    // 回退到「首字节」边界：(b & 0xC0) != 0x80 才是一个字符的开始
    while (cut > 0 && (b[cut] & UInt8(0xC0)) == UInt8(0x80)) {
        cut--
    }
    if (cut <= 0) {
        return ""
    }
    return String.fromUtf8(b[0..cut])
}

/** 去 Markdown 标记的粗略纯文本（摘要用）：去代码围栏行、行首 # 与列表符、图片/链接保留文字 */
public func stripMarkdown(md: String): String {
    let lines = md.split("\n", -1)
    var out = StringBuilder()
    var inCode = false
    for (l in lines) {
        let t = trimAscii(l)
        if (t.startsWith("```")) {
            inCode = !inCode
            continue
        }
        if (inCode) {
            continue
        }
        if (t.size == 0) {
            continue
        }
        var line = t
        // 行首标记：# / > / - / * / 数字.
        while (line.size > 0 && (line.startsWith("#") || line.startsWith(">") || line.startsWith("- ") || line.startsWith("* "))) {
            line = trimAscii(line[1..line.size])
        }
        out.append(line)
        out.append(" ")
    }
    return trimAscii(out.toString())
}

// ── 多平台共用 HTTP 执行 ──

/** 一次 HTTP 请求的结果：状态码 + 响应体文本 */
public class HttpResp {
    public var status: Int64
    public var text: String
    public init(status: Int64, text: String) {
        this.status = status
        this.text = text
    }
}

/** 批量设置请求头（builder.header 链式，逐个赋回） */
public func applyHeaders(builder: HttpRequestBuilder, headers: Array<StrKV>): HttpRequestBuilder {
    var b = builder
    for (h in headers) {
        b = b.header(h.k, h.v)
    }
    return b
}

/** 发请求并读回状态码与响应体。TLS 默认 CustomCA（系统根集 + 追加 Certum 根，
 * 与 csdn.cj 同一套，各平台链都能验）；insecure = TrustAll（诊断/自担风险）。 */
public func execRequest(req: HttpRequest, insecure: Bool): HttpResp {
    var cfg = TlsClientConfig()
    if (insecure) {
        cfg.verifyMode = CertificateVerifyMode.TrustAll
    } else {
        let x509s = X509Certificate.decodeFromPem(CERTUM_ROOT_PEM)
        let roots = Array<Certificate>(x509s.size, repeat: x509s[0])
        var ri = 0
        while (ri < x509s.size) {
            roots[ri] = x509s[ri]
            ri += 1
        }
        cfg.verifyMode = CertificateVerifyMode.CustomCA(roots)
    }
    let client = ClientBuilder()
        .tlsConfig(cfg)
        .readTimeout(Duration.second * 30)
        .writeTimeout(Duration.second * 30)
        .build()
    try {
        let resp = client.send(req)
        let text = readRespText(resp)
        let status = Int64(resp.status)
        resp.close()
        return HttpResp(status, text)
    } finally {
        client.close()
    }
}
