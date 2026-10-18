/**
 * cspub —— CSDN 自动发文 CLI（仓颉实现）
 *
 * 用法：
 *   cspub check   <文章.md>            解析 front-matter + 渲染统计，不联网
 *   cspub publish <文章.md> [--draft]  发草稿（默认）
 *                      [--live]        直接发布（覆盖 front-matter 的 draft: true）
 *                      [--update <id>] 原地更新已有文章
 *   cspub whoami                       校验 Cookie 配置（解析 UserName，不发网络请求）
 *   cspub help                         本帮助
 *
 * 配置（优先级从高到低）：
 *   1. 环境变量 CSPUB_CSDN_COOKIE
 *   2. ~/.cspub/config.json 的 {"csdnCookie": "..."}
 * Cookie 获取：浏览器登录 CSDN → F12 → 任一 blog.csdn.net 请求 → 复制 Cookie 请求头整串。
 *
 * 签名：CSDN 编辑器接口走阿里云 API 网关风格 HMAC-SHA256（x-ca-*），key/secret 烙在
 * CSDN 公开的前端 JS 里；本工具只带这两个公开常量，账号凭据只有用户自己的 Cookie。
 */
package cspub

import std.env.*
import stdx.encoding.json.*

main(args: Array<String>): Int64 {
    if (args.size == 0) {
        usage()
        return 1
    }
    let cmd = args[0]
    if (cmd == "help" || cmd == "--help" || cmd == "-h") {
        usage()
        return 0
    }
    if (cmd == "whoami") {
        return cmdWhoami()
    }
    if (cmd == "check" && args.size >= 2) {
        return cmdCheck(args[1])
    }
    if (cmd == "html" && args.size >= 2) {
        // 调试入口：只打印渲染后的 HTML（publish 发给 CSDN 的 content 就是它）
        let text = loadArticleFile(args[1])
        if (text.size == 0) {
            return 1
        }
        println(mdToHtml(parseArticle(text).body))
        return 0
    }
    if (cmd == "imgs" && args.size >= 2) {
        // 调试入口：列出会被转存的站外图（只扫描不联网；publish 的 rehost 用同一套扫描）
        let text = loadArticleFile(args[1])
        if (text.size == 0) {
            return 1
        }
        let imgs = findExternalImages(parseArticle(text).body)
        if (imgs.size == 0) {
            println("无图片引用")
            return 0
        }
        for (m in imgs) {
            let host = hostOf(m.url)
            var action = "rehost"
            if (isCsdnImageHost(host)) {
                action = "skip (already csdn)"
            } else if (!m.url.startsWith("http://") && !m.url.startsWith("https://")) {
                action = "skip (not http)"
            } else if (isBlockedHost(host)) {
                action = "BLOCKED (non-public)"
            }
            println("[${action}] ${host} ${m.url}")
        }
        return 0
    }
    if (cmd == "probeimg") {
        // 负向探针（图床签名端点）：不带 Cookie 发签名请求——期望 401（网关放行、仅缺登录）。
        // 签名接口不看图片字节，fake 字节即可；真实上传在 publish 时发生。
        println("（探针：不带 Cookie 调图床签名接口，看网关响应）")
        let fake = Array<Byte>(8, repeat: 0)
        try {
            let newUrl = uploadImage("", fake, "png", true)
            println("意外成功（不应发生，说明鉴权形同虚设）：${newUrl}")
            return 1
        } catch (e: PubError) {
            println("图床签名端点预检：${e.message}")
            return 0
        } catch (e: Exception) {
            println("预检失败：${e.message}")
            return 1
        }
    }
    if (cmd == "sig" && args.size >= 2) {
        // 调试入口：按给定 nonce 打印签名（确定性），与参考实现逐字节对账用
        let sign = caSignWithNonce("POST", "/blog-console-api/v3/mdeditor/saveArticle", "application/json", args[1])
        match (sign.get("x-ca-signature")) {
            case Some(v) =>
                println(v)
                return 0
            case None => return 1
        }
    }
    if (cmd == "probe" && args.size >= 2) {
        // 负向探针：不带 Cookie 发签名请求（草稿体）——验证请求形状与签名能否过网关。
        // 401/403 = 签名被验过、只缺凭据；回签名类错误 = 实现有问题；WAF 拦截会回 HTML。
        let text = loadArticleFile(args[1])
        if (text.size == 0) {
            return 1
        }
        println("（探针：不带 Cookie 发送签名请求，看网关响应）")
        return publishToCsdn("", parseArticle(text), "", false, true)
    }
    if (cmd == "publish" && args.size >= 2) {
        return cmdPublish(args, 2)
    }
    println("未知命令或参数不足：${cmd}")
    usage()
    return 1
}

func usage(): Unit {
    println("cspub v0.1.0 — CSDN 自动发文 CLI（仓颉实现）")
    println("")
    println("用法:")
    println("  cspub check   <文章.md>            解析 front-matter + 渲染统计（不联网）")
    println("  cspub publish <文章.md> [--draft]  发草稿（默认）")
    println("                      [--live]       直接发布（覆盖 front-matter 的 draft: true）")
    println("                      [--update id]  原地更新指定文章")
    println("  cspub whoami                       校验 Cookie 配置（解析 UserName）")
    println("  cspub help                         本帮助")
    println("")
    println("配置: 环境变量 CSPUB_CSDN_COOKIE 优先，其次 ~/.cspub/config.json 的 csdnCookie 字段")
    println("front-matter: title(必填) / tags(逗号分隔,最多5) / categories / desc / draft(true|false)")
}

/** 命令：whoami——解析 Cookie 里的账号标识，配置自检用（不发网络请求） */
func cmdWhoami(): Int64 {
    let cookie = loadCookie()
    if (cookie.size == 0) {
        return 1
    }
    let user = cookieValue(cookie, "UserName")
    if (user.size == 0) {
        println("Cookie 里没有 UserName 字段——可能不是登录态的 Cookie（要浏览器登录后的整串）")
        return 1
    }
    let nick = cookieValue(cookie, "UserNick")
    println("UserName: ${user}")
    if (nick.size > 0) {
        println("UserNick: ${nick}")
    }
    println("Cookie 配置可用（未联网验证；publish 时以 CSDN 实际响应为准）")
    return 0
}

/** 命令：check——解析 front-matter + 渲染统计，不联网 */
func cmdCheck(path: String): Int64 {
    let text = loadArticleFile(path)
    if (text.size == 0) {
        return 1
    }
    let a = parseArticle(text)
    println("title      : ${a.title}")
    println("tags       : ${a.tags}")
    println("categories : ${a.categories}")
    println("desc       : ${a.desc}")
    println("draft      : ${a.draft}")
    println("正文        : ${a.body.size} 字节 / ${countLines(a.body)} 行")
    let html = mdToHtml(a.body)
    println("渲染 HTML   : ${html.size} 字节")
    if (a.title.size == 0) {
        println("⚠ front-matter 缺 title（CSDN 必填）")
        return 1
    }
    println("OK")
    return 0
}

/** 命令：publish——解析 + 组包 + 签名 + 发送 */
func cmdPublish(args: Array<String>, startIdx: Int64): Int64 {
    var draftOverride = false
    var liveOverride = false
    var updateId = ""
    var insecure = false
    var i = startIdx
    while (i < args.size) {
        if (args[i] == "--draft") {
            draftOverride = true
        } else if (args[i] == "--live") {
            liveOverride = true
        } else if (args[i] == "--insecure") {
            insecure = true
        } else if (args[i] == "--update" && i + 1 < args.size) {
            updateId = args[i + 1]
            i++
        } else {
            println("未知参数：${args[i]}")
            return 1
        }
        i++
    }
    let path = args[1]
    let text = loadArticleFile(path)
    if (text.size == 0) {
        return 1
    }
    let a = parseArticle(text)
    if (a.title.size == 0) {
        println("错误：front-matter 缺 title（CSDN 必填）")
        return 1
    }
    // 发布态优先级：--live > --draft > front-matter 的 draft（缺省 true = 宁可草稿不发）
    let publishNow = liveOverride || (!draftOverride && !a.draft)
    let cookie = loadCookie()
    if (cookie.size == 0) {
        return 1
    }
    // 图片转存（发文前）：CSDN 对站外图有防盗链（200 + 0 字节），外链图必须先进 CSDN 图床。
    // best-effort：单张失败保留原链接继续发，不阻断发文。
    let a2 = parseArticle(text)
    a2.title = a.title
    a2.tags = a.tags
    a2.categories = a.categories
    a2.desc = a.desc
    a2.draft = a.draft
    a2.body = rehostImages(cookie, a.body, insecure)
    let mode = if (publishNow) { "publish" } else { "draft" }
    if (insecure) {
        println("⚠ --insecure：跳过 TLS 证书校验（自担风险；仅诊断用）")
    }
    if (updateId.size > 0) {
        println("更新文章 id=${updateId}（${mode}）…")
    } else {
        println("发布新文章（${mode}）…")
    }
    return publishToCsdn(cookie, a2, updateId, publishNow, insecure)
}

/** 读文章文件；读不到给可行动的报错（路径是第一嫌疑） */
func loadArticleFile(path: String): String {
    try {
        return readTextFileAll(path)
    } catch (e: Exception) {
        println("错误：读不到 ${path}（${e.message}）")
        println("提示：相对路径按当前工作目录解析，先 cd 到文章所在目录再试")
        return ""
    }
}

func countLines(s: String): Int64 {
    let lines = s.split("\n", -1)
    var n: Int64 = 0
    for (l in lines) {
        let _ = l
        n++
    }
    return n
}

/** 载入 CSDN Cookie：环境变量优先，其次 ~/.cspub/config.json */
func loadCookie(): String {
    match (getVariable("CSPUB_CSDN_COOKIE")) {
        case Some(v) =>
            if (v.size > 0) {
                return v
            }
        case None => ()
    }
    match (getVariable("HOME")) {
        case Some(home) =>
            let path = home + "/.cspub/config.json"
            try {
                let text = readTextFileAll(path)
                let root = JsonValue.fromStr(text)
                // JsonKind 没有 ==（AGENTS §4）：枚举比较只能走 match 分支
                match (root.kind()) {
                    case JsonKind.JsObject =>
                        let obj = root.asObject()
                        if (let Some(v) <- obj.get("csdnCookie")) {
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
        case None => ()
    }
    println("错误：没有找到 CSDN Cookie。")
    println("  方式一：export CSPUB_CSDN_COOKIE='<浏览器复制的 Cookie 整串>'")
    println("  方式二：mkdir -p ~/.cspub && 写 ~/.cspub/config.json：{\"csdnCookie\": \"...\"}")
    return ""
}
