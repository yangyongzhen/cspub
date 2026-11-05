/** 腾讯云开发者社区发文：走社区原创编辑器自用的 addArticle 接口——Cookie 鉴权、零签名、零浏览器。
 *
 * 探明的接口形状（2026-11 实测，见 docs/多平台发文调研.md §二）：
 *   POST https://cloud.tencent.com/developer/api/article/addArticle
 *   鉴权：Cookie 整串透传（skey / qcommunity_session 是登录态，qcloud_uid / tinyid 是身份）
 *   成功：{"articleId":2650368,"status":0}，文章地址 https://cloud.tencent.com/developer/article/{articleId}
 *   失败：{"msg":"参数错误","code":400} / {"msg":"你还未登录，请先登录","code":401}
 *
 * 两个实测出来的硬约束，写实现时都得让着它：
 * ① **参数校验先于登录校验**：只发 `{}` 得到的是 400「参数错误」而不是 401「未登录」。
 *    所以字段必须一次给全；否则 400 会被误读成「Cookie 失效」，白排查半天。
 * ② **正文不少于 140 字**（官方文档明示，按字符算不是按字节）。
 *
 * 草稿：addArticle 没有草稿态（请求体里没有 draft/status 一类字段；社区的草稿箱走另一套接口，
 * 本次未探到）。所以 --draft 在这里做成 **dry-run**：把要提交的标题/字数/专栏/图片打印出来但不发送。
 * 宁可少发一次，也不要把「以为存了草稿、其实已经公开」这种最坏情况做出来。
 */
package cspub

import std.collection.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

public const TENCENT_API: String = "https://cloud.tencent.com/developer/api/article/addArticle"
public const TENCENT_SITE: String = "https://cloud.tencent.com"
/** 默认专栏 id 149 = 技术。腾讯云要求文章必须归属专栏，空数组提交必失败。 */
public const TENCENT_DEFAULT_CLASSIFY: Int64 = 149
/** 官方明示的正文下限（字符数，按纯文本计） */
public const TENCENT_MIN_PLAIN: Int64 = 140
const TENCENT_UA: String = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

/** 登录态判定：skey 或 qcommunity_session 有一个就算（qcloud_uid 只是身份标识，不单独成立） */
public func tencentCookieHasSession(cookie: String): Bool {
    return cookieValue(cookie, "skey").size > 0 || cookieValue(cookie, "qcommunity_session").size > 0
}

/** 正文纯文本（接口的 plain 字段）：接口要「去标签的纯文本」，塞 HTML 进去会被当纯文本显示。 */
public func tencentPlainText(md: String): String {
    return stripMarkdown(md)
}

/** 解析专栏 id 配置（逗号分隔）：非法项丢弃；全空或全非法时回落到默认专栏。
 * 不能返回空数组——那一定 400。 */
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

/** addArticle 请求体（纯函数，单测覆盖）：字段一次给全，少一个就变 400 */
public func buildTencentArticleBody(title: String, html: String, plain: String, summary: String,
    classifyIds: Array<Int64>, isOriginal: Bool): String {
    let o = JsonObject()
    o.put("title", JsonString(title))
    o.put("content", JsonString(html))
    o.put("plain", JsonString(plain))
    o.put("summary", JsonString(summary))
    o.put("userSummary", JsonString(summary))
    o.put("sourceType", JsonInt(1))
    o.put("isOriginal", JsonBool(isOriginal))
    let arr = JsonArray()
    for (id in classifyIds) {
        arr.add(JsonInt(id))
    }
    o.put("classifyIds", arr)
    o.put("openComment", JsonInt(1))
    o.put("closeTextLink", JsonInt(0))
    return o.toJsonString()
}

/** 解析 addArticle 响应：返回 (code, msg, articleId)。
 * 成功体 {"articleId":N,"status":0} **没有 code 字段**，此时 code 记 0；失败体才带 code/msg。
 * 因此调用方的成功判据是 articleId 非空，不是 code==0。 */
public func parseTencentResp(text: String): (Int64, String, String) {
    let root = try {
        JsonValue.fromStr(text)
    } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    var code: Int64 = 0
    var msg = ""
    var id = ""
    match (root.kind()) {
        case JsonKind.JsObject =>
            let c = jsonScalar(root, "code")
            if (c.size > 0) {
                code = tencentNum(c)
            }
            msg = jsonScalar(root, "msg")
            id = jsonScalar(root, "articleId")
        case _ => ()
    }
    return (code, msg, id)
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

/** 腾讯云发文入口。publishNow=false 走 dry-run（只校验不发送，见文件头说明）。
 * 图片：本地图在配了 AtomGit 令牌时转成外链（腾讯云会把正文图重写到自有 CDN，外链可直接留用），
 * 失败保留原引用，不阻断发文。 */
public func publishToTencent(cookie: String, classifyCfg: String, a: Article, publishNow: Bool,
    insecure: Bool, atomgitToken: String, atomgitRepo: String, atomgitBranch: String,
    atomgitDir: String): Int64 {

    // ① 图片：本地图转外链（失败 best-effort，保留原引用）
    var body = a.body
    if (atomgitToken.size > 0) {
        let (b1, ok1, fail1) = rehostImagesAtomGit(body, atomgitToken, atomgitRepo,
            atomgitBranch, atomgitDir, insecure)
        if (ok1 > 0 || fail1 > 0) {
            body = b1
            println("图片（AtomGit 外链）：成功 ${ok1}，失败 ${fail1}")
        }
    }

    // ② 正文下限按字符算：字节数会把一个汉字算成 3 个，中文短文会被误判成「够长」而发不出去
    let plain = tencentPlainText(body)
    let chars = utf8CharCount(plain)
    if (chars < TENCENT_MIN_PLAIN) {
        println("错误：正文纯文本只有 ${chars} 字，腾讯云要求不少于 ${TENCENT_MIN_PLAIN} 字")
        println("提示：这是社区官方下限，补足正文再来（纯文本计，代码块与图片不计入）")
        return 1
    }

    let html = mdToHtml(body)
    var summary = trimAscii(a.desc)
    if (summary.size == 0) {
        summary = truncateUtf8(plain, 200)
    }
    let classifyIds = parseTencentClassifyIds(classifyCfg)
    // 有 origin_url 视为转载：腾讯云用 isOriginal 表达
    let isOriginal = trimAscii(a.originUrl).size == 0
    let payload = buildTencentArticleBody(a.title, html, plain, summary, classifyIds, isOriginal)

    // ③ 草案：该接口无草稿态，dry-run 代偿
    if (!publishNow) {
        println("腾讯云：dry-run（未发送）")
        println("  标题    ：${a.title}")
        println("  正文字数：${chars} 字（下限 ${TENCENT_MIN_PLAIN}，已通过）")
        println("  专栏    ：${joinIds(classifyIds)}")
        println("  原创    ：${if (isOriginal) { "是（无 origin_url）" } else { "否（按转载提交）" }}")
        println("  图片    ：正文外链/本地引用 ${findExternalImages(body).size} 处")
        println("该接口没有草稿态——确认无误后加 --live 直接发布")
        return 0
    }

    let builder = HttpRequestBuilder()
        .url(TENCENT_API)
        .post()
        .header("Content-Type", "application/json")
        .body(payload)
    let req = applyHeaders(builder, [
        StrKV("User-Agent", TENCENT_UA),
        StrKV("Accept", "application/json, text/plain, */*"),
        StrKV("Origin", TENCENT_SITE),
        StrKV("Referer", TENCENT_SITE + "/developer/article/write-new"),
        StrKV("Cookie", cookie),
    ]).build()
    let r = execRequest(req, insecure)
    dbg("tencent addArticle HTTP ${r.status}：${r.text}")

    let (code, msg, articleId) = parseTencentResp(r.text)
    if (r.status == 401 || code == 401) {
        println("错误：腾讯云未登录${if (msg.size > 0) { "（${msg}）" } else { "" }}")
        println("提示：Cookie 过期——重新登录 cloud.tencent.com 后复制整串（须含 skey / qcommunity_session）")
        return 1
    }
    if (r.status == 400 || code == 400) {
        println("错误：腾讯云参数错误${if (msg.size > 0) { "（${msg}）" } else { "" }}")
        println("提示：这是**参数**问题不是登录问题（该接口先校验参数再校验登录）")
        println("      常见原因：正文太短 / 标题为空 / 无可用专栏")
        println("      专栏：CSPUB_TENCENT_CLASSIFY_IDS=<id>（新账号要先在社区后台建专栏，审核 1~3 天）")
        println(r.text)
        return 1
    }
    if (r.status != 200 || articleId.size == 0) {
        println("错误：腾讯云提交失败（HTTP ${r.status}，code ${code}）")
        println(r.text)
        return 1
    }
    println("腾讯云：发布成功，articleId ${articleId}")
    println("文章地址：${tencentArticleUrl(articleId)}")
    return 0
}
