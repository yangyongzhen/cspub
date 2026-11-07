/** 腾讯云开发者社区单元测试：RPC 地址、uin 提取、content 编码、Draft.js 块转换、响应解析。
 *
 * 重点覆盖实测出来的反直觉点（见 docs/多平台发文调研.md §十一）：
 * ① 真正的发文接口是 `/developer/services/ajax/column/article?action=X`（namespace 带 `developer/`
 *    前缀），老的 `/developer/api/article/addArticle` 在前端 bundle 里出现 0 次，已废弃；
 * ② `content` = base64(urlencode(JSON.stringify(jsonpack.pack(rawDraft))))——三层，错一层就 400；
 * ③ 响应 code 是 **JSON 数字**，必须按 Kind 取（只认字符串的 jsonStr 会得空串）；
 * ④ 140 字下限只卡发布，草稿实测 6 字符也能成功，别在草稿阶段拦；
 * ⑤ 参数校验先于登录校验：400 不代表 Cookie 失效。
 *
 * 其中 contentEncMatchesCaptureTest 用的是**线上真包原文**：packed 串、base64 串都是抓包得到的常量，
 * 这比"能存进去就算过"强得多——只要一个字节不同就会失败。
 */
package cspub

import std.unittest.*
import stdx.encoding.json.*

@Test
func tencentRpcUrlTest(): Unit {
    @Assert(tencentRpcUrl("CreateArticleDraft", "100009199133"),
        "https://cloud.tencent.com/developer/services/ajax/column/article?action=CreateArticleDraft&uin=100009199133")
    // uin 缺失时不能拼出 uin= 空值（会被服务端当无效账号）
    @Assert(tencentRpcUrl("CreateArticleDraft", ""),
        "https://cloud.tencent.com/developer/services/ajax/column/article?action=CreateArticleDraft")
}

@Test
func tencentUinTest(): Unit {
    // 真 Cookie 里是 uin=o100009199133，前导 o 必须去掉
    @Assert(tencentUin("uin=o100009199133; skey=abc"), "100009199133")
    @Assert(tencentUin("uin=100009199133"), "100009199133")
    // 兜底走 ownerUin（可能带 o 前缀与 G 后缀）
    @Assert(tencentUin("ownerUin=o123G; skey=abc"), "123")
    @Assert(tencentUin("skey=abc"), "")
}

@Test
func tencentContentEncMatchesCaptureTest(): Unit {
    // 线上真包：单 block（key=421q5, text=aaaaaa）的 content 原文，解码后即
    //   "blocks|key|421q5|text|aaaaaa|...|$]]"
    // 这里做的是 pack -> JSON.stringify -> urlencode -> base64 的整条链路比对
    let captured = "JTIyYmxvY2tzJTdDa2V5JTdDNDIxcTUlN0N0ZXh0JTdDYWFhYWFhJTdDdHlwZSU3Q3Vuc3R5bGVk" +
        "JTdDZGVwdGglN0NpbmxpbmVTdHlsZVJhbmdlcyU3Q2VudGl0eVJhbmdlcyU3Q2RhdGElN0NlbnRpdHlNYXAl" +
        "NUUwJTVFJTVFJTI0MCU3QyU0MCUyNDElN0MyJTdDMyU3QzQlN0M1JTdDNiU3QzclN0NDJTdDOCU3QyU0MCU1" +
        "RCU3QzklN0MlNDAlNUQlN0NBJTdDJTI0JTVEJTVEJTVEJTdDQiU3QyUyNCU1RCU1RCUyMg=="
    let packed = jsonpackPack(testRaw([testBlock("421q5", "aaaaaa")]))
    @Assert(tencentEncodeField(packed), captured)
}

@Test
func tencentPlainEncMatchesCaptureTest(): Unit {
    // 真包 plain = base64(urlencode("\"aaaaaa\"")) = JTIyYWFhYWFhJTIy
    @Assert(tencentEncodeField("aaaaaa"), "JTIyYWFhYWFhJTIy")
}

@Test
func tencentUrlEncodeTest(): Unit {
    // encodeURIComponent 语义：字母数字与 -_.!~*'() 保留，竖线/空格/汉字全部编码
    @Assert(urlEncodeComponent("a b"), "a%20b")
    @Assert(urlEncodeComponent("a|b"), "a%7Cb")
    @Assert(urlEncodeComponent("A-Z_0.9!(~*)'"), "A-Z_0.9!(~*)'")
    @Assert(urlEncodeComponent("中"), "%E4%B8%AD")
    // 双引号必须编码，否则 JSON.stringify 的引号会被 URL 层吃掉
    @Assert(urlEncodeComponent("\"x\""), "%22x%22")
}

@Test
func tencentDraftPayloadAllFieldsTest(): Unit {
    let ids: Array<Int64> = [149, 150]
    let s = buildTencentDraftPayload("标题", "Y29udGVudA==", "cGxhaW4=", ids,
        Array<Int64>(0, repeat: 0), Array<String>(0, repeat: ""))
    let v = JsonValue.fromStr(s)
    let keys: Array<String> = [
        "articleId", "title", "content", "plain", "columnIds", "tagIds", "keywords",
        "sourceType", "openComment", "focusReadTotalAfterFollowAuthor", "closeTextLink",
        "classifyIds"
    ]
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            // 真包字段一个不多一个不少，逐个点名
            for (k in keys) {
                @Assert(obj.get(k).isSome(), true)
            }
            // articleId 新建草稿固定 0
            match (obj.get("articleId")) {
                case Some(a) =>
                    match (a.kind()) {
                        case JsonKind.JsInt => @Assert(a.asInt().getValue(), 0)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func tencentRpcBodyShapeTest(): Unit {
    let s = buildTencentRpcBody("CreateArticleDraft", "{\"title\":\"t\"}")
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            // action 在顶层，payload 是**嵌套对象**（不是字符串），这是网关约定的形状
            @Assert(jsonScalar(v, "action"), "CreateArticleDraft")
            match (jsonObjField(v, "payload")) {
                case Some(p) =>
                    match (p.kind()) {
                        case JsonKind.JsObject => @Assert(jsonScalar(p, "title"), "t")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func tencentRpcRespParseTest(): Unit {
    // 成功：code 是数字 0，draftId 在 data 里
    let (c1, m1, d1, _) = parseTencentRpcResp(
        "{\"code\":0,\"msg\":\"ok\",\"data\":{\"articleId\":0,\"draftId\":341899}}")
    @Assert(c1, 0)
    @Assert(m1, "ok")
    @Assert(d1, "341899")

    // content 编码错时的真实回包——必须能和登录失败区分开
    let (c2, m2, d2, _) = parseTencentRpcResp(
        "{\"code\":400,\"msg\":\"文章草稿创建失败，请稍后重试 [400]\"}")
    @Assert(c2, 400)
    @Assert(m2, "文章草稿创建失败，请稍后重试 [400]")
    @Assert(d2, "")

    // 未登录
    let (c3, _, d3, _) = parseTencentRpcResp("{\"code\":401,\"msg\":\"你还未登录，请先登录\"}")
    @Assert(c3, 401)
    @Assert(d3, "")

    // 非 JSON / 空体不崩
    let (c4, _, d4, _) = parseTencentRpcResp("<html>501 Not Implemented</html>")
    @Assert(c4, 0)
    @Assert(d4, "")
    let (c5, _, d5, _) = parseTencentRpcResp("")
    @Assert(c5, 0)
    @Assert(d5, "")
}

@Test
func tencentDraftBlockTypesTest(): Unit {
    let md = "# 大标题\n## 二级\n- 列表项\n正文一行\n```\ncode line\n```"
    let (root, plain) = mdToDraftRoot(md)
    let packed = jsonpackPack(root)
    // 标题/列表/代码块都要落到 Draft.js 的 type 名上，否则编辑器里样式全丢
    @Assert(packed.contains("header-one"), true)
    @Assert(packed.contains("header-two"), true)
    @Assert(packed.contains("unordered-list-item"), true)
    @Assert(packed.contains("code-block"), true)
    // 代码围栏本身不是正文
    @Assert(packed.contains("```"), false)
    @Assert(plain.contains("# "), false)
}

@Test
func tencentImageEntityTest(): Unit {
    let (root, _) = mdToDraftRoot("前文\n![alt](https://cdn.example.com/a.png)\n后文")
    let packed = jsonpackPack(root)
    // 图片独占一行 -> atomic block + IMAGE entity
    @Assert(packed.contains("atomic"), true)
    @Assert(packed.contains("IMAGE"), true)
    @Assert(packed.contains("IMMUTABLE"), true)
    @Assert(packed.contains("https://cdn.example.com/a.png"), true)
    // imageUrl 才是腾讯云前端读的字段名：缺它时发布会被服务端 `.startsWith` 崩成 500，
    // 而草稿阶段完全看不出来——这条断言就是为了守住这个只在发布时暴露的坑
    @Assert(packed.contains("imageUrl"), true)
}

@Test
func tencentClassifyCfgTest(): Unit {
    let a = parseTencentClassifyIds("149,150")
    @Assert(a.size, 2)
    @Assert(a[0], 149)
    @Assert(a[1], 150)

    // 空配置回落默认专栏：空数组提交必失败
    let b = parseTencentClassifyIds("")
    @Assert(b.size, 1)
    @Assert(b[0], TENCENT_DEFAULT_CLASSIFY)

    // 全非法同样回落默认
    let c = parseTencentClassifyIds("abc,-3")
    @Assert(c.size, 1)
    @Assert(c[0], TENCENT_DEFAULT_CLASSIFY)

    // 混合：非法项丢弃，合法项保留
    let d = parseTencentClassifyIds("0,abc,200")
    @Assert(d.size, 1)
    @Assert(d[0], 200)
}

@Test
func tencentCookieSessionTest(): Unit {
    @Assert(tencentCookieHasSession("skey=abc; qcloud_uid=1"), true)
    @Assert(tencentCookieHasSession("qcommunity_session=xyz"), true)
    // 只有身份字段（qcloud_uid / tinyid）不算登录态
    @Assert(tencentCookieHasSession("qcloud_uid=1; tinyid=2"), false)
    @Assert(tencentCookieHasSession(""), false)
}

@Test
func tencentCharCountTest(): Unit {
    // 140 字下限按字符算：一个汉字算 1，按字节算会变成 3 而误判成「够长」
    @Assert(utf8CharCount("中文"), 2)
    @Assert(utf8CharCount("abc"), 3)
    @Assert(utf8CharCount("a中b"), 3)
    @Assert(utf8CharCount(""), 0)
}

@Test
func tencentUrlHistoryTest(): Unit {
    @Assert(tencentArticleUrl("2650368"),
        "https://cloud.tencent.com/developer/article/2650368")
    @Assert(tencentDraftUrl("341899").contains("draftId=341899"), true)
}

@Test
func tencentImageRpcUrlTest(): Unit {
    // 图片 RPC 的 namespace 是 image（发文是 column/article），两者混用会回 501
    let u = tencentImageRpcUrl("SaveHttpImageCommon", "100009199133")
    @Assert(u.contains("/developer/services/ajax/image?"), true)
    @Assert(u.contains("action=SaveHttpImageCommon"), true)
    @Assert(u.contains("uin=100009199133"), true)
    @Assert(u.contains("column/article"), false)
}

@Test
func tencentDataUrlTest(): Unit {
    // 线上真实响应（转存成功）：data.url 才是图链
    let real = "{\"code\":0,\"msg\":\"ok\",\"data\":{\"url\":\"https://developer.qcloudimg.com/operation/attachment/4616350/20261106-3d62adf5.png\"}}"
    @Assert(tencentDataUrl(real),
        "https://developer.qcloudimg.com/operation/attachment/4616350/20261106-3d62adf5.png")
    // 缺 data / data 不是对象 / 坏 JSON 一律空串——不能把 "null" 之类当成可用链接
    @Assert(tencentDataUrl("{\"code\":0,\"msg\":\"ok\"}"), "")
    @Assert(tencentDataUrl("{\"code\":0,\"data\":\"x\"}"), "")
    @Assert(tencentDataUrl("not json"), "")
    @Assert(tencentDataUrl(""), "")
}

@Test
func tencentPublishPayloadFieldsTest(): Unit {
    let p = buildTencentPublishPayload("标题", "ENC_C", "ENC_P", "341905", 149,
        Array<String>(0, repeat: ""), [10757, 17183])
    let v = JsonValue.fromStr(p)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            // 字段组照抄前端 bundle 的真实调用（d.call("CreateArticle", m)）
            // 唯一例外是 sourceDetail：原创传空串会被判 400「参数错误」（逐字段实验证实）
            let must: Array<String> = ["columnId", "columnIds", "draftId", "title", "content",
                "plain", "sourceType", "tagIds", "picture", "keywords"]
            for (k in must) {
                @Assert(obj.get(k).isSome(), true)
            }
            // 发布 payload 里不该出现这两个（classifyIds 只有草稿要，articleId 是更新才要）
            @Assert(obj.get("classifyIds").isNone(), true)
            @Assert(obj.get("articleId").isNone(), true)
            // sourceDetail 只要出现就回 400——这条断言守的就是那个坑
            @Assert(obj.get("sourceDetail").isNone(), true)
            @Assert(obj.size(), 10)
            // tagIds 必须带真实标签：空数组服务端回 -9993「请选择文章标签」
            match (obj.get("tagIds")) {
                case Some(t) =>
                    match (t.kind()) {
                        case JsonKind.JsArray => @Assert(t.asArray().size(), 2)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // 来源类型必须是 1（原创）：0 建草稿能过，但发布会被判 -9996「文章来源类型错误」
            match (obj.get("sourceType")) {
                case Some(s) =>
                    match (s.kind()) {
                        case JsonKind.JsInt => @Assert(s.asInt().getValue(), 1)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // draftId 必须是数字：草稿转发布靠它，发成字符串服务端认不出
            match (obj.get("draftId")) {
                case Some(d) =>
                    match (d.kind()) {
                        case JsonKind.JsInt => @Assert(d.asInt().getValue(), 341905)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            match (obj.get("columnId")) {
                case Some(c) =>
                    match (c.kind()) {
                        case JsonKind.JsInt => @Assert(c.asInt().getValue(), 149)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func tencentColumnRpcUrlTest(): Unit {
    // 专栏/标签的 namespace 是 column/column，挂到 column/article 下回 501
    @Assert(tencentColumnRpcUrl("FetchJoinedColumnList", "100009199133"),
        "https://cloud.tencent.com/developer/services/ajax/column/column?action=FetchJoinedColumnList&uin=100009199133")
    // uin 缺失时不能拼出 uin= 空值
    @Assert(tencentColumnRpcUrl("FetchJoinedColumnList", ""),
        "https://cloud.tencent.com/developer/services/ajax/column/column?action=FetchJoinedColumnList")
    // FetchColumnTags 也走同一个 namespace
    @Assert(tencentColumnRpcUrl("FetchColumnTags", "1").contains("column/column?action=FetchColumnTags"), true)
}

@Test
func tencentRespCodeTest(): Unit {
    // code 是 JSON **数字**：按 Kind 取才拿得到 "0"（只认字符串的 jsonStr 得空串）
    @Assert(tencentRespCode("{\"code\":0,\"data\":{}}"), "0")
    @Assert(tencentRespCode("{\"code\":300031}"), "300031")
    @Assert(tencentRespCode("{\"code\":-9993}"), "-9993")
    // 非对象或不可解析 → 空串（调用方按失败处理）
    @Assert(tencentRespCode("[1,2]"), "")
    @Assert(tencentRespCode("not json"), "")
}

@Test
func tencentColumnParseTest(): Unit {
    // data 直接是数组
    let flat = "{\"code\":0,\"data\":[{\"columnId\":88542,\"columnName\":\"开源技术\"},{\"columnId\":149,\"columnName\":\"技术\"}]}"
    let cols = parseTencentColumns(flat)
    @Assert(cols.size, 2)
    @Assert(cols[0][0], "88542")
    @Assert(cols[0][1], "开源技术")
    // data 包一层 list，字段名换成 id/name 也要认
    let nested = "{\"code\":0,\"data\":{\"list\":[{\"id\":88542,\"name\":\"备份专栏\"}]}}"
    let cols2 = parseTencentColumns(nested)
    @Assert(cols2.size, 1)
    @Assert(cols2[0][0], "88542")
    @Assert(cols2[0][1], "备份专栏")
    // 缺 id 的条目直接跳过，不产出空 id 的假专栏
    @Assert(parseTencentColumns("{\"code\":0,\"data\":[{\"columnName\":\"没有 id\"}]}").size, 0)
    // 空/坏响应不抛异常
    @Assert(parseTencentColumns("").size, 0)
}

@Test
func tencentTagParseTest(): Unit {
    let t = "{\"code\":0,\"data\":[{\"tagId\":10663,\"tagName\":\"编程算法\"},{\"tagId\":10308,\"tagName\":\"linux\"}]}"
    let tags = parseTencentTags(t)
    @Assert(tags.size, 2)
    @Assert(tags[0][0], "10663")
    @Assert(tags[0][1], "编程算法")
    @Assert(tags[1][1], "linux")
    // tagId 缺失跳过
    @Assert(parseTencentTags("{\"code\":0,\"data\":[{\"tagName\":\"无 id\"}]}").size, 0)
    // 条目数组提取：数组与容器两种形状都要能取到
    @Assert(tencentItemArray("{\"data\":[1,2,3]}").size, 3)
    @Assert(tencentItemArray("{\"data\":{\"tags\":[1]}}").size, 1)
    @Assert(tencentItemArray("[]").size, 0)
}
