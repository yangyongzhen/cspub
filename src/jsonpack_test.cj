/** jsonpack 移植的对照测试：期望值全部由 node 端原库 `jsonpack.pack` 实测产出。
 *
 * 这些是硬真值而不是"看着像"——只要一个字节不同，腾讯云就回 400「文章草稿创建失败」，
 * 所以四个用例覆盖：空容器、单 block（含线上真包原文）、多 block（字典复用/引用递增）、分隔符转义。
 *
 * 节点按 Draft.js raw 的键序构造（key,text,type,depth,inlineStyleRanges,entityRanges,data），
 * 与抓包请求体一致，因此压缩串可以逐字节比对。
 */
package cspub

import std.unittest.*

/** 造一个 unstyled 文本 block，键序与线上 raw 一致 */
func testBlock(key: String, text: String): JpNode {
    let b = jpObj()
    jpPut(b, "key", jpStr(key))
    jpPut(b, "text", jpStr(text))
    jpPut(b, "type", jpStr("unstyled"))
    jpPut(b, "depth", jpInt(0))
    jpPut(b, "inlineStyleRanges", jpArr())
    jpPut(b, "entityRanges", jpArr())
    jpPut(b, "data", jpObj())
    return b
}

/** 造 raw 根：{blocks:[...], entityMap:{}} */
func testRaw(blocks: Array<JpNode>): JpNode {
    let root = jpObj()
    let arr = jpArr()
    for (b in blocks) {
        jpAdd(arr, b)
    }
    jpPut(root, "blocks", arr)
    jpPut(root, "entityMap", jpObj())
    return root
}

@Test
func jsonpackEmptyContainersTest(): Unit {
    // node: jp.pack({blocks:[],entityMap:{}})
    let expect = "blocks|entityMap^^^$0|@]|1|$]]"
    let got = jsonpackPack(testRaw([]))
    @Assert(expect == got)
}

@Test
func jsonpackSingleBlockTest(): Unit {
    // 与腾讯云真机抓包的 content 解码结果逐字节相同（node 端同输入复现一致）
    let expect = "blocks|key|421q5|text|aaaaaa|type|unstyled|depth|inlineStyleRanges|" +
        "entityRanges|data|entityMap^0^^$0|@$1|2|3|4|5|6|7|C|8|@]|9|@]|A|$]]]|B|$]]"
    let got = jsonpackPack(testRaw([testBlock("421q5", "aaaaaa")]))
    @Assert(expect == got)
}

@Test
func jsonpackMultiBlockTest(): Unit {
    // node: 两个 block，字典里 key/text 各入一次，第二块复用键名引用
    let expect = "blocks|key|k1|text|你好|type|unstyled|depth|inlineStyleRanges|entityRanges|" +
        "data|k2|世界|entityMap^0^^$0|@$1|2|3|4|5|6|7|E|8|@]|9|@]|A|$]]|$1|B|3|C|5|6|7|E|8|@]|" +
        "9|@]|A|$]]]|D|$]]"
    let got = jsonpackPack(testRaw([testBlock("k1", "你好"), testBlock("k2", "世界")]))
    @Assert(expect == got)
}

@Test
func jsonpackSeparatorEscapingTest(): Unit {
    // node: text='a b|c%d^e+f' —— 空格/竖线/百分号/脱字符/加号都必须单遍转义，且不能二次转义
    let expect = "blocks|key|k1|text|a+b%7Cc%25d%5Ee%2Bf|type|unstyled|depth|" +
        "inlineStyleRanges|entityRanges|data|entityMap^0^^$0|@$1|2|3|4|5|6|7|C|8|@]|9|@]|A|$]]]|B|$]]"
    let got = jsonpackPack(testRaw([testBlock("k1", "a b|c%d^e+f")]))
    @Assert(expect == got)
}
