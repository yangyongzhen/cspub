/** 极简 Markdown → HTML：CSDN 编辑器要求 content 字段是**渲染后的 HTML**（发 markdown 原文会显示字面 ## 与 ![]()） */
package cspub

/** 渲染状态机：方法读自有字段，避开「闭包捕获可变局部变量」的编译限制（AGENTS §4） */
class MdRenderer {
    var out: StringBuilder
    var listMode: String  // "" | "ul" | "ol"
    var para: StringBuilder
    var hasPara: Bool
    var inCode: Bool
    init() {
        out = StringBuilder()
        listMode = ""
        para = StringBuilder()
        hasPara = false
        inCode = false
    }

    func closeList(): Unit {
        if (listMode == "ul") {
            out.append("</ul>\n")
        } else if (listMode == "ol") {
            out.append("</ol>\n")
        }
        listMode = ""
    }

    func flushPara(): Unit {
        if (hasPara) {
            out.append("<p>")
            out.append(renderInline(trimAscii(para.toString())))
            out.append("</p>\n")
            para = StringBuilder()
            hasPara = false
        }
    }

    func render(md: String): String {
        let lines = md.split("\n", -1)
        for (raw in lines) {
            let line = trimAscii(raw)
            if (!inCode && line.startsWith("```")) {
                this.flushPara()
                this.closeList()
                inCode = true
                out.append("<pre><code>")
                continue
            }
            if (inCode) {
                if (line.startsWith("```")) {
                    inCode = false
                    out.append("</code></pre>\n")
                } else {
                    out.append(escapeHtml(raw.replace("\r", "")))
                    out.append("\n")
                }
                continue
            }
            if (line.size == 0) {
                this.flushPara()
                this.closeList()
                continue
            }
            if (line == "---" || line == "***") {
                this.flushPara()
                this.closeList()
                out.append("<hr>\n")
                continue
            }
            if (line.startsWith("#")) {
                let h = renderHeading(line)
                if (h.size > 0) {
                    this.flushPara()
                    this.closeList()
                    out.append(h)
                    continue
                }
            }
            if (line.startsWith("- ") || line.startsWith("* ")) {
                this.flushPara()
                if (listMode != "ul") {
                    this.closeList()
                    out.append("<ul>\n")
                    listMode = "ul"
                }
                out.append("<li>")
                out.append(renderInline(line[2..line.size]))
                out.append("</li>\n")
                continue
            }
            if (isOrderedItem(line)) {
                this.flushPara()
                if (listMode != "ol") {
                    this.closeList()
                    out.append("<ol>\n")
                    listMode = "ol"
                }
                out.append("<li>")
                out.append(renderInline(orderedText(line)))
                out.append("</li>\n")
                continue
            }
            if (line.startsWith("> ")) {
                this.flushPara()
                this.closeList()
                out.append("<blockquote><p>")
                out.append(renderInline(line[2..line.size]))
                out.append("</p></blockquote>\n")
                continue
            }
            // 普通文本：并入当前段落（markdown 连续行属同一段）
            if (listMode != "") {
                this.closeList()
            }
            if (hasPara) {
                para.append("\n")
            }
            para.append(line)
            hasPara = true
        }
        if (inCode) {
            out.append("</code></pre>\n")  // 未闭合的围栏：按闭合收尾，不丢内容
        }
        this.flushPara()
        this.closeList()
        return out.toString()
    }
}

/** 逐块渲染入口 */
public func mdToHtml(md: String): String {
    let r = MdRenderer()
    return r.render(md)
}

/** 标题行 → <h1>..<h6>；不是合法标题（# 后没空格）返回空串走段落 */
func renderHeading(line: String): String {
    let b = line.toArray()
    var level: Int64 = 0
    while (level < b.size && b[level] == UInt8(35)) {  // '#'
        level++
    }
    if (level > 6 || level >= b.size || b[level] != UInt8(32)) {
        return ""
    }
    let text = trimAscii(String.fromUtf8(b[(level + 1)..b.size]))
    if (text.size == 0) {
        return ""
    }
    return "<h${level}>" + renderInline(text) + "</h${level}>\n"
}

func isOrderedItem(line: String): Bool {
    let b = line.toArray()
    if (b.size < 3) {
        return false
    }
    return b[0] >= UInt8(49) && b[0] <= UInt8(57) && b[1] == UInt8(46) && b[2] == UInt8(32)
}

/** 去掉有序列表的「N. 」前缀 */
func orderedText(line: String): String {
    let b = line.toArray()
    var k: Int64 = 0
    while (k < b.size && b[k] >= UInt8(48) && b[k] <= UInt8(57)) {
        k++
    }
    if (k + 1 < b.size) {
        return String.fromUtf8(b[(k + 2)..b.size])
    }
    return line
}

/** HTML 转义（先转 & 防二次转义） */
public func escapeHtml(s: String): String {
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

/** 行内渲染：图片 / 链接 / 行内代码 / 加粗。
 * 按字节扫标记（标记都是 ASCII，不会撞进多字节字符中间），字面段按**区间**整体转 UTF-8——
 * 逐字节 append 会把汉字拆成非法序列。 */
public func renderInline(s: String): String {
    let b = escapeHtml(s).toArray()
    var out = StringBuilder()
    var i: Int64 = 0
    var seg: Int64 = 0  // 待输出字面段的起点
    while (i < b.size) {
        if (b[i] == UInt8(96)) {  // '`' 行内代码
            var j = i + 1
            while (j < b.size && b[j] != UInt8(96)) {
                j++
            }
            if (j < b.size) {
                if (i > seg) { out.append(String.fromUtf8(b[seg..i])) }
                out.append("<code>")
                out.append(String.fromUtf8(b[(i + 1)..j]))
                out.append("</code>")
                i = j + 1
                seg = i
                continue
            }
        }
        if (b[i] == UInt8(33) && i + 1 < b.size && b[i + 1] == UInt8(91)) {  // '![' 图片
            match (tryImageOrLink(b, i, true)) {
                case Some(m) =>
                    if (i > seg) { out.append(String.fromUtf8(b[seg..i])) }
                    out.append(m.html)
                    i = m.next
                    seg = i
                    continue  // 不 continue 会带着新 i 落进后面的 b[i] 判断（i 可能已越界，实测踩过）
                case None => ()
            }
        }
        if (b[i] == UInt8(91)) {  // '[' 链接
            match (tryImageOrLink(b, i, false)) {
                case Some(m) =>
                    if (i > seg) { out.append(String.fromUtf8(b[seg..i])) }
                    out.append(m.html)
                    i = m.next
                    seg = i
                    continue
                case None => ()
            }
        }
        if (b[i] == UInt8(42) && i + 1 < b.size && b[i + 1] == UInt8(42)) {  // '**' 加粗
            var j = i + 2
            while (j + 1 < b.size && !(b[j] == UInt8(42) && b[j + 1] == UInt8(42))) {
                j++
            }
            if (j + 1 < b.size) {
                if (i > seg) { out.append(String.fromUtf8(b[seg..i])) }
                out.append("<strong>")
                out.append(String.fromUtf8(b[(i + 2)..j]))
                out.append("</strong>")
                i = j + 2
                seg = i
                continue
            }
        }
        i++
    }
    if (b.size > seg) {
        out.append(String.fromUtf8(b[seg..b.size]))
    }
    return out.toString()
}

/** 行内匹配结果：渲染好的 HTML + 扫描推进到的位置 */
class InlineMatch {
    var html: String
    var next: Int64
    init(html: String, next: Int64) {
        this.html = html
        this.next = next
    }
}

/** 在 from 处尝试解析 ![alt](src) / [text](href)；成功返回渲染结果与新位置，失败 None */
func tryImageOrLink(b: Array<Byte>, from: Int64, isImage: Bool): Option<InlineMatch> {
    let textStart = if (isImage) { from + 2 } else { from + 1 }
    var cb: Int64 = -1
    var k = textStart
    while (k < b.size) {
        if (b[k] == UInt8(93)) {  // ']'
            cb = k
            break
        }
        k++
    }
    if (cb < 0 || cb + 1 >= b.size || b[cb + 1] != UInt8(40)) {  // '](' 
        return Option<InlineMatch>.None
    }
    var cp: Int64 = -1
    var m = cb + 2
    while (m < b.size) {
        if (b[m] == UInt8(41)) {  // ')'
            cp = m
            break
        }
        m++
    }
    if (cp < 0) {
        return Option<InlineMatch>.None
    }
    let text = String.fromUtf8(b[textStart..cb])
    let target = String.fromUtf8(b[(cb + 2)..cp])
    var html = StringBuilder()
    if (isImage) {
        html.append("<img src=\"")
        html.append(target)
        html.append("\" alt=\"")
        html.append(text)
        html.append("\">")
    } else {
        html.append("<a href=\"")
        html.append(target)
        html.append("\">")
        html.append(text)
        html.append("</a>")
    }
    return Option<InlineMatch>.Some(InlineMatch(html.toString(), cp + 1))
}
