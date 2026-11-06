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
            let action = imgPreviewAction(m.url)
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
    // 版本号唯一真相在 cjpm.toml 的 version，此处仅回显，改动时须同步
    println("cspub v0.3.0 — 多平台自动发文 CLI（仓颉实现）：csdn / zhihu / baijiahao / cnblogs / juejin / oschina / tencent / yuque / toutiao / segmentfault")
    println("")
    println("用法:")
    println("  cspub check   <文章.md>            解析 front-matter + 渲染统计（不联网）")
    println("  cspub publish <文章.md> [--draft]  发草稿（默认）")
    println("                      [--live]       直接发布（覆盖 front-matter 的 draft: true）")
    println("                      [--update id]  原地更新指定文章（仅 csdn）")
    println("                      [--platform p] csdn（默认）/ zhihu / baijiahao / cnblogs / juejin / oschina / tencent / yuque / toutiao / segmentfault")
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
    println("  oschina:   CSPUB_OSCHINA_COOKIE（须含 oscid）+ 可选 CSPUB_OSCHINA_USER_ID/CATALOG/PRIVACY")
    println("             （privacy=true 发成仅自己可见；分类默认按 front-matter 名匹配，否则取第一个）")
    println("  tencent:   CSPUB_TENCENT_COOKIE（须含 uin，且 skey 或 qcommunity_session 之一）")
    println("             + CSPUB_TENCENT_CLASSIFY_IDS（专栏 id，须是自己已加入的专栏；默认 149=技术常因无成员权限回 300031）")
    println("             + CSPUB_TENCENT_TAG_IDS（文章标签 id，逗号分隔；--live 发布必填，空则服务端回 -9993）")
    println("             走社区编辑器自身的 RPC（/developer/services/ajax/column/article，零签名）")
    println("             --draft 真存草稿（回显 draftId 与编辑地址），--live 在同一链路上创建并发布")
    println("  yuque:     CSPUB_YUQUE_TOKEN（X-Auth-Token）+ CSPUB_YUQUE_NAMESPACE（user/repo 两段式）")
    println("             + 可选 CSPUB_YUQUE_PUBLIC（0 私密 / 1 公开 / 2 企业内公开；不配则继承知识库）")
    println("             官方 OpenAPI v2，Markdown 原样提交；--draft 建成 public=0 的私密文档（等同草稿）")
    println("  toutiao:   CSPUB_TOUTIAO_COOKIE（须含 sessionid 或 tt_webid）+ 可选 CSPUB_TOUTIAO_CSRF")
    println("             模拟后台 mp/agw 接口，X-CSRFToken 默认自动取 cookie 的 csrftoken")
    println("             图片硬约束：正文每张图都要转存头条 CDN，任何非头条域名 → 整篇拒稿 7115")
    println("             **头条没有草稿通道**：save 非 0 即提交发布（1/3/4 等价），save=0 需浏览器风控签名")
    println("  segmentfault: CSPUB_SEGMENTFAULT_COOKIE（思否登录后的整串 Cookie）")
    println("             走 /gateway 网关，零签名；Token 于发文时从写文章页 __NEXT_DATA__ 实时取")
    println("             正文是 HTML 富文本，--draft 存草稿箱、--live 直接发布")
    println("  图片外链:  CSPUB_ATOMGIT_TOKEN（+可选 CSPUB_ATOMGIT_REPO/BRANCH/DIR，默认 ${"qq8864/images"} main cspub）")
    println("             配了令牌则本地图上传 AtomGit 仓库、正文嵌 raw 外链（掘金认外链，不依赖浏览器）")
    println("             （正文图片转存走浏览器通道，需 python3+playwright+chromium）")
    println("  图片门禁:  CSPUB_STRICT_IMAGES=1 —— 正文仍有本地图片未转存就中止发布（默认 best-effort 照发）")
    println("  伴生脚本:  CSPUB_SCRIPT_DIR=<cspub 仓库根>（默认依次找 当前目录 / 可执行文件目录向上 5 级）")
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

/** 载入开源中国凭证：环境变量优先，其次 ~/.cspub/config.json。
 * 只要 Cookie（含 oscid）就能发文；userId/catalog 可选，省一次接口探测。 */
func loadOschinaCreds(): (String, String, String, Bool) {
    let cookie = loadConfigString("CSPUB_OSCHINA_COOKIE", "oschinaCookie")
    let userId = loadConfigString("CSPUB_OSCHINA_USER_ID", "oschinaUserId")
    let catalog = loadConfigString("CSPUB_OSCHINA_CATALOG", "oschinaCatalog")
    let privacyRaw = loadConfigString("CSPUB_OSCHINA_PRIVACY", "oschinaPrivacy")
    let privacy = privacyRaw == "true" || privacyRaw == "1"
    if (cookie.size == 0) {
        println("错误：没有找到开源中国 Cookie。")
        println("  开源中国用登录 Cookie 直通站点接口，须包含 oscid")
        println("  方式一：export CSPUB_OSCHINA_COOKIE='oscid=…'")
        println("  方式二：~/.cspub/config.json 写 {\"oschinaCookie\": \"oscid=…\"}")
        println("  可选：CSPUB_OSCHINA_USER_ID / CSPUB_OSCHINA_CATALOG / CSPUB_OSCHINA_PRIVACY=true（仅自己可见）")
        return (cookie, userId, catalog, privacy)
    }
    if (!oschinaCookieHasSession(cookie)) {
        println("警告：Cookie 里没有 oscid，可能不是登录态整串（要浏览器登录 oschina.net 后复制的 Cookie）")
    }
    return (cookie, userId, catalog, privacy)
}

/** 载入腾讯云凭证：Cookie + 可选专栏 id + 可选文章标签 id。
 * Cookie 缺失给可行动报错（不是笼统的「配置缺失」）。 */
func loadTencentCreds(): (String, String, String) {
    let cookie = loadConfigString("CSPUB_TENCENT_COOKIE", "tencentCookie")
    let classify = loadConfigString("CSPUB_TENCENT_CLASSIFY_IDS", "tencentClassifyIds")
    let tags = loadConfigString("CSPUB_TENCENT_TAG_IDS", "tencentTagIds")
    if (cookie.size == 0) {
        println("错误：没有找到腾讯云开发者社区 Cookie。")
        println("  方式一：export CSPUB_TENCENT_COOKIE='<浏览器登录 cloud.tencent.com 后复制的 Cookie 整串，须含 skey>'")
        println("  方式二：~/.cspub/config.json 写 {\"tencentCookie\": \"...\"}")
        println("  可选：CSPUB_TENCENT_CLASSIFY_IDS=149（专栏 id，逗号分隔，默认 149=技术）")
        println("  可选：CSPUB_TENCENT_TAG_IDS=10757,17183（文章标签 id，--live 发布时必填）")
        println("  注意：skey 里的 * 原样保留，不要做 URL 编码")
    }
    return (cookie, classify, tags)
}

/** 载入语雀凭证：Token + namespace + 可选公开性。两者都是必填，缺哪个就点名哪个。 */
func loadYuqueCreds(): (String, String, Int64) {
    let token = loadConfigString("CSPUB_YUQUE_TOKEN", "yuqueToken")
    let ns = trimAscii(loadConfigString("CSPUB_YUQUE_NAMESPACE", "yuqueNamespace"))
    let pubCfg = loadConfigString("CSPUB_YUQUE_PUBLIC", "yuquePublic")
    if (token.size == 0) {
        println("错误：没有找到语雀 Token。")
        println("  方式一：export CSPUB_YUQUE_TOKEN='<https://www.yuque.com/settings/tokens 生成的 Token>'")
        println("  方式二：~/.cspub/config.json 写 {\"yuqueToken\": \"...\"}")
    }
    if (ns.size == 0) {
        println("错误：没有找到语雀知识库 namespace。")
        println("  export CSPUB_YUQUE_NAMESPACE='user/repo'（取知识库 URL 里那两段，单段名一定 404）")
    }
    return (token, ns, parseYuquePublic(pubCfg))
}

/** 载入头条号凭证：Cookie + X-CSRFToken。CSRF 默认从 cookie 的 csrftoken 取，
 * 允许显式覆盖（个别账号只在请求头里认 token，cookie 里没有）。 */
func loadToutiaoCreds(): (String, String) {
    let cookie = loadConfigString("CSPUB_TOUTIAO_COOKIE", "toutiaoCookie")
    let csrfCfg = trimAscii(loadConfigString("CSPUB_TOUTIAO_CSRF", "toutiaoCsrf"))
    if (cookie.size == 0) {
        println("错误：没有找到头条号 Cookie。")
        println("  方式一：export CSPUB_TOUTIAO_COOKIE='<浏览器登录 mp.toutiao.com 后复制的 Cookie 整串，须含 sessionid>'")
        println("  方式二：~/.cspub/config.json 写 {\"toutiaoCookie\": \"...\"}")
        println("  可选：CSPUB_TOUTIAO_CSRF=<X-CSRFToken>（默认自动取 cookie 里的 csrftoken）")
    }
    let csrf = if (csrfCfg.size > 0) { csrfCfg } else { toutiaoCsrfToken(cookie) }
    return (cookie, csrf)
}

/** 载入思否凭证：只需要 Cookie 整串。思否的 Token 不在 Cookie 里（发文时从写文章页实时取），
 * 所以这里无法像别家那样校验某个 cookie 字段——登录与否由 publish 取 token 时判定。 */
func loadSegmentfaultCreds(): String {
    let cookie = loadConfigString("CSPUB_SEGMENTFAULT_COOKIE", "segmentfaultCookie")
    if (cookie.size == 0) {
        println("错误：没有找到思否 Cookie。")
        println("  方式一：export CSPUB_SEGMENTFAULT_COOKIE='<浏览器登录 segmentfault.com 后复制的 Cookie 整串>'")
        println("  方式二：~/.cspub/config.json 写 {\"segmentfaultCookie\": \"...\"}")
        println("  注意：思否没有可自查的登录 cookie 字段，真正的 Token 在发文时从写文章页取")
    }
    return cookie
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

/** 载入 AtomGit 图床配置（可选）：配了令牌则图片走外链优先，否则沿用平台图床通道。
 * 默认仓库/分支/目录给了 cspub 的常用值，环境里只需提供令牌即可用。 */
func loadAtomgitImageConf(): (String, String, String, String) {
    let token = loadConfigString("CSPUB_ATOMGIT_TOKEN", "atomgitToken")
    var repo = loadConfigString("CSPUB_ATOMGIT_REPO", "atomgitRepo")
    if (repo.size == 0) {
        repo = "qq8864/images"
    }
    var branch = loadConfigString("CSPUB_ATOMGIT_BRANCH", "atomgitBranch")
    if (branch.size == 0) {
        branch = "main"
    }
    var dir = loadConfigString("CSPUB_ATOMGIT_DIR", "atomgitDir")
    if (dir.size == 0) {
        dir = "cspub"
    }
    return (token, repo, branch, dir)
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
        let (agToken, agRepo, _, agDir) = loadAtomgitImageConf()
        if (agToken.size > 0) {
            println("图片通道  : 外链优先（AtomGit ${agRepo} / ${agDir}）")
        } else {
            println("图片通道  : 平台图床（未配置 CSPUB_ATOMGIT_TOKEN；会走 ImageX 浏览器通道）")
        }
        println("Cookie 配置可用（未联网验证；publish 时以掘金实际响应为准）")
        return 0
    }
    if (platform == "tencent") {
        let (tCookie, tClassify, _) = loadTencentCreds()
        if (tCookie.size == 0) {
            return 1
        }
        let hasSkey = cookieValue(tCookie, "skey").size > 0
        let hasSess = cookieValue(tCookie, "qcommunity_session").size > 0
        println("skey              : ${if (hasSkey) { "存在" } else { "缺失" }}")
        println("qcommunity_session: ${if (hasSess) { "存在" } else { "缺失" }}")
        println("Cookie 长度       : ${tCookie.toArray().size} 字节")
        println("专栏 classifyIds  : ${if (tClassify.size > 0) { tClassify } else { "默认 149（技术）" }}")
        println("提示：登录态是否还有效只能真发一次才知道——addArticle 先校验参数再校验登录，空体返回 400 不代表 Cookie 失效")
        return if (hasSkey || hasSess) { 0 } else { 1 }
    }
    if (platform == "yuque") {
        let (qToken, qNs, qPublic) = loadYuqueCreds()
        if (qToken.size == 0 || qNs.size == 0) {
            return 1
        }
        let nsOk = yuqueNamespaceValid(qNs)
        println("namespace : ${qNs}（${if (nsOk) { "两段式，格式正确" } else { "**格式错误**：必须 user/repo 或 group/book_slug" }}）")
        println("public    : ${if (qPublic < 0) { "不传，继承知识库公开性" } else { "${qPublic}" }}")
        println("Token     : 联网校验中（GET /api/v2/user，语雀是唯一能真验凭证的平台）…")
        let (qLogin, qName) = fetchYuqueUser(qToken, false)
        if (qLogin.size == 0) {
            println("Token     : **校验失败**（401 = Token 无效/过期；其它 = 网络或证书问题）")
            return 1
        }
        println("Token     : 有效，登录用户 ${qLogin}${if (qName.size > 0) { "（" + qName + "）" } else { "" }}")
        return if (nsOk) { 0 } else { 1 }
    }
    if (platform == "toutiao") {
        let (tCookie, tCsrf) = loadToutiaoCreds()
        if (tCookie.size == 0) {
            return 1
        }
        let hasSess = cookieValue(tCookie, "sessionid").size > 0
        let hasWeb = cookieValue(tCookie, "tt_webid").size > 0
        println("sessionid   : ${if (hasSess) { "存在" } else { "缺失" }}")
        println("tt_webid    : ${if (hasWeb) { "存在" } else { "缺失" }}")
        println("X-CSRFToken : ${if (tCsrf.size > 0) { "已取得（${tCsrf.size} 字节）" } else { "**缺失**：cookie 里没有 csrftoken" }}")
        println("Cookie 长度 : ${tCookie.toArray().size} 字节")
        println("提示：头条无开放发布 API，本工具模拟后台 mp/agw 接口；正文任一非头条域名图片都会整篇拒稿（7115）")
        println("      头条没有草稿通道：save 非 0 即发布（有审核队列，约每日 4 篇上限）；save=0 需浏览器风控签名")
        return if (hasSess || hasWeb) { 0 } else { 1 }
    }
    if (platform == "segmentfault") {
        let sfCookie = loadSegmentfaultCreds()
        if (sfCookie.size == 0) {
            return 1
        }
        println("Cookie 长度 : ${sfCookie.toArray().size} 字节")
        println("Token       : 联网校验中（GET /write 抠 serverData.Token）…")
        let (sfToken, sfStatus) = fetchSegmentfaultToken(sfCookie, false)
        if (sfToken.size == 0) {
            if (sfStatus != 200) {
                println("Token       : **取页失败**（HTTP ${sfStatus}）——网络或证书问题，可试 --insecure")
            } else {
                println("Token       : **空**——Cookie 不是登录态（重新登录 segmentfault.com 后复制整串）")
            }
            return 1
        }
        println("Token       : 已取得（${sfToken.size} 字节），Cookie 是有效登录态")
        return 0
    }
    if (platform == "oschina") {
        let (cookie, userId, catalog, privacy) = loadOschinaCreds()
        if (cookie.size == 0) {
            return 1
        }
        let sid = cookieValue(cookie, "oscid")
        if (sid.size == 0) {
            println("Cookie 里没有 oscid——不是登录态整串（要浏览器登录 oschina.net 后复制的 Cookie）")
            return 1
        }
        println("oscid   : 存在（${sid.size} 字节）")
        println("userId  : ${if (userId.size > 0) { userId } else { "未配置（publish 时自动向接口查询）" }}")
        println("catalog : ${if (catalog.size > 0) { catalog } else { "未配置（按 front-matter 分类名匹配，否则取账号第一个分类）" }}")
        println("privacy : ${if (privacy) { "私有（仅自己可见）" } else { "公开" }}")
        let (agToken, agRepo, _, agDir) = loadAtomgitImageConf()
        println("图片通道: 平台自带图床（oscimg.oschina.net）优先，无需额外配置")
        if (agToken.size > 0) {
            println("          失败兜底 AtomGit 外链（${agRepo} / ${agDir}）")
        } else {
            println("          未配 CSPUB_ATOMGIT_TOKEN：平台图床失败时保留原引用")
        }
        println("Cookie 配置可用（未联网验证；publish 时以开源中国实际响应为准）")
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
        let (atomgitToken, atomgitRepo, atomgitBranch, atomgitDir) = loadAtomgitImageConf()
        println("发布到掘金（${mode}）…")
        return publishToJuejin(cookie, uuid, categoryId, tagArr, a, publishNow, insecure,
            atomgitToken, atomgitRepo, atomgitBranch, atomgitDir)
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
    if (platform == "oschina") {
        let (cookie, userId, catalog, privacy) = loadOschinaCreds()
        if (cookie.size == 0) {
            return 1
        }
        let osMode = if (publishNow) { "publish" } else { "draft" }
        let (atomgitToken, atomgitRepo, atomgitBranch, atomgitDir) = loadAtomgitImageConf()
        println("发布到开源中国（${osMode}）…")
        return publishToOschina(cookie, userId, catalog, privacy, a, publishNow, insecure,
            atomgitToken, atomgitRepo, atomgitBranch, atomgitDir)
    }
    if (platform == "tencent") {
        let (tCookie, tClassify, tTags) = loadTencentCreds()
        if (tCookie.size == 0) {
            return 1
        }
        if (!tencentCookieHasSession(tCookie)) {
            println("警告：Cookie 里没有 skey / qcommunity_session，多半不是登录态整串")
        }
        let tMode = if (publishNow) { "publish" } else { "存草稿（可逆）" }
        let (tToken, tRepo, tBranch, tDir) = loadAtomgitImageConf()
        println("发布到腾讯云开发者社区（${tMode}）…")
        return publishToTencent(tCookie, tClassify, tTags, a, publishNow, insecure, tToken, tRepo, tBranch, tDir)
    }
    if (platform == "yuque") {
        let (qToken, qNs, qPublic) = loadYuqueCreds()
        if (qToken.size == 0 || qNs.size == 0) {
            return 1
        }
        // 单段 namespace 必然 404，本地先拦，别拿一个注定失败的请求去怀疑 Token
        if (!yuqueNamespaceValid(qNs)) {
            println("错误：语雀 namespace `" + qNs + "` 不是两段式")
            println("提示：必须是 user/repo 或 group/book_slug（取知识库 URL 里那两段）")
            return 1
        }
        let qMode = if (publishNow) { "publish" } else { "draft（public=0 私密）" }
        let (qImgToken, qRepo, qBranch, qDir) = loadAtomgitImageConf()
        println("发布到语雀（${qMode}）…")
        return publishToYuque(qToken, qNs, qPublic, a, publishNow, insecure, qImgToken, qRepo, qBranch, qDir)
    }
    if (platform == "toutiao") {
        let (tCookie, tCsrf) = loadToutiaoCreds()
        if (tCookie.size == 0) {
            return 1
        }
        if (!toutiaoCookieHasSession(tCookie)) {
            println("警告：Cookie 里没有 sessionid / tt_webid，多半不是登录态整串")
        }
        if (tCsrf.size == 0) {
            println("警告：没能从 cookie 取到 csrftoken，X-CSRFToken 头将缺失（头条风控多半会挡）")
            println("      可显式给：CSPUB_TOUTIAO_CSRF=<后台请求里的 X-CSRFToken>")
        }
        let tMode = if (publishNow) { "提交发布（save=1）" } else { "未提交（头条无草稿通道）" }
        let (tToken, tRepo, tBranch, tDir) = loadAtomgitImageConf()
        println("发布到头条号（${tMode}）…")
        return publishToToutiao(tCookie, tCsrf, a, publishNow, insecure, tToken, tRepo, tBranch, tDir)
    }
    if (platform == "segmentfault") {
        let sfCookie = loadSegmentfaultCreds()
        if (sfCookie.size == 0) {
            return 1
        }
        let sfMode = if (publishNow) { "publish" } else { "draft" }
        let (sfImgToken, sfRepo, sfBranch, sfDir) = loadAtomgitImageConf()
        println("发布到 SegmentFault 思否（${sfMode}）…")
        return publishToSegmentfault(sfCookie, a, publishNow, insecure,
            sfImgToken, sfRepo, sfBranch, sfDir)
    }
    if (platform != "csdn") {
        println("未知平台：${platform}（可选 csdn / zhihu / baijiahao / cnblogs / juejin / oschina / tencent / yuque / toutiao / segmentfault）")
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
    if (imagesRemainGate("csdn", a2.body, strictImagesEnabled())) {
        return 1
    }
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
