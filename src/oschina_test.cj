/** 开源中国单测：删除请求体形态 + apiv1 统一响应解析。
 *
 * 真实坑（2026-11-08 实战）：/blog/delete 只认表单参数，
 * 发 JSON 体 {"id":…} 会被服务端静默忽略并回「博客不存在」（code 500）——
 * 与「id 写错」同一个码，极容易误判成鉴权或参数问题。
 */
package cspub

import std.unittest.*

@Test
func oschinaDeleteFormTest(): Unit {
    @Assert(buildOschinaDeleteForm("19788502"), "id=19788502")
    // 前后空白必须去掉，否则 body 是 id= 19788502，服务端解析成空 id
    @Assert(buildOschinaDeleteForm("  19788502\n"), "id=19788502")
    @Assert(buildOschinaDeleteForm(""), "id=")
}

@Test
func oschinaDeleteRespOkTest(): Unit {
    // 删除成功的真实响应形状（result 为 null）
    let body = "{\"success\":true,\"error\":false,\"message\":\"成功\",\"code\":200,\"result\":null}"
    let (code, msg, id) = parseOschinaResp(body)
    @Assert(code, 200)
    @Assert(msg, "成功")
    @Assert(id, "")
}

@Test
func oschinaDeleteRespMissingTest(): Unit {
    // 文章不存在 / id 写错 / 已经删过，服务端一律回 code 500 +「博客不存在」
    let body = "{\"success\":false,\"error\":false,\"message\":\"博客不存在\",\"code\":500,\"result\":null}"
    let (code, msg, _) = parseOschinaResp(body)
    @Assert(code, 500)
    @Assert(msg.contains("不存在"), true)
}

@Test
func oschinaDeleteRespBrokenJsonTest(): Unit {
    // 非 JSON（WAF 拦截回的 HTML）不能抛异常炸掉：回 code -1 交给调用方判失败
    let (code, msg, id) = parseOschinaResp("<html><center>403 Forbidden</center></html>")
    @Assert(code, -1)
    @Assert(msg, "")
    @Assert(id, "")
}
