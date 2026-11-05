/** 语雀单元测试：请求体构造、响应/错误解析、namespace 与公开性校验。
 *
 * 重点覆盖两条官方规格里容易踩的（见 docs/多平台发文调研.md 与 spec/yuque-openapi.yaml）：
 * ① `body` 是唯一必填字段，`format` 必须显式 markdown（否则会被按 HTML 解析）；
 * ② namespace 必须两段式，单段名会 404 —— 本地先拦，别拿必然失败的请求怀疑 Token。
 */
package cspub

import stdx.encoding.json.*
import std.unittest.*

@Test
func yuqueBodyRequiredFieldsTest(): Unit {
    let s = buildYuqueDocBody("标题", "# 正文", "", -1)
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            @Assert(obj.get("title").isSome(), true)
            @Assert(obj.get("body").isSome(), true)
            // format 必须显式 markdown：原样提交 Markdown，不让语雀按 HTML 解析
            match (obj.get("format")) {
                case Some(f) =>
                    match (f.kind()) {
                        case JsonKind.JsString => @Assert(f.asString().getValue(), "markdown")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            // slug 为空时不传（交给语雀按标题生成）
            @Assert(obj.get("slug").isNone(), true)
            // publicLevel = -1 表示不传，继承知识库公开性
            @Assert(obj.get("public").isNone(), true)
        case _ => @Assert(false, true)
    }
}

@Test
func yuqueBodyOptionalFieldsTest(): Unit {
    // 显式 slug + 私密
    let s = buildYuqueDocBody("标题", "正文", "my-doc", 0)
    let v = JsonValue.fromStr(s)
    match (v.kind()) {
        case JsonKind.JsObject =>
            let obj = v.asObject()
            match (obj.get("slug")) {
                case Some(x) =>
                    match (x.kind()) {
                        case JsonKind.JsString => @Assert(x.asString().getValue(), "my-doc")
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
            match (obj.get("public")) {
                case Some(p) =>
                    match (p.kind()) {
                        // public 是整数枚举 0/1/2，不是 bool 也不是字符串
                        case JsonKind.JsInt => @Assert(p.asInt().getValue(), 0)
                        case _ => @Assert(false, true)
                    }
                case None => @Assert(false, true)
            }
        case _ => @Assert(false, true)
    }
}

@Test
func yuqueDocRespParseTest(): Unit {
    let (id, slug, title) = parseYuqueDocResp(
        "{\"data\":{\"id\":123456,\"slug\":\"abc-def\",\"title\":\"我的文章\"}}")
    @Assert(id, "123456")
    @Assert(slug, "abc-def")
    @Assert(title, "我的文章")

    // 没有 data（异常体）：全部空，不崩
    let (id2, slug2, _) = parseYuqueDocResp("{\"status\":400,\"error\":\"bad request\"}")
    @Assert(id2, "")
    @Assert(slug2, "")

    // 非 JSON
    let (id3, _, _) = parseYuqueDocResp("<html>502</html>")
    @Assert(id3, "")
}

@Test
func yuqueErrorParseTest(): Unit {
    let (s1, m1) = parseYuqueError("{\"status\":401,\"error\":\"Unauthorized\"}")
    @Assert(s1, 401)
    @Assert(m1, "Unauthorized")

    // message 形态也要能取到
    let (_, m2) = parseYuqueError("{\"message\":\"参数校验失败\"}")
    @Assert(m2, "参数校验失败")

    // 空体 / 非 JSON 不崩
    let (s3, m3) = parseYuqueError("")
    @Assert(s3, 0)
    @Assert(m3, "")
}

@Test
func yuqueNamespaceValidTest(): Unit {
    @Assert(yuqueNamespaceValid("yangyongzhen/cspub"), true)
    @Assert(yuqueNamespaceValid("myteam/dev-docs"), true)
    // 单段名会 404，不是权限问题
    @Assert(yuqueNamespaceValid("cspub"), false)
    @Assert(yuqueNamespaceValid("a/b/c"), false)
    @Assert(yuqueNamespaceValid(""), false)
    @Assert(yuqueNamespaceValid("/book"), false)
    @Assert(yuqueNamespaceValid("user/"), false)
}

@Test
func yuquePublicParseTest(): Unit {
    // 空 → 不传（-1）
    @Assert(parseYuquePublic(""), -1)
    @Assert(parseYuquePublic("0"), 0)
    @Assert(parseYuquePublic("1"), 1)
    @Assert(parseYuquePublic("2"), 2)
    // 越界或非法一律回落到「不传」，不把脏值发给接口
    @Assert(parseYuquePublic("5"), -1)
    @Assert(parseYuquePublic("abc"), -1)
}

@Test
func yuqueDocUrlTest(): Unit {
    @Assert(yuqueDocUrl("yangyongzhen/cspub", "abc"),
        "https://www.yuque.com/yangyongzhen/cspub/abc")
}
