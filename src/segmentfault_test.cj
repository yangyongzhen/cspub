/** SegmentFault 单元测试：token 抠取、请求体构造、响应解析。
 *
 * 重点覆盖实测出来的反直觉点（见 docs/多平台发文调研.md §九）：
 * ① Token **不在 Cookie 里**，只能从写文章页的 `__NEXT_DATA__` 抠；未登录时它是空串，
 *    必须如实返回 "" —— 否则会带着空 Token 去撞 401，让人误以为是 Cookie 过期；
 * ② 网关的错误体是**一个 JSON 字符串**（`"Unauthorized"`）而不是对象，
 *    只按对象解析会把原因丢干净；
 * ③ `tags` 是**数组**不是逗号串，塞字符串进去后端会判参数错误；
 * ④ `cover` 空串不能带——空封面容易被判非法。
 *
 * 网络部分（取 token、提交、图片）留给真机验证：本机无思否登录态。
 */
package cspub

import std.unittest.*
import stdx.encoding.json.*

@Test
func sfExtractTokenOkTest(): Unit {
    let html = "<script id=\"__NEXT_DATA__\" type=\"application/json\">" +
        "{\"props\":{\"pageProps\":{}},\"serverData\":{\"Token\":\"abc123def456\",\"userAgent\":\"ua\",\"platform\":\"\"}}" +
        "</script>"
    @Assert(extractSegmentfaultToken(html), "abc123def456")
}

@Test
func sfExtractTokenEmptyWhenLoggedOutTest(): Unit {
    // 未登录实测就是空串：空串必须原样返回，不能当成「没找到」去猜别的字段
    let html = "{\"serverData\":{\"Token\":\"\",\"userAgent\":\"ua\",\"platform\":\"\"}}"
    @Assert(extractSegmentfaultToken(html), "")
}

@Test
func sfExtractTokenMissingAnchorTest(): Unit {
    // 页面结构变了（或拿到的是登录页）→ 空串，调用方据此报「Cookie 不是登录态」
    @Assert(extractSegmentfaultToken("<html><body>登录 - SegmentFault 思否</body></html>"), "")
    @Assert(extractSegmentfaultToken(""), "")
}

@Test
func sfTagsSplitTest(): Unit {
    let tags = parseSegmentfaultTags("Cangjie, 仓颉 ,, 后端 ,")
    @Assert(tags.size, 3)
    @Assert(tags[0], "Cangjie")
    @Assert(tags[1], "仓颉")
    @Assert(tags[2], "后端")
    // 全空输入要得到空数组，不是含空串的数组
    @Assert(parseSegmentfaultTags("").size, 0)
    @Assert(parseSegmentfaultTags(" , ").size, 0)
}

@Test
func sfBodyFieldsTest(): Unit {
    let s = buildSegmentfaultArticleBody("标题", "<p>正文</p>", ["Cangjie", "后端"], "",
        "article", "zh-CN", "")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            @Assert(obj.containsKey("title"), true)
            @Assert(obj.containsKey("tags"), true)
            @Assert(obj.containsKey("text"), true)
            @Assert(obj.containsKey("object_id"), true)
            @Assert(obj.containsKey("type"), true)
            @Assert(obj.containsKey("language"), true)
            // cover 空串时不带这个键
            @Assert(obj.containsKey("cover"), false)
            // tags 必须是数组（JsonKind 没有 ==，只能 match，AGENTS §4）
            if (let Some(tv) <- obj.get("tags")) {
                var isArr = false
                match (tv.kind()) {
                    case JsonKind.JsArray => isArr = true
                    case _ => ()
                }
                @Assert(isArr, true)
                if (isArr) {
                    @Assert(tv.asArray().size(), 2)
                }
            } else {
                @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func sfBodyCoverTest(): Unit {
    let s = buildSegmentfaultArticleBody("t", "<p>x</p>", Array<String>(), "old-id",
        "article", "zh-CN", "https://img.example.com/c.png")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            @Assert(obj.containsKey("cover"), true)
            // object_id 原样带上（改草稿时要用）
            if (let Some(ov) <- obj.get("object_id")) {
                @Assert(ov.asString().getValue(), "old-id")
            }
        case _ => @Assert(false, true)
    }
}

@Test
func sfBodyEscapesHtmlTest(): Unit {
    // 正文含引号/换行/反斜杠：JSON 必须转义，否则请求体直接是坏 JSON
    let s = buildSegmentfaultArticleBody("a\"b", "<p>行1\n行2</p>", Array<String>(), "",
        "article", "zh-CN", "")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            if (let Some(tv) <- v.asObject().get("text")) {
                @Assert(tv.asString().getValue(), "<p>行1\n行2</p>")
            }
        case _ => @Assert(false, true)
    }
}

@Test
func sfRespPlainStringTest(): Unit {
    // 网关错误体是 JSON 字符串，不是对象——原样当 msg
    let (code, msg, id) = parseSegmentfaultResp("\"Unauthorized\"")
    @Assert(code, 0)
    @Assert(msg, "Unauthorized")
    @Assert(id, "")
}

@Test
func sfRespObjectTest(): Unit {
    let (code, msg, id) = parseSegmentfaultResp("{\"id\":\"119000004000123\",\"title\":\"x\"}")
    @Assert(code, 0)
    @Assert(msg, "")
    @Assert(id, "119000004000123")
}

@Test
func sfRespBadJsonTest(): Unit {
    // 挡在网关外的 HTML 错误页（WAF/反爬）不能抛异常，退回全空
    let (code, msg, id) = parseSegmentfaultResp("<html>403 Forbidden</html>")
    @Assert(code, 0)
    @Assert(msg, "")
    @Assert(id, "")
    // 空响应同样不能抛异常（元组下标在宏里解析不了，先绑定再断言）
    let (c2, m2, i2) = parseSegmentfaultResp("")
    @Assert(c2, 0)
    @Assert(m2, "")
    @Assert(i2, "")
}
