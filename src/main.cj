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

import std.collection.*
import std.env.*
import stdx.encoding.hex.*
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
        return cmdWhoami(args)
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
    if (cmd == "mp") {
        // 调试入口：按固定输入打印 multipart 表单体 hex（确定性），与参考实现逐字节对账用
        let fields = [StrKV("key", "abc/def.png"), StrKV("policy", "pol==")]
        let body = buildMultipart("----cspubTEST", fields, "file", "image.png", "image/png", [UInt8(0x89), UInt8(0x50), UInt8(0x4E), UInt8(0x47)])
        println(toHexString(body))
        return 0
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
    println("cspub v0.2.2 — 多平台自动发文 CLI（仓颉实现）：csdn / zhihu / baijiahao / cnblogs / juejin")
    println("")
    println("用法:")
    println("  cspub check   <文章.md>            解析 front-matter + 渲染统计（不联网）")
    println("  cspub publish <文章.md> [--draft]  发草稿（默认）")
    println("                      [--live]       直接发布（覆盖 front-matter 的 draft: true）")
    println("                      [--update id]  原地更新指定文章（仅 csdn）")
    println("                      [--platform p] csdn（默认）/ zhihu / baijiahao / cnblogs / juejin")
    println("  cspub whoami [platform]            校验平台凭证配置（不发网络请求）")
    println("  cspub help                         本帮助")
    println("")
    println("配置（环境变量优先，其次 ~/.cspub/config.json 同名小驼峰字段）:")
    println("  csdn:      CSPUB_CSDN_COOKIE       / csdnCookie（浏览器登录后整串 Cookie）")
    println("  zhihu:     CSPUB_ZHIHU_COOKIE      / zhihuCookie（须含 z_c0 与 XSRF-TOKEN）")
    println("  baijiahao: ①官方 token 通道 CSPUB_BAIJIAHAO_APP_ID/TOKEN（需后台「开发」入口，现为定向邀请制）")
    println("             ②Cookie 浏览器通道 CSPUB_BAIJIAHAO_COOKIE（通用，须含 BDUSS；另需 python3+playwright+chromium）")
    println("  cnblogs:   CSPUB_CNBLOGS_BLOG_ID、CSPUB_CNBLOGS_USERNAME、CSPUB_CNBLOGS_TOKEN")
    println("             （MetaWeblog 访问令牌，后台「设置 → 允许博客客户端访问」开启并生成）")
    println("  juejin:    CSPUB_JUEJIN_COOKIE（须含 sessionid）+ 可选 CSPUB_JUEJIN_UUID/CATEGORY_ID/TAG_IDS")
    println("             （正文图片转存走浏览器通道，需 python3+playwright+chromium）")
    println("front-matter: title(必填) / tags(逗号分隔,最多5) / categories / desc / draft(true|false)")
    println("              / origin_url（baijiahao 必填：原文地址/首发链接）")
}

/** 载入博客园 MetaWeblog 凭证：环境变量优先，其次 ~/.cspub/config.json */
func loadCnblogsCreds(): (String, String, String) {
    let blogId = loadConfigString("CSPUB_CNBLOGS_BLOG_ID", "cnblogsBlogId")
    let username = loadConfigString("CSPUB_CNBLOGS_USERNAME", "cnblogsUsername")
    let token = loadConfigString("CSPUB_CNBLOGS_TOKEN", "cnblogsToken")
    if (blogId.size == 0 || username.size == 0 || token.size == 0) {
        println("错误：没有找到博客园凭证（三项都要）：")
        println("  blogId：MetaWeblog 访问地址 https://rpc.cnblogs.com/metaweblog/<博客名> 的尾巴")
        println("  username：后台 MetaWeblog 设置页显示的登录名（不是昵称/主页路径猜测）")
        println("  token：同页面的「访问令牌」（不是登录密码）；须先开启「允许博客客户端访问」")
        println("  方式一：export CSPUB_CNBLOGS_BLOG_ID=… CSPUB_CNBLOGS_USERNAME=… CSPUB_CNBLOGS_TOKEN=…")
        println("  方式二：~/.cspub/config.json 写 {\"cnblogsBlogId\": \"…\", \"cnblogsUsername\": \"…\", \"cnblogsToken\": \"…\"}")
    }
    return (blogId, username, token)
}

/** 载入掘金凭证：环境变量优先，其次 ~/.cspub/config.json */
func loadJuejinCreds(): (String, String, String, String) {
    let cookie = loadConfigString("CSPUB_JUEJIN_COOKIE", "juejinCookie")
    let uuid = loadConfigString("CSPUB_JUEJIN_UUID", "juejinUuid")
    let categoryId = loadConfigString("CSPUB_JUEJIN_CATEGORY_ID", "juejinCategoryId")
    let tagIds = loadConfigString("CSPUB_JUEJIN_TAG_IDS", "juejinTagIds")
    if (cookie.size == 0) {
        println("错误：没有找到掘金 Cookie。")
        println("  方式一：export CSPUB_JUEJIN_COOKIE='<浏览器登录 juejin.cn 后复制的 Cookie 整串，须含 sessionid>'")
        println("  方式二：~/.cspub/config.json 写 {\"juejinCookie\": \"...\"}")
        println("  可选：CSPUB_JUEJIN_UUID（api 请求里的 uuid）、CSPUB_JUEJIN_CATEGORY_ID / CSPUB_JUEJIN_TAG_IDS")
        println("  （分类/标签用掘金内部 ID：后台抓包 category_id / tag_ids；不配置则草稿不带分类标签）")
    }
    return (cookie, uuid, categoryId, tagIds)
}

/** 命令：whoami——解析平台凭证里的账号标识，配置自检用（不发网络请求） */
func cmdWhoami(args: Array<String>): Int64 {
    var platform = "csdn"
    if (args.size >= 2) {
        platform = args[1]
    }
    if (platform == "zhihu") {
        let cookie = loadZhihuCookie()
        if (cookie.size == 0) {
            return 1
        }
        let zc0 = cookieValue(cookie, "z_c0")
        let xsrf = cookieValue(cookie, "XSRF-TOKEN")
        if (zc0.size == 0) {
            println("Cookie 里没有 z_c0——不是登录态的 Cookie（要浏览器登录 zhuanlan.zhihu.com 后的整串）")
            return 1
        }
        println("z_c0       : 存在（${zc0.size} 字节）")
        println("XSRF-TOKEN : ${if (xsrf.size > 0) { "存在" } else { "缺失（发文时可能被 403，建议整串复制）" }}")
        println("Cookie 配置可用（未联网验证；publish 时以知乎实际响应为准）")
        return 0
    }
    if (platform == "juejin") {
        let (cookie, uuid, categoryId, _) = loadJuejinCreds()
        if (cookie.size == 0) {
            return 1
        }
        let sid = cookieValue(cookie, "sessionid")
        if (sid.size == 0) {
            println("Cookie 里没有 sessionid——不是登录态整串（要浏览器登录 juejin.cn 后复制的 Cookie）")
            return 1
        }
        println("sessionid : 存在（${sid.size} 字节）")
        println("uuid      : ${if (uuid.size > 0) { "已配置" } else { "未配置（可选，遇到校验错误再补）" }}")
        println("category/tag: ${if (categoryId.size > 0) { "category 已配置" } else { "category 未配置（草稿将不带分类）" }}")
        println("Cookie 配置可用（未联网验证；publish 时以掘金实际响应为准）")
        return 0
    }
    if (platform == "cnblogs") {
        let (blogId, username, token) = loadCnblogsCreds()
        if (blogId.size == 0 || username.size == 0 || token.size == 0) {
            return 1
        }
        println("blogId  : ${blogId}")
        println("username: ${username}")
        println("token   : 已配置（${token.size} 字节）")
        println("凭证配置可用（未联网验证；publish 时以博客园实际响应为准）")
        return 0
    }
    if (platform == "baijiahao") {
        let (appId, token) = loadBjhCreds()
        if (appId.size > 0 && token.size > 0) {
            println("app_id   : ${appId}")
            println("app_token: 已配置（${token.size} 字节，泄露需在百家号后台立即重置）")
            println("凭证配置可用（官方 token 通道；未联网验证）")
            return 0
        }
        let bjhCookie = loadConfigString("CSPUB_BAIJIAHAO_COOKIE", "baijiahaoCookie")
        if (bjhCookie.size > 0) {
            let bduss = cookieValue(bjhCookie, "BDUSS")
            if (bduss.size == 0) {
                println("Cookie 里没有 BDUSS——不是百度登录态整串（要浏览器登录 baijiahao.baidu.com 后的整串）")
                return 1
            }
            println("BDUSS    : 存在（${bduss.size} 字节）")
            println("Cookie 配置可用（浏览器自动化通道；未联网验证）")
            return 0
        }
        println("错误：没有找到百家号凭证（① app_id+app_token 或 ② Cookie，见 help）")
        return 1
    }
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

/** 命令：publish——解析 + 组包 + 签名/凭证 + 按平台发送 */
func cmdPublish(args: Array<String>, startIdx: Int64): Int64 {
    var draftOverride = false
    var liveOverride = false
    var updateId = ""
    var insecure = false
    var platform = "csdn"
    var i = startIdx
    while (i < args.size) {
        if (args[i] == "--draft") {
            draftOverride = true
        } else if (args[i] == "--live") {
            liveOverride = true
        } else if (args[i] == "--insecure") {
            insecure = true
        } else if (args[i] == "--platform" && i + 1 < args.size) {
            platform = args[i + 1]
            i++
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
        println("错误：front-matter 缺 title（发文必填）")
        return 1
    }
    // 发布态优先级：--live > --draft > front-matter 的 draft（缺省 true = 宁可草稿不发）
    let publishNow = liveOverride || (!draftOverride && !a.draft)
    if (platform == "zhihu") {
        let cookie = loadZhihuCookie()
        if (cookie.size == 0) {
            return 1
        }
        let mode = if (publishNow) { "publish" } else { "draft" }
        println("发布到知乎（${mode}）…")
        // 知乎无 CSDN 那种站外图防盗链，暂不转存（知乎编辑器保存时可能剥离部分外链图）
        return publishToZhihu(cookie, a, publishNow, insecure)
    }
    if (platform == "baijiahao") {
        let (appId, token) = loadBjhCreds()
        let mode = if (publishNow) { "publish" } else { "draft" }
        if (appId.size > 0 && token.size > 0) {
            // 通道一：官方开发者接口（后台「开发」菜单的 app_id/app_token）
            println("发布到百家号（${mode}，官方 token 通道）…")
            return publishToBaijiahao(appId, token, a, publishNow, insecure)
        }
        // 通道二：Cookie + 浏览器自动化伴生脚本（开发者入口为定向邀请制时的替代）
        let bjhCookie = loadConfigString("CSPUB_BAIJIAHAO_COOKIE", "baijiahaoCookie")
        if (bjhCookie.size > 0) {
            println("发布到百家号（${mode}，Cookie 浏览器通道）…")
            return publishToBaijiahaoCookie(bjhCookie, a, publishNow)
        }
        println("错误：没有找到百家号凭证（两选一）：")
        println("  ① 官方开发者接口（若账号有「开发」入口）：CSPUB_BAIJIAHAO_APP_ID + CSPUB_BAIJIAHAO_APP_TOKEN")
        println("     或 config.json 的 baijiahaoAppId / baijiahaoAppToken")
        println("  ② Cookie 浏览器通道（推荐，通用）：CSPUB_BAIJIAHAO_COOKIE 或 config.json 的 baijiahaoCookie")
        println("     Cookie 获取：浏览器登录 baijiahao.baidu.com → F12 → 复制 Cookie 整串（须含 BDUSS）")
        println("     通道②另需宿主机：python3 + playwright + chromium（pip install playwright && playwright install chromium）")
        return 1
    }
    if (platform == "juejin") {
        let (cookie, uuid, categoryId, tagIds) = loadJuejinCreds()
        if (cookie.size == 0) {
            return 1
        }
        var tagArr: Array<String> = Array<String>()
        if (tagIds.size > 0) {
            var list: ArrayList<String> = ArrayList<String>()
            for (p in tagIds.split(",", -1)) {
                let t = trimAscii(p)
                if (t.size > 0) {
                    list.add(t)
                }
            }
            tagArr = list.toArray()
        }
        let mode = if (publishNow) { "publish" } else { "draft" }
        println("发布到掘金（${mode}）…")
        return publishToJuejin(cookie, uuid, categoryId, tagArr, a, publishNow, insecure)
    }
    if (platform == "cnblogs") {
        let (blogId, username, token) = loadCnblogsCreds()
        if (blogId.size == 0 || username.size == 0 || token.size == 0) {
            return 1
        }
        let mode = if (publishNow) { "publish" } else { "draft" }
        println("发布到博客园（${mode}）…")
        return publishToCnblogs(blogId, username, token, a, publishNow, insecure)
    }
    if (platform != "csdn") {
        println("未知平台：${platform}（可选 csdn / zhihu / baijiahao）")
        return 1
    }
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
    let c = loadConfigString("CSPUB_CSDN_COOKIE", "csdnCookie")
    if (c.size == 0) {
        println("错误：没有找到 CSDN Cookie。")
        println("  方式一：export CSPUB_CSDN_COOKIE='<浏览器复制的 Cookie 整串>'")
        println("  方式二：mkdir -p ~/.cspub && 写 ~/.cspub/config.json：{\"csdnCookie\": \"...\"}")
    }
    return c
}

/** 载入知乎 Cookie：环境变量优先，其次 ~/.cspub/config.json 的 zhihuCookie 字段 */
func loadZhihuCookie(): String {
    let c = loadConfigString("CSPUB_ZHIHU_COOKIE", "zhihuCookie")
    if (c.size == 0) {
        println("错误：没有找到知乎 Cookie。")
        println("  方式一：export CSPUB_ZHIHU_COOKIE='<浏览器复制的 Cookie 整串，须含 z_c0>'")
        println("  方式二：mkdir -p ~/.cspub && 写 ~/.cspub/config.json：{\"zhihuCookie\": \"...\"}")
        println("  获取：浏览器登录 zhuanlan.zhihu.com → F12 → 任一请求 → 复制 Cookie 请求头整串")
    }
    return c
}

/** 载入百家号开发者凭证：环境变量优先，其次 ~/.cspub/config.json；缺失返回空串（调用方兜底 Cookie 通道） */
func loadBjhCreds(): (String, String) {
    let appId = loadConfigString("CSPUB_BAIJIAHAO_APP_ID", "baijiahaoAppId")
    let token = loadConfigString("CSPUB_BAIJIAHAO_APP_TOKEN", "baijiahaoAppToken")
    return (appId, token)
}

/** 通用凭证读取：环境变量 envName 优先，其次 ~/.cspub/config.json 的 jsonKey 字符串字段 */
func loadConfigString(envName: String, jsonKey: String): String {
    match (getVariable(envName)) {
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
                        if (let Some(v) <- obj.get(jsonKey)) {
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
    return ""
}
