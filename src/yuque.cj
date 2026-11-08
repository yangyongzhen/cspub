/** 语雀发文：走官方 OpenAPI v2（Token 鉴权），和 Cookie 体系无关，是全部平台里最稳的一条通道。
 *
 * 接口规格（官方 spec spec/yuque-openapi.yaml，2026-11 核对）：
 *   POST https://www.yuque.com/api/v2/repos/{namespace}/docs
 *   鉴权：Header `X-Auth-Token: <token>`（不需要 Cookie / Referer / Origin）
 *   请求体：{"title":..., "body":..., "format":"markdown", "slug"?:..., "public"?:0|1|2}
 *           **body 是唯一必填**；format 默认 markdown——原样提交 Markdown，别预渲染成 HTML
 *           public：0 私密 / 1 公开 / 2 企业内公开，**不传则继承知识库的公开性**
 *   响应：{"data":{"id":123,"slug":"abc","title":"..."}} → 文档地址 https://www.yuque.com/{namespace}/{slug}
 *   错误：400 参数非法 / 401 Token 未通过鉴权 / 403 无操作权限 / 404 实体未找到 /
 *         422 参数校验失败 / 429 频率超限 / 500 内部错误
 *
 * 两个官方明示的坑：
 * ① **创建后不会自动加入知识库目录**，需要再调「知识库目录更新接口」；这是纯展示问题，
 *    文档本身已经存在且可通过直链访问，所以这里不代劳，只在成功输出里提示一句。
 * ② namespace 是两段式 `user/repo` 或 `group/book_slug`。写成单段（例如只写知识库名）必 404——
 *    这是用户配错时最常见的报错，所以进来先本地校验，不要拿一个必然 404 的请求去测 Token。
 */
package cspub

import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

public const YUQUE_API: String = "https://www.yuque.com/api/v2"
public const YUQUE_SITE: String = "https://www.yuque.com"
// 版本串唯一真相在 cjpm.toml 的 version，发版时随此处一并更新（其余平台 UA 不带版本号）
const YUQUE_UA: String = "cspub/0.3.2 (+https://atomgit.com/qq8864/cspub)"

/** namespace 合法性：`user/repo` 或 `group/book_slug` 两段式，两段都不能空。
 * 单段名字会 404（不是权限问题），本地先拦掉能省一轮误判。 */
public func yuqueNamespaceValid(ns: String): Bool {
    let t = trimAscii(ns)
    if (t.size == 0) {
        return false
    }
    let parts = t.split("/", -1)
    if (parts.size != 2) {
        return false
    }
    return trimAscii(parts[0]).size > 0 && trimAscii(parts[1]).size > 0
}

/** 创建文档请求体（纯函数，单测覆盖）。
 * publicLevel < 0 表示「不传该字段」，交给语雀继承知识库的公开性。 */
public func buildYuqueDocBody(title: String, docBody: String, slug: String, publicLevel: Int64): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    // body 是唯一必填字段，format 固定 markdown：原样提交，不让语雀按 HTML 解析
    o.put("body", JsonString(docBody))
    o.put("format", JsonString("markdown"))
    if (trimAscii(slug).size > 0) {
        o.put("slug", JsonString(trimAscii(slug)))
    }
    if (publicLevel >= 0) {
        o.put("public", JsonInt(publicLevel))
    }
    return o.toJsonString()
}

/** 解析创建文档响应：返回 (docId, docSlug, title)。
 * 成功体 {"data":{...}}；错误体 {"status":401,"error":"Unauthorized"} 走 parseYuqueError。 */
public func parseYuqueDocResp(text: String): (String, String, String) {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var id = ""
    var slug = ""
    var title = ""
    if (let Some(data) <- jsonObjField(root, "data")) {
        id = jsonScalar(data, "id")
        slug = jsonScalar(data, "slug")
        title = jsonScalar(data, "title")
    }
    return (id, slug, title)
}

/** 解析语雀错误体：返回 (status, message)。status 取不到时记 0，交给调用方看 HTTP 码。 */
public func parseYuqueError(text: String): (Int64, String) {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var status: Int64 = 0
    let st = jsonScalar(root, "status")
    if (st.size > 0) {
        status = yuqueNum(st)
    }
    var msg = jsonScalar(root, "error")
    if (msg.size == 0) {
        msg = jsonScalar(root, "message")
    }
    return (status, msg)
}

/** 数字兜底解析：非数字返回 0 */
func yuqueNum(s: String): Int64 {
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

/** 公开性配置解析：0 私密 / 1 公开 / 2 企业内公开；其它值（含空、非数字）返回 -1 = 不传，继承知识库。
 * 注意不能借用 yuqueNum 兜底：它把非法值解析成 0，而 0 是合法的「私密」，
 * 会把配错的 "abc" 悄悄变成私密发布——这里必须让非法值走 -1。 */
public func parseYuquePublic(cfg: String): Int64 {
    let t = trimAscii(cfg)
    if (t.size == 0) {
        return -1
    }
    let v = try {
        Int64.parse(t)
    } catch (e: Exception) {
        let _ = e
        Int64(-1)
    }
    if (v >= 0 && v <= 2) {
        return v
    }
    return -1
}

/** 文档地址：https://www.yuque.com/{namespace}/{docSlug} */
public func yuqueDocUrl(namespace: String, docSlug: String): String {
    return "${YUQUE_SITE}/${trimAscii(namespace)}/${docSlug}"
}

/** 校验 Token 并取当前用户：GET /api/v2/user → data.login / data.name。
 * 语雀是唯一能「真验证」凭证的平台（腾讯云/头条的 Cookie 只能真发一篇才知道）。
 * 返回 (login, name)；鉴权失败或网络异常返回空串。 */
public func fetchYuqueUser(token: String, insecure: Bool): (String, String) {
    let builder = HttpRequestBuilder()
        .url("${YUQUE_API}/user")
        .get()
    let req = applyHeaders(builder, [
        StrKV("X-Auth-Token", token),
        StrKV("Accept", "application/json"),
        StrKV("User-Agent", YUQUE_UA),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("yuque /user HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        return ("", "")
    }
    let root = try {
        JsonValue.fromStr(r.text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    if (let Some(data) <- jsonObjField(root, "data")) {
        return (jsonScalar(data, "login"), jsonScalar(data, "name"))
    }
    return ("", "")
}

/** 语雀发文入口。publishNow=false 时按 public=0（私密）创建——语雀的私密文档就是草稿态，
 * 用户可在网页端改成公开，比腾讯云「没有草稿态只能 dry-run」好办。
 * 图片：本地图在配了 AtomGit 令牌时转成外链（语雀正文支持外链图），失败保留原引用不阻断。 */
public func publishToYuque(token: String, namespace: String, publicCfg: Int64, a: Article,
    publishNow: Bool, insecure: Bool, atomgitToken: String, atomgitRepo: String,
    atomgitBranch: String, atomgitDir: String): Int64 {

    // ① 图片：本地图转外链（best-effort）
    var body = a.body
    if (atomgitToken.size > 0) {
        let (b1, ok1, fail1) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        if (ok1 > 0 || fail1 > 0) {
            body = b1
            println("图片（AtomGit 外链）：成功 ${ok1}，失败 ${fail1}")
        }
    }

    // ② body 是唯一必填字段：纯文本为空就没必要发请求
    if (utf8CharCount(stripMarkdown(body)) == 0) {
        println("错误：正文为空——语雀的 body 是唯一必填字段")
        return 1
    }

    // ③ 公开性：草稿模式强制私密（0）；发布模式用配置值，未配置则不传（继承知识库）
    let level = if (publishNow) { publicCfg } else { Int64(0) }
    let payload = buildYuqueDocBody(a.title, body, "", level)
    let mode = if (publishNow) { "publish" } else { "draft（public=0 私密）" }
    println("语雀：提交（${mode}）→ ${namespace} …")

    let builder = HttpRequestBuilder()
        .url("${YUQUE_API}/repos/${namespace}/docs")
        .post()
        .header("Content-Type", "application/json")
        .body(payload)
    let req = applyHeaders(builder, [
        StrKV("X-Auth-Token", token),
        StrKV("Accept", "application/json"),
        StrKV("User-Agent", YUQUE_UA),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("yuque create doc HTTP ${r.status}：${r.text}")

    let (errStatus, errMsg) = parseYuqueError(r.text)
    if (r.status == 401 || errStatus == 401) {
        println("错误：语雀 Token 未通过鉴权${if (errMsg.size > 0) { "（${errMsg}）" } else { "" }}")
        println("提示：去 https://www.yuque.com/settings/tokens 重新生成，并确认已勾选「读/写文档」权限")
        return 1
    }
    if (r.status == 404 || errStatus == 404) {
        println("错误：语雀实体未找到（namespace 或知识库不对）")
        println("提示：namespace 必须是两段式 `user/repo` 或 `group/book_slug`，取知识库 URL 里那两段")
        println("      当前值：${namespace}")
        return 1
    }
    if (r.status == 403 || errStatus == 403) {
        println("错误：语雀无操作权限${if (errMsg.size > 0) { "（${errMsg}）" } else { "" }}")
        println("提示：Token 的 scope 要包含该知识库的写权限（只读 Token 发不了文档）")
        return 1
    }
    if (r.status == 422 || errStatus == 422) {
        println("错误：语雀参数校验失败${if (errMsg.size > 0) { "（${errMsg}）" } else { "" }}")
        println(r.text)
        return 1
    }
    if (r.status == 429 || errStatus == 429) {
        println("错误：语雀访问频率超限（429），稍后再试")
        return 1
    }
    if (r.status != 200) {
        println("错误：语雀提交失败（HTTP ${r.status}${if (errMsg.size > 0) { "：" + errMsg } else { "" }}）")
        println(r.text)
        return 1
    }

    let (docId, docSlug, docTitle) = parseYuqueDocResp(r.text)
    if (docId.size == 0) {
        println("错误：语雀返回 200 但没解析出文档 id")
        println(r.text)
        return 1
    }
    println("语雀：${if (publishNow) { "发布成功" } else { "草稿（私密文档）已创建" }}，id ${docId}")
    if (docTitle.size > 0) {
        println("标题：${docTitle}")
    }
    if (docSlug.size > 0) {
        println("文档地址：${yuqueDocUrl(namespace, docSlug)}")
    }
    println("提示：语雀不会把新文档自动加入知识库目录，需要的话去网页端拖一下（直链已可访问）")
    return 0
}
