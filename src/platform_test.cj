/** 多平台（zhihu / baijiahao）单元测试：请求体构造、响应解析、凭证与标题校验 */
package cspub

import stdx.encoding.json.*
import std.unittest.*

@Test
func zhihuCreateBodyTest(): Unit {
    let s = buildZhihuCreateBody("标题A")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            match (obj.get("title")) {
                case Some(t) =>
                    match (t.kind()) {
                        case JsonKind.JsString => @Assert(t.asString().getValue(), "标题A")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            match (obj.get("content")) {
                case Some(c) =>
                    match (c.kind()) {
                        case JsonKind.JsString => @Assert(c.asString().getValue(), "")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func zhihuDraftIdParseTest(): Unit {
    // id 是数字
    @Assert(parseZhihuDraftId("{\"id\": 123456, \"title\": \"t\"}"), "123456")
    // id 是字符串
    @Assert(parseZhihuDraftId("{\"id\": \"987\"}"), "987")
    // 没有 id
    @Assert(parseZhihuDraftId("{\"error\": \"bad_request\"}"), "")
    // 非 JSON
    @Assert(parseZhihuDraftId("<html>blocked</html>"), "")
}

@Test
func bjhPayloadTest(): Unit {
    let s = buildBjhPayload("10001", "tok", "测试标题八字以上", "<p>正文</p>",
        "https://example.com/a", "https://img.example.com/1.png", true)
    let v = JsonValue.fromStr(s)
    var coverRaw = ""
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            match (obj.get("app_id")) {
                case Some(x) => @Assert(x.asString().getValue(), "10001")
                case None => @Assert(false, true)
            }
            match (obj.get("origin_url")) {
                case Some(x) => @Assert(x.asString().getValue(), "https://example.com/a")
                case None => @Assert(false, true)
            }
            match (obj.get("is_original")) {
                case Some(x) => @Assert(x.asInt().getValue(), 1)
                case None => @Assert(false, true)
            }
            match (obj.get("cover_images")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => coverRaw = x.asString().getValue()
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
    // cover_images 是内嵌 JSON 字符串（官方要求），解析回数组取 src
    let inner = JsonValue.fromStr(coverRaw)
    match (inner.kind()) {
        case JsonKind.JsArray =>
            let arr = inner.asArray()
            @Assert(arr.size(), 1)
            match (arr.get(0)) {
                case Some(first) =>
                    match (first.kind()) {
                        case JsonKind.JsObject =>
                            match (first.asObject().get("src")) {
                                case Some(x) => @Assert(x.asString().getValue(), "https://img.example.com/1.png")
                                case None => @Assert(false, true)
                            }
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
    // 草稿模式：无封面 → cover_images 字段不存在
    let draft = JsonValue.fromStr(buildBjhPayload("10001", "tok", "测试标题八字以上", "<p/>", "u", "", false))
    match (draft.kind()) {
        case JsonKind.JsObject =>
            match (draft.asObject().get("cover_images")) {
                case Some(_) => @Assert(false, true)
                case None => @Assert(true, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func bjhRespParseTest(): Unit {
    let (errno, errmsg, articleId) = parseBjhResp("{\"errno\": 0, \"errmsg\": \"\", \"data\": {\"article_id\": \"1701\"}}")
    @Assert(errno, 0)
    @Assert(errmsg, "")
    @Assert(articleId, "1701")
    let (errno2, _, _) = parseBjhResp("{\"errno\": 60001009, \"errmsg\": \"当日剩余发文篇数为0\"}")
    @Assert(errno2, 60001009)
    let (errno3, _, _) = parseBjhResp("<html>login page</html>")
    @Assert(errno3, -1)
}

@Test
func bjhTitleValidTest(): Unit {
    @Assert(bjhTitleValid("八字以上正常中文标题"), true)
    @Assert(bjhTitleValid("短"), false)
    @Assert(bjhTitleValid("abcdefghijklmnopqrstuvwxyz"), true)  // 26 字节 ASCII
}

@Test
func originUrlParseTest(): Unit {
    let a = parseArticle("---\ntitle: 标题\norigin_url: https://blog.example.com/post/1\n---\n正文")
    @Assert(a.originUrl, "https://blog.example.com/post/1")
    let b = parseArticle("---\ntitle: 标题\n---\n正文")
    @Assert(b.originUrl, "")
}

@Test
func zhihuImgExtTest(): Unit {
    @Assert(zhihuImgExt("https://a.com/x/y.png"), "png")
    @Assert(zhihuImgExt("https://a.com/x/y.PNG?size=1"), "PNG")
    @Assert(zhihuImgExt("https://a.com/x/y.jpg#frag"), "jpg")
    @Assert(zhihuImgExt("https://a.com/noext"), "png")
    @Assert(zhihuImgExt("/abs/path/img.webp"), "webp")
}

@Test
func zhihuCanonicalUrlTest(): Unit {
    @Assert(zhihuCanonicalUrl("v2-abc123", "https://pic-private.zhihu.com/v2-abc123~resize:0:q75.png?exp=1"),
        "https://picx.zhimg.com/v2-abc123.png")
    @Assert(zhihuCanonicalUrl("", "https://a.com/x.png"), "")
}

@Test
func zhihuPercentEncodeTest(): Unit {
    @Assert(zhihuPercentEncode("abc-._~123"), "abc-._~123")
    @Assert(zhihuPercentEncode("a b"), "a%20b")
    @Assert(zhihuPercentEncode("x=1&y=2"), "x%3D1%26y%3D2")
    @Assert(zhihuPercentEncode("a/b:c"), "a%2Fb%3Ac")
}

@Test
func rfc1123FromUnixTest(): Unit {
    // 0 = 1970-01-01 00:00:00 GMT，周四
    @Assert(rfc1123FromUnix(0), "Thu, 01 Jan 1970 00:00:00 GMT")
    // 2026-11-04 00:00:00 UTC 的时间戳，查表核对
    @Assert(rfc1123FromUnix(1793775215), "Wed, 04 Nov 2026 06:53:35 GMT")
}

@Test
func imgContentTypeTest(): Unit {
    @Assert(imgContentType([UInt8(0x89), UInt8(0x50), UInt8(0x4E), UInt8(0x47)]), "image/png")
    @Assert(imgContentType([UInt8(0xFF), UInt8(0xD8), UInt8(0xFF)]), "image/jpeg")
    @Assert(imgContentType([UInt8(0x47), UInt8(0x49), UInt8(0x46), UInt8(0x38)]), "image/gif")
    @Assert(imgContentType([UInt8(1), UInt8(2)]), "application/octet-stream")
}

@Test
func md5HexTest(): Unit {
    // MD5("abc") = 900150983cd24fb0d6963f7d28e17f72（RFC 1321 测试向量）
    @Assert(md5Hex("abc".toArray()), "900150983cd24fb0d6963f7d28e17f72")
}

@Test
func xmlEscapeTest(): Unit {
    @Assert(xmlEscape("a&b<c>d"), "a&amp;b&lt;c&gt;d")
    @Assert(xmlEscape("普通文本"), "普通文本")
}

@Test
func iso8601FromUnixTest(): Unit {
    @Assert(iso8601FromUnix(0), "19700101T00:00:00")
    @Assert(iso8601FromUnix(1793775215), "20261104T06:53:35")
}

@Test
func cnblogsNewPostXmlTest(): Unit {
    let xml = buildCnblogsNewPostXml("myblog", "user1", "tok", "标题<T>",
        "<p>正文&内容</p>", ["[Markdown]", "随笔"], "仓颉,测试", true, "20261104T065335")
    // 方法名与五个参数都在
    @Assert(xml.contains("metaWeblog.newPost"), true)
    @Assert(xml.contains("<string>myblog</string>"), true)
    @Assert(xml.contains("<string>user1</string>"), true)
    @Assert(xml.contains("<string>tok</string>"), true)
    @Assert(xml.contains("<dateTime.iso8601>20261104T065335</dateTime.iso8601>"), true)
    @Assert(xml.contains("<boolean>1</boolean>"), true)
    // XML 转义生效
    @Assert(xml.contains("标题&lt;T&gt;"), true)
    @Assert(xml.contains("正文&amp;内容"), true)
    // [Markdown] 分类必须带上（否则博客园不按 MD 渲染）
    @Assert(xml.contains("<string>[Markdown]</string>"), true)
    // 草稿模式 boolean 0
    let draftXml = buildCnblogsNewPostXml("b", "u", "t", "t", "d", ["[Markdown]"], "", false, "20261104T065335")
    @Assert(draftXml.contains("<boolean>0</boolean>"), true)
}

@Test
func cnblogsRespParseTest(): Unit {
    // 成功：postid 字符串
    @Assert(parseCnblogsPostId("<?xml?><methodResponse><params><param><value><string>19858898</string></value></param></params></methodResponse>"), "19858898")
    // fault：postid 为空，faultString 带出
    @Assert(parseCnblogsPostId("<?xml?><methodResponse><fault><value><struct><member><name>faultCode</name><value><int>403</int></value></member><member><name>faultString</name><value><string>您的博客已禁用 MetaWeblogApi</string></value></member></struct></value></fault></methodResponse>"), "")
    @Assert(parseCnblogsFault("<?xml?><methodResponse><fault><value><struct><member><name>faultCode</name><value><int>403</int></value></member><member><name>faultString</name><value><string>您的博客已禁用 MetaWeblogApi</string></value></member></struct></value></fault></methodResponse>"),
        "您的博客已禁用 MetaWeblogApi")
    // 非 XML
    @Assert(parseCnblogsPostId("<html>blocked</html>"), "")
}

@Test
func juejinDraftBodyTest(): Unit {
    let s = buildJuejinDraftBody("标题", "# 正文", "摘要内容五十个字以上满足掘金硬性长度要求才行呀不够就补齐吧", "6809637769959178254", ["6809640445233070098"], "")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            match (obj.get("edit_type")) {
                case Some(x) => @Assert(x.asInt().getValue(), 10)
                case None => @Assert(false, true)
            }
            match (obj.get("category_id")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => @Assert(x.asString().getValue(), "6809637769959178254")
                        case _ => @Assert(false, true)  // 必须是字符串不是数字
                    }
                case None => @Assert(false, true)
            }
            match (obj.get("html_content")) {
                case Some(x) => @Assert(x.asString().getValue(), "deprecated")
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
    // categoryId 为空则省略字段
    let noCat = JsonValue.fromStr(buildJuejinDraftBody("t", "m", "brief", "", [], ""))
    match (noCat.kind()) {
        case JsonKind.JsObject =>
            match (noCat.asObject().get("category_id")) {
                case Some(_) => @Assert(false, true)
                case None => @Assert(true, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func juejinPublishBodyTest(): Unit {
    let s = buildJuejinPublishBody("7301234567890")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get("draft_id")) {
                case Some(x) => @Assert(x.asString().getValue(), "7301234567890")
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func juejinBriefTest(): Unit {
    // desc 足够长：原样
    let long = "这是一段超过五十个字符的摘要文本，用来验证掘金的摘要长度硬性要求不会触发补齐逻辑，内容保持原样不重复。"
    @Assert(normalizeJuejinBrief(long, ""), long)
    // desc 空：从正文剥 Markdown 取
    let fromBody = normalizeJuejinBrief("", "## 标题\n\n这是一段足够长的正文文字，用来生成摘要，需要超过五十个字符才能满足掘金的硬性要求，因此这里多写一些内容填充。")
    @Assert(utf8CharCount(fromBody) >= 50, true)
    // 短摘要：补齐到 50 字以上
    let short = normalizeJuejinBrief("太短了", "正文内容用来补齐摘要长度，这部分文字应当被重复填充进摘要里直到满足五十个字符的最低要求为止。")
    @Assert(utf8CharCount(short) >= 50, true)
}

@Test
func juejinRespParseTest(): Unit {
    let (e1, _, id1) = parseJuejinResp("{\"err_no\": 0, \"err_msg\": \"success\", \"data\": {\"id\": \"7301\"}}", "id")
    @Assert(e1, 0)
    @Assert(id1, "7301")
    let (e2, _, aid2) = parseJuejinResp("{\"err_no\": 0, \"err_msg\": \"success\", \"data\": {\"article_id\": \"730000123\"}}", "article_id")
    @Assert(e2, 0)
    @Assert(aid2, "730000123")
    let (e3, m3, _) = parseJuejinResp("{\"err_no\": 2, \"err_msg\": \"参数错误\"}", "id")
    @Assert(e3, 2)
    @Assert(m3, "参数错误")
    let (e4, _, _) = parseJuejinResp("<html>login</html>", "id")
    @Assert(e4, -1)
}
