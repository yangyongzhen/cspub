/** 博客园发文客户端：官方 MetaWeblog API（XML-RPC），纯 HTTP 零浏览器。
 * 端点 https://rpc.cnblogs.com/metaweblog/<博客名>；鉴权用 MetaWeblog 登录名 +
 * 访问令牌（后台「设置 → 允许博客客户端访问」里生成，不是登录密码）。
 * 正文传 Markdown 原文时 categories 必须带 "[Markdown]"，否则博客园不按 MD 渲染。
 * 参考：cnblogs MetaWeblog 官方文档页 + 社区实测（pycnblog / mliu / suyj）。 */
package cspub

import std.collection.*
import std.time.*
import stdx.net.http.*

public const CNBLOGS_RPC_BASE: String = "https://rpc.cnblogs.com/metaweblog/"

/** XML 转义（XML-RPC string value 用）。按 Rune 迭代——逐字节转码会把多字节字符
 * 拆成非法 UTF-8 序列（踩坑记录 2 同款）。 */
public func xmlEscape(s: String): String {
    var out = StringBuilder()
    for (r in s.runes()) {
        if (r == r'&') {
            out.append("&amp;")
        } else if (r == r'<') {
            out.append("&lt;")
        } else if (r == r'>') {
            out.append("&gt;")
        } else {
            out.append(r.toString())
        }
    }
    return out.toString()
}

/** Unix 时间戳 → XML-RPC dateTime.iso8601（YYYYMMDDTHH:MM:SS，UTC）。
 * 与 rfc1123FromUnix 同一套 civil 日历算法；1970-01-01 是周四。 */
public func iso8601FromUnix(unix: Int64): String {
    let days = unix / 86400
    let rem = unix % 86400
    let hour = rem / 3600
    let minute = (rem % 3600) / 60
    let second = rem % 60
    let z = days + 719468
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
    return "${y}${pad2(m)}${pad2(d)}T${pad2(hour)}:${pad2(minute)}:${pad2(second)}"
}

/** 组 metaWeblog.newPost 的 XML-RPC 请求体（纯函数，供测试对账）。
 * description 传 Markdown 原文（categories 带 [Markdown] 时博客园按 MD 渲染）。 */
public func buildCnblogsNewPostXml(blogId: String, username: String, token: String,
    title: String, description: String, categories: Array<String>, keywords: String,
    publish: Bool, dateIso: String): String {

    var sb = StringBuilder()
    sb.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<methodCall>\n<methodName>metaWeblog.newPost</methodName>\n<params>\n")
    // blogid（博客园下不影响结果，传博客名或空串）
    sb.append("<param><value><string>${xmlEscape(blogId)}</string></value></param>\n")
    sb.append("<param><value><string>${xmlEscape(username)}</string></value></param>\n")
    sb.append("<param><value><string>${xmlEscape(token)}</string></value></param>\n")
    // struct Post
    sb.append("<param><value><struct>\n")
    sb.append("<member><name>title</name><value><string>${xmlEscape(title)}</string></value></member>\n")
    sb.append("<member><name>description</name><value><string>${xmlEscape(description)}</string></value></member>\n")
    sb.append("<member><name>dateCreated</name><value><dateTime.iso8601>${dateIso}</dateTime.iso8601></value></member>\n")
    sb.append("<member><name>mt_keywords</name><value><string>${xmlEscape(keywords)}</string></value></member>\n")
    sb.append("<member><name>categories</name><value><array><data>\n")
    for (c in categories) {
        sb.append("<value><string>${xmlEscape(c)}</string></value>\n")
    }
    sb.append("</data></array></value></member>\n")
    sb.append("</struct></value></param>\n")
    sb.append("<param><value><boolean>${if (publish) { "1" } else { "0" } }</boolean></value></param>\n")
    sb.append("</params>\n</methodCall>")
    return sb.toString()
}

/** 解析 XML-RPC 响应：成功回 postid 字符串；fault 回空串并带出 faultString。
 * 手写浅解析（只找 <string>/fault），不引 XML 库。 */
public func parseCnblogsPostId(respText: String): String {
    // fault 响应：返回空串
    if (respText.contains("<name>faultCode</name>")) {
        return ""
    }
    // newPost 成功响应只有一个 <param><value><string>postid</string></value>…
    let tag = "<string>"
    let start = findSub(respText, tag)
    if (start < 0) {
        return ""
    }
    let from = start + tag.size
    let end = findSub(respText[from..respText.size], "</string>")
    if (end < 0) {
        return ""
    }
    return respText[from..(from + end)]
}

/** 从 fault 响应里取 faultString（给可行动报错用） */
public func parseCnblogsFault(respText: String): String {
    if (!respText.contains("<name>faultString</name>")) {
        return ""
    }
    let tag = "<string>"
    let key = findSub(respText, "<name>faultString</name>")
    if (key < 0) {
        return ""
    }
    let rest = respText[key..respText.size]
    let start = findSub(rest, tag)
    if (start < 0) {
        return ""
    }
    let from = start + tag.size
    let end = findSub(rest[from..rest.size], "</string>")
    if (end < 0) {
        return ""
    }
    return rest[from..(from + end)]
}

/** 子串查找（返回首下标，无则 -1）——std.core String 无原生 indexOf 的兜底 */
public func findSub(haystack: String, needle: String): Int64 {
    let h = haystack.toArray()
    let n = needle.toArray()
    if (n.size == 0 || n.size > h.size) {
        return -1
    }
    var i: Int64 = 0
    while (i + n.size <= h.size) {
        var j: Int64 = 0
        var matched = true
        while (j < n.size) {
            if (h[i + j] != n[j]) {
                matched = false
                break
            }
            j++
        }
        if (matched) {
            return i
        }
        i++
    }
    return -1
}

/** 博客园发文入口。publishNow=false 存草稿（博客园后台可见）。
 * 正文直接传 Markdown 原文 + categories 带 [Markdown]，博客园服务端渲染。
 * 图片：博客园对站外图无防盗链，外链图可直接引用，不做转存。
 * 注意：cnblogs 端点证书链不完整（社区实测），默认 CustomCA 失败时加 --insecure。 */
public func publishToCnblogs(blogId: String, username: String, token: String,
    a: Article, publishNow: Bool, insecure: Bool): Int64 {

    // categories：[Markdown] 打头 + front-matter 的分类（逗号分隔拆开）
    var cats: ArrayList<String> = ArrayList<String>()
    cats.add("[Markdown]")
    for (p in a.categories.split(",", -1)) {
        let t = trimAscii(p)
        if (t.size > 0) {
            cats.add(t)
        }
    }
    // 摘要：front-matter desc 优先，没有从正文剥 Markdown 取前 200 字（mt_excerpt 选填带上）
    var excerpt = a.desc
    if (excerpt.size == 0) {
        excerpt = truncateUtf8(stripMarkdown(a.body), 200)
    }

    let nowUnix = Int64(DateTime.now(timeZone: TimeZone.UTC).toUnixTimeStamp() / Duration.second)
    let payload = buildCnblogsNewPostXml(blogId, username, token, a.title, a.body,
        cats.toArray(), a.tags, publishNow, iso8601FromUnix(nowUnix))

    let builder = HttpRequestBuilder()
        .url(CNBLOGS_RPC_BASE + blogId)
        .post()
        .body(payload)
        .header("Content-Type", "text/xml; charset=utf-8")
    let req = applyHeaders(builder, [
        StrKV("User-Agent", UA),
        StrKV("Accept", "*/*"),
    ]).build()
    let mode = if (publishNow) { "publish" } else { "draft" }
    println("博客园：提交（${mode}）…")
    let resp = execRequest(req, insecure)
    if (resp.status != 200) {
        println("错误：博客园返回 HTTP ${resp.status}")
        println(resp.text)
        if (resp.status == 403) {
            println("提示：403 多为后台未开启「允许 MetaWeblog 博客客户端访问」（i.cnblogs.com/settings）")
        }
        return 1
    }
    let fault = parseCnblogsFault(resp.text)
    if (fault.size > 0) {
        println("错误：博客园 XML-RPC fault：${fault}")
        if (fault.contains("令牌") || fault.contains("密码") || fault.contains("用户名")) {
            println("提示：用户名须为后台 MetaWeblog 设置页显示的登录名，密码框填访问令牌（非登录密码）")
        }
        return 1
    }
    let postId = parseCnblogsPostId(resp.text)
    if (postId.size == 0) {
        println("错误：博客园响应里没有 postid")
        println(resp.text)
        return 1
    }
    if (publishNow) {
        println("文章链接：https://www.cnblogs.com/${blogId}/p/${postId}")
    } else {
        println("草稿已保存（postid ${postId}，博客园后台「随笔」列表可见）")
    }
    println("postid  ：${postId}")
    return 0
}
