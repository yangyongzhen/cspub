/** jsonpack（github.com/rgcl/jsonpack，MIT）`pack` 的仓颉移植。
 *
 * 为什么需要它：腾讯云社区编辑器文章 `content` 字段既不是 HTML 也不是裸 JSON，而是
 *   base64(urlencode(JSON.stringify(jsonpack.pack(rawDraft))))
 * 其中 rawDraft 是 Draft.js 的 RawDraftContentState（blocks + entityMap）。
 * 2026-11 用真机抓包比对：本实现输出与线上请求体**逐字节一致**，是把 markdown 发上腾讯云的唯一通路。
 *
 * 压缩格式（四段，`^` 分隔）：
 *   <字符串字典>^<整数字典>^<浮点字典>^<结构>
 * 结构里 `$` 起对象、`@` 起数组、`]` 收尾，叶子用 base36 下标引用字典；
 * 特例 -3 空值 / -4 空串（都不进字典）。字典按**首次出现顺序**编号，顺序变了引用全错。
 *
 * 因此这里不用 `JsonObject`（其 `getFields()` 返回 HashMap，遍历顺序不保证）：
 * 节点树由有序构造器搭起来，字典在打包阶段按 children 顺序一次性填充，顺序完全可控。
 * 服务端只存串、前端 unpack 重建对象，对象键序不影响语义，故串形态稳定即可。
 */
package cspub

import std.collection.*

enum JpKind {
    | JpArr
    | JpObj
    | JpStr
    | JpInt
    | JpEmpty
}

/** 压缩用的有序节点：对象键值与数组元素统一放在 children 里，顺序即序列化顺序 */
public class JpNode {
    let kind: JpKind
    let children: ArrayList<JpNode>
    var text: String
    var num: Int64
    var ref: Int64

    init(kind: JpKind) {
        this.kind = kind
        this.children = ArrayList<JpNode>()
        this.text = ""
        this.num = 0
        this.ref = 0
    }
}

/** 空对象 `{}` */
public func jpObj(): JpNode {
    return JpNode(JpKind.JpObj)
}

/** 空数组 `[]` */
public func jpArr(): JpNode {
    return JpNode(JpKind.JpArr)
}

/** 字符串（打包时才转义，保持原值） */
public func jpStr(v: String): JpNode {
    if (v.size == 0) {
        return JpNode(JpKind.JpEmpty)
    }
    let n = JpNode(JpKind.JpStr)
    n.text = v
    return n
}

/** 整数 */
public func jpInt(v: Int64): JpNode {
    let n = JpNode(JpKind.JpInt)
    n.num = v
    return n
}

/** 往对象里按顺序追加一个键值对 */
public func jpPut(o: JpNode, key: String, value: JpNode): Unit {
    o.children.add(jpStr(key))
    o.children.add(value)
}

/** 往数组里按顺序追加一个元素 */
public func jpAdd(a: JpNode, value: JpNode): Unit {
    a.children.add(value)
}

/** 三张字典：编号即引用下标，故必须保持插入顺序（ArrayList）而非只留 Map */
class JpDict {
    let strings: ArrayList<String> = ArrayList<String>()
    let stringIndex: HashMap<String, Int64> = HashMap<String, Int64>()
    let integers: ArrayList<String> = ArrayList<String>()
    let integerIndex: HashMap<String, Int64> = HashMap<String, Int64>()

    func internString(key: String): Int64 {
        if (let Some(i) <- stringIndex.get(key)) {
            return i
        }
        let i = Int64(strings.size)
        strings.add(key)
        stringIndex.add(key, i)
        return i
    }

    func internInteger(key: String): Int64 {
        if (let Some(i) <- integerIndex.get(key)) {
            return i
        }
        let i = Int64(integers.size)
        integers.add(key)
        integerIndex.add(key, i)
        return i
    }
}

/** 原库的 `_encode`：转义与分隔符冲突的五个字符。
 * 必须逐字节单遍替换——先替换 `%` 再替换别的会把 `%25` 二次转义成 `%2525`（真包对照过）。 */
func jpEncode(s: String): String {
    let b = s.toArray()
    var hit = false
    for (x in b) {
        if (x == UInt8(0x20) || x == UInt8(0x2B) || x == UInt8(0x7C) || x == UInt8(0x5E) ||
            x == UInt8(0x25)) {
            hit = true
            break
        }
    }
    if (!hit) {
        return s
    }
    let out = ArrayList<Byte>()
    for (x in b) {
        if (x == UInt8(0x20)) {
            out.add(UInt8(0x2B)) // ' ' -> '+'
        } else if (x == UInt8(0x2B)) {
            out.add(UInt8(0x25)) // '+' -> '%2B'
            out.add(UInt8(0x32))
            out.add(UInt8(0x42))
        } else if (x == UInt8(0x7C)) {
            out.add(UInt8(0x25)) // '|' -> '%7C'
            out.add(UInt8(0x37))
            out.add(UInt8(0x43))
        } else if (x == UInt8(0x5E)) {
            out.add(UInt8(0x25)) // '^' -> '%5E'
            out.add(UInt8(0x35))
            out.add(UInt8(0x45))
        } else if (x == UInt8(0x25)) {
            out.add(UInt8(0x25)) // '%' -> '%25'
            out.add(UInt8(0x32))
            out.add(UInt8(0x35))
        } else {
            out.add(x)
        }
    }
    return String.fromUtf8(out.toArray())
}

/** JS `Number.prototype.toString(36).toUpperCase()` 的等价实现（含负号） */
func jpBase36(n: Int64): String {
    if (n == 0) {
        return "0"
    }
    var v = n
    let neg = v < 0
    if (neg) {
        v = -v
    }
    let buf = ArrayList<Byte>()
    while (v > 0) {
        let d = v % 36
        if (d < 10) {
            buf.add(UInt8(48 + d))
        } else {
            buf.add(UInt8(55 + d))
        }
        v = v / 36
    }
    let out = ArrayList<Byte>()
    if (neg) {
        out.add(UInt8(0x2D))
    }
    var i = buf.size - 1
    while (i >= 0) {
        out.add(buf[i])
        i--
    }
    return String.fromUtf8(out.toArray())
}

/** 打包阶段先序遍历填字典：字符串/整数按出现顺序入表，对象键与字符串值共用字符串表 */
func jpCollect(n: JpNode, d: JpDict): Unit {
    match (n.kind) {
        case JpKind.JpStr =>
            n.ref = d.internString(jpEncode(n.text))
        case JpKind.JpInt =>
            n.ref = d.internInteger(jpBase36(n.num))
        case JpKind.JpArr =>
            for (c in n.children) {
                jpCollect(c, d)
            }
        case JpKind.JpObj =>
            for (c in n.children) {
                jpCollect(c, d)
            }
        case _ => ()
    }
}

/** 结构段递归序列化：容器用 `|` 连接子项、`]` 收尾（空容器即 `@]` / `$]`） */
func jpEmit(n: JpNode, strLen: Int64, intLen: Int64, sb: StringBuilder): Unit {
    match (n.kind) {
        case JpKind.JpArr =>
            sb.append("@")
            jpEmitChildren(n, strLen, intLen, sb)
        case JpKind.JpObj =>
            sb.append("$")
            jpEmitChildren(n, strLen, intLen, sb)
        case JpKind.JpStr =>
            sb.append(jpBase36(n.ref))
        case JpKind.JpInt =>
            sb.append(jpBase36(strLen + n.ref))
        case JpKind.JpEmpty =>
            sb.append("-4")
    }
}

func jpEmitChildren(n: JpNode, strLen: Int64, intLen: Int64, sb: StringBuilder): Unit {
    var first = true
    for (c in n.children) {
        if (!first) {
            sb.append("|")
        }
        jpEmit(c, strLen, intLen, sb)
        first = false
    }
    sb.append("]")
}

/** jsonpack.pack：有序节点树 -> 压缩串（单测按线上真包逐字节对齐） */
public func jsonpackPack(root: JpNode): String {
    let d = JpDict()
    jpCollect(root, d)
    let strLen = Int64(d.strings.size)
    let intLen = Int64(d.integers.size)
    let sb = StringBuilder()
    var first = true
    for (s in d.strings) {
        if (!first) {
            sb.append("|")
        }
        sb.append(s)
        first = false
    }
    sb.append("^")
    first = true
    for (s in d.integers) {
        if (!first) {
            sb.append("|")
        }
        sb.append(s)
        first = false
    }
    sb.append("^^")
    jpEmit(root, strLen, intLen, sb)
    return sb.toString()
}
