/** 腾讯云开发者社区单元测试：请求体构造、响应解析、专栏 id 与登录态判定。
 *
 * 重点覆盖实测出来的两个反直觉点（见 docs/多平台发文调研.md §二）：
 * ① 成功响应 {"articleId":N,"status":0} **没有 code 字段**——成功判据不能写成 code == 0；
 * ② 该接口先校验参数再校验登录，400「参数错误」≠ 401「未登录」，错误映射必须分开。
 */
package cspub

import stdx.encoding.json.*
import std.unittest.*

@Test
func tencentBodyAllFieldsTest(): Unit {
    let ids: Array<Int64> = [149, 150]
    let s = buildTencentArticleBody("标题", "<p>正文</p>", "正文", "摘要", ids, true)
    let v = JsonValue.fromStr(s)
    let keys: Array<String> = [
        "title", "content", "plain", "summary", "userSummary", "sourceType",
        "isOriginal", "classifyIds", "openComment", "closeTextLink"
    ]
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            // 少一个字段就变 400「参数错误」，所以逐个点名检查，而不是只看能序列化
            for (k in keys) {
                @Assert(obj.get(k).isSome(), true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func tencentClassifyIdsShapeTest(): Unit {
    let ids: Array<Int64> = [149, 150]
    let s = buildTencentArticleBody("t", "<p>x</p>", "x", "s", ids, false)
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            match (v.asObject().get("classifyIds")) {
                case Some(a) =>
                    match (a.kind()) {
                        case JsonKind.JsArray =>
                            let arr = a.asArray()
                            // 必须是数组（标量或字符串都会被判参数错误）
                            @Assert(arr.size(), 2)
                            if (let Some(first) <- arr.get(0)) {
                                match (first.kind()) {
                                    case JsonKind.JsInt => @Assert(first.asInt().getValue(), 149)
                                    case _ => @Assert(false, true)
                                }
                            } else {
                                @Assert(false, true)
                            }
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // 转载（isOriginal=false）也要如实落地
            match (v.asObject().get("isOriginal")) {
                case Some(b) =>
                    match (b.kind()) {
                        case JsonKind.JsBool => @Assert(b.asBool().getValue(), false)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func tencentRespParseTest(): Unit {
    // 成功体没有 code，靠 articleId 判成功
    let (c1, m1, id1) = parseTencentResp("{\"articleId\":2650368,\"status\":0}")
    @Assert(c1, 0)
    @Assert(m1, "")
    @Assert(id1, "2650368")

    // 未登录
    let (c2, m2, id2) = parseTencentResp("{\"msg\":\"你还未登录，请先登录\",\"code\":401}")
    @Assert(c2, 401)
    @Assert(m2, "你还未登录，请先登录")
    @Assert(id2, "")

    // 参数错误：必须能和 401 区分开（否则会去修 Cookie，白排查）
    let (c3, m3, _) = parseTencentResp("{\"msg\":\"参数错误\",\"code\":400}")
    @Assert(c3, 400)
    @Assert(m3, "参数错误")

    // 非 JSON / 空体不崩
    let (c4, _, id4) = parseTencentResp("<html>502 Bad Gateway</html>")
    @Assert(c4, 0)
    @Assert(id4, "")
    let (c5, _, id5) = parseTencentResp("")
    @Assert(c5, 0)
    @Assert(id5, "")
}

@Test
func tencentClassifyCfgTest(): Unit {
    let a = parseTencentClassifyIds("149,150")
    @Assert(a.size, 2)
    @Assert(a[0], 149)
    @Assert(a[1], 150)

    // 空配置回落默认专栏：空数组提交必 400
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
func tencentUrlTest(): Unit {
    @Assert(tencentArticleUrl("2650368"),
        "https://cloud.tencent.com/developer/article/2650368")
}
