/** util 工具函数单测：HTML 实体反转义。
 *
 * 复现的真实故障（2026-11-08 头条实战）：mdToHtml 渲染后，图片 URL 里的 `&`
 * 变成 `&amp;`，rehostToutiaoImages 拿 HTML 原文的 src 去下载 → 5 张头条 CDN 签名链
 * （形如 `...~tplv-obj.image?lk3s=xxx&policy=yyy&x-orig-sign=zzz`）全部「读不到图片」，
 * 被误报成「头条会拒稿 7115」，实际链接是好的。
 */
package cspub

import std.unittest.*

@Test
func htmlUnescapeAmpTest(): Unit {
    // 头条 CDN 签名链的典型形状：三个 & 分隔的查询参数
    let raw = "https://image-tt-private.toutiao.com/x~tplv-obj.image?lk3s=1&amp;policy=2&amp;sign=3"
    let fixed = htmlUnescape(raw)
    @Assert(fixed, "https://image-tt-private.toutiao.com/x~tplv-obj.image?lk3s=1&policy=2&sign=3")
    // 只反转义一层：&amp;amp; 应得 &amp;，不能一路剥到 &
    @Assert(htmlUnescape("&amp;amp;"), "&amp;")
}

@Test
func htmlUnescapeNamedEntitiesTest(): Unit {
    @Assert(htmlUnescape("&lt;p&gt;"), "<p>")
    @Assert(htmlUnescape("&quot;x&quot;"), "\"x\"")
    @Assert(htmlUnescape("&#39;a&#39;"), "'a'")
    @Assert(htmlUnescape("&apos;b&apos;"), "'b'")
}

@Test
func htmlUnescapeKeepsUtf8Test(): Unit {
    // 汉字必须整体保留：逐字节 append 会把 3 字节的汉字拆成非法序列（AGENTS §4）
    let fixed = htmlUnescape("图&amp;片：架构")
    @Assert(fixed, "图&片：架构")
    @Assert(fixed.size, "图&片：架构".size)
}

@Test
func htmlUnescapeNoopTest(): Unit {
    // 没有 & 时原样返回（快速路径）
    @Assert(htmlUnescape("https://a.example/b.png"), "https://a.example/b.png")
    @Assert(htmlUnescape(""), "")
    // 未知实体不动它，避免把 &nbsp; 之类误伤成 nbsp;
    @Assert(htmlUnescape("a&nbsp;b"), "a&nbsp;b")
    // 落单的 & 也不动
    @Assert(htmlUnescape("a&b"), "a&b")
}
