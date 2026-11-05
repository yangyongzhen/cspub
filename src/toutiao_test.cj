/** 头条号单元测试：请求体构造、响应解析、错误码映射、标题字符校验、图片标签改写。
 *
 * 重点覆盖实测出来的反直觉点（见 docs/多平台发文调研.md §三）：
 * ① 响应 code 是 **JSON 数字**——用只认字符串的 jsonStr 取会得空串，0 与未登录都算不清；
 * ② 未登录有**两套码**：mp/agw 通用是 100004/100005，图片上传接口是 1000，三者都得认；
 * ③ 7115「图片 uri 非法」不是登录问题，必须能与登录码区分开，否则会去白排查 Cookie；
 * ④ 标题 5~30 字按**字符**不按字节，7 个汉字是 7 字（按字节算成 21 会误判超限）。
 *
 * 图片管线是头条独有的一段（别的平台外链可留用，头条必须全部进自家 CDN），
 * collectImgSrcs / rewriteHtmlImgs 两个纯函数单测覆盖，网络上传留给真机验证。
 */
package cspub

import std.collection.*
import stdx.encoding.json.*
import std.unittest.*

@Test
func toutiaoBodyAllFieldsTest(): Unit {
    let s = buildToutiaoArticleBody("标题五个字", "<p>正文</p>", 0, "")
    let v = JsonValue.fromStr(s)
    let keys: Array<String> = [
        "title", "content", "article_ad_type", "article_type", "from_diagnosis",
        "origin_debut_check_pgc_normal", "tree_plan_article", "save", "pgc_id",
        "pgc_feed_covers"
    ]
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            // 头条后台对缺字段的容忍度未知，先保证形状与抓包一致，逐个点名
            for (k in keys) {
                @Assert(obj.get(k).isSome(), true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func toutiaoSaveAndPgcIdTest(): Unit {
    let live = JsonValue.fromStr(buildToutiaoArticleBody("t", "<p>x</p>", 0, ""))
    match (live.kind()) {
        case JsonKind.JsObject =>
            let obj = live.asObject()
            // save=0 发布
            match (obj.get("save")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsInt => @Assert(x.asInt().getValue(), 0)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // pgc_id 是字符串 "0"（新建）；写成数字会被判参数错误
            match (obj.get("pgc_id")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => @Assert(x.asString().getValue(), "0")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // 不设封面时是字符串 "[]"，不是 JSON 数组
            match (obj.get("pgc_feed_covers")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => @Assert(x.asString().getValue(), "[]")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
    // save=1 存草稿
    let draft = JsonValue.fromStr(buildToutiaoArticleBody("t", "<p>x</p>", 1, ""))
    match (draft.kind()) {
        case JsonKind.JsObject =>
            match (draft.asObject().get("save")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsInt => @Assert(x.asInt().getValue(), 1)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
    // 显式封面 JSON 原样落地（不能被 "[]" 覆盖）
    let withCover = JsonValue.fromStr(buildToutiaoArticleBody("t", "<p>x</p>", 0, "[\"tos-cn-1\"]"))
    match (withCover.kind()) {
        case JsonKind.JsObject =>
            match (withCover.asObject().get("pgc_feed_covers")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => @Assert(x.asString().getValue(), "[\"tos-cn-1\"]")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func toutiaoRespParseTest(): Unit {
    // 成功体：code 是数字 0，pgc_id 是**字符串**
    let (c1, m1, id1) = parseToutiaoResp("{\"code\":0,\"data\":{\"pgc_id\":\"7031386221209256455\"}}")
    @Assert(c1, 0)
    @Assert(m1, "")
    @Assert(id1, "7031386221209256455")

    // publish 未登录（实测原样响应）
    let (c2, m2, id2) = parseToutiaoResp("{\"code\":100005,\"data\":{\"pgc_id\":\"0\"},\"err_no\":100005,\"message\":\"获取用户信息失败\",\"now\":1793912296,\"reason\":\"获取用户信息失败\"}")
    @Assert(c2, 100005)
    @Assert(m2, "获取用户信息失败")
    @Assert(id2, "0")

    // 图片上传未登录：code 是数字 1000，中文在 message 里（实测原样响应）
    let (c3, m3, _) = parseToutiaoResp("{\"code\":1000,\"height\":0,\"message\":\"用户未登录\",\"state\":\"\",\"web_uri\":\"\",\"url\":\"\"}")
    @Assert(c3, 1000)
    @Assert(m3, "用户未登录")

    // 只有 reason 没有 message 时回落 reason，别把错误说成空串
    let (_, m4, _) = parseToutiaoResp("{\"code\":500,\"reason\":\"系统繁忙\"}")
    @Assert(m4, "系统繁忙")

    // 非 JSON / 空体不崩
    let (c5, _, id5) = parseToutiaoResp("<html>502 Bad Gateway</html>")
    @Assert(c5, 0)
    @Assert(id5, "")
    let (c6, _, id6) = parseToutiaoResp("")
    @Assert(c6, 0)
    @Assert(id6, "")
}

@Test
func toutiaoLoginCodeTest(): Unit {
    @Assert(toutiaoLoginCode(100005), true)
    @Assert(toutiaoLoginCode(100004), true)
    @Assert(toutiaoLoginCode(1000), true)
    // 7115 是「图片 uri 非法」，不是登录问题——混进登录码会让人以为 Cookie 过期
    @Assert(toutiaoLoginCode(7115), false)
    @Assert(toutiaoLoginCode(0), false)
    @Assert(toutiaoLoginCode(303), false)
}

@Test
func toutiaoTitleTest(): Unit {
    // 按字符不按字节
    @Assert(toutiaoTitleChars("头条号发文"), 5)
    @Assert(toutiaoTitleChars("abc"), 3)
    @Assert(toutiaoTitleChars("a中b"), 3)
    @Assert(toutiaoTitleChars(""), 0)

    @Assert(toutiaoTitleOk("abcd"), false)   // 4 字，低于下限
    @Assert(toutiaoTitleOk("abcde"), true)   // 5 字，恰好通过
    // 30 字（"一二三四五六七八九十" × 3）恰好通过，31 字被拒
    @Assert(toutiaoTitleOk("一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十"), true)
    @Assert(toutiaoTitleOk("一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一"), false)
    // 两侧空格不计入字数（后台按 trim 后的标题算）
    @Assert(toutiaoTitleOk("   abcde   "), true)
    @Assert(toutiaoTitleOk("   abcd   "), false)
}

@Test
func toutiaoCookieTest(): Unit {
    @Assert(toutiaoCookieHasSession("sessionid=abc; tt_webid=1"), true)
    @Assert(toutiaoCookieHasSession("tt_webid=1"), true)
    // 只有埋点/灰度字段不算登录态；tt_webid_v2 不能被当成 tt_webid 误命中
    @Assert(toutiaoCookieHasSession("_ga=1; tt_webid_v2=2"), false)
    @Assert(toutiaoCookieHasSession(""), false)

    // X-CSRFToken 优先 csrftoken，退一步 csrf_sessionid
    @Assert(toutiaoCsrfToken("csrftoken=abc123; sessionid=x"), "abc123")
    @Assert(toutiaoCsrfToken("csrf_sessionid=tok9; sessionid=x"), "tok9")
    @Assert(toutiaoCsrfToken("sessionid=x"), "")
    @Assert(toutiaoCsrfToken(""), "")
}

@Test
func toutiaoCollectImgTest(): Unit {
    let html = "<p>a</p><img src=\"https://a.com/1.png\" alt=\"x\"><img src=\"b.jpg\" alt=\"y\">"
    let u = collectImgSrcs(html)
    @Assert(u.size, 2)
    @Assert(u[0], "https://a.com/1.png")
    @Assert(u[1], "b.jpg")

    @Assert(collectImgSrcs("<p>无图正文</p>").size, 0)
    @Assert(collectImgSrcs("").size, 0)
    // 空 src 不收集（否则会拿空串去下载）
    @Assert(collectImgSrcs("<img src=\"\" alt=\"x\">").size, 0)
}

@Test
func toutiaoRewriteImgTest(): Unit {
    let html = "<p>x</p><img src=\"https://a.com/1.png\" alt=\"图\"><img src=\"https://keep.com/2.png\" alt=\"留\">"
    let m = HashMap<String, String>()
    m.add("https://a.com/1.png", "<img src=\"https://p3.toutiaoimg.com/1.png\" web_uri=\"tos-cn-1\"")
    let out = rewriteHtmlImgs(html, m)
    // 命中：换成头条链接并补 web_uri（头条认这个属性）
    @Assert(out.contains("https://p3.toutiaoimg.com/1.png"), true)
    @Assert(out.contains("web_uri=\"tos-cn-1\""), true)
    // alt 不能被吃掉
    @Assert(out.contains("alt=\"图\""), true)
    // 未命中的图原样保留（不静默丢图）
    @Assert(out.contains("https://keep.com/2.png"), true)

    // 空映射 = 原文一字不改
    let empty = HashMap<String, String>()
    @Assert(rewriteHtmlImgs(html, empty), html)
    @Assert(rewriteHtmlImgs("", empty), "")
}

@Test
func toutiaoUrlTest(): Unit {
    @Assert(toutiaoArticleUrl("7031386221209256455"),
        "https://www.toutiao.com/article/7031386221209256455/")
    @Assert(toutiaoDraftUrl("703"),
        "https://mp.toutiao.com/profile_v3/graphic/publish?pgc_id=703")
}
