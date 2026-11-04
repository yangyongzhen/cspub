/** front-matter 解析：--- 包头的 key: value 块 + 正文 */
package cspub

import std.collection.*

/** 一篇文章：front-matter 字段 + 正文（全部 var，解析时就地置位） */
public class Article {
    public var title: String
    public var tags: String
    public var categories: String
    public var desc: String
    public var draft: Bool
    public var originUrl: String
    public var body: String
    public init() {
        title = ""
        tags = ""
        categories = ""
        desc = ""
        draft = true
        originUrl = ""
        body = ""
    }
}

/** 解析文章文本：`---` 包头的 front-matter（可缺省）+ 其余为 Markdown 正文。
 * draft 缺省 true——宁可草稿也不误发布，这是发文工具的安全缺省。 */
public func parseArticle(text: String): Article {
    let a = Article()
    let lines = text.split("\n", -1)
    var idx: Int64 = 0
    // 跳过 UTF-8 BOM（EF BB BF）
    if (lines.size > 0 && trimAscii(lines[0]).size > 0) {
        let first = lines[0].toArray()
        if (first.size >= 3 && first[0] == UInt8(0xEF) && first[1] == UInt8(0xBB) && first[2] == UInt8(0xBF)) {
            // BOM 在首行行首：把首行重切成去掉 BOM 的部分再判
            let rest = String.fromUtf8(first[3..first.size])
            if (trimAscii(rest) == "---") {
                idx = 1
                idx = parseFmBlock(a, lines, idx)
                return a
            }
        }
    }
    if (lines.size > 0 && trimAscii(lines[0]) == "---") {
        idx = parseFmBlock(a, lines, 1)
    }
    // 正文：从 idx 行起原样拼接（保留缩进与空行）
    var body = StringBuilder()
    while (idx < lines.size) {
        body.append(lines[idx])
        body.append("\n")
        idx++
    }
    a.body = body.toString()
    return a
}

/** 解析 front-matter 块（从 startIdx 起，遇到闭合 `---` 或文件尾止）；返回停止行号 */
func parseFmBlock(a: Article, lines: Array<String>, startIdx: Int64): Int64 {
    var i = startIdx
    while (i < lines.size) {
        let t = trimAscii(lines[i])
        if (t == "---") {
            return i + 1
        }
        if (t.size > 0) {
            applyFmLine(a, t)
        }
        i++
    }
    return i
}

/** 一行 key: value（值可带引号）；认不出的键忽略（不报错——front-matter 允许多余字段） */
func applyFmLine(a: Article, line: String): Unit {
    let arr = line.toArray()
    var ci: Int64 = -1
    for (k in 0..arr.size) {
        if (arr[k] == UInt8(58)) {  // ':'
            ci = k
            break
        }
    }
    if (ci <= 0) {
        return
    }
    let key = trimAscii(String.fromUtf8(arr[0..ci]))
    let value = unquote(trimAscii(String.fromUtf8(arr[(ci + 1)..arr.size])))
    if (key == "title") {
        a.title = value
    } else if (key == "tags") {
        a.tags = normalizeTags(value)
    } else if (key == "categories" || key == "category") {
        a.categories = value
    } else if (key == "desc" || key == "description" || key == "summary") {
        a.desc = value
    } else if (key == "draft") {
        a.draft = !(value == "false" || value == "no" || value == "0")
    } else if (key == "origin_url" || key == "originUrl") {
        a.originUrl = value
    }
}

/** 去值两端成对引号 */
func unquote(v: String): String {
    if (v.size >= 2 && v.startsWith("\"") && v.endsWith("\"")) {
        return v[1..(v.size - 1)]
    }
    return v
}

/** tags 归一：逗号/顿号分隔都收，转成 CSDN 要的逗号串；最多 5 个（API 上限） */
func normalizeTags(v: String): String {
    var parts = ArrayList<String>()
    for (p in v.split("，", -1)) {
        for (q in p.split(",", -1)) {
            let t = trimAscii(q)
            if (t.size > 0) {
                parts.add(t)
            }
        }
    }
    var out = StringBuilder()
    var n: Int64 = 0
    for (p in parts) {
        if (n >= 5) {
            break
        }
        if (n > 0) {
            out.append(",")
        }
        out.append(p)
        n++
    }
    return out.toString()
}
