/** 平台级「发布前预检」规则：把各平台写死在服务端的硬约束提到本地，避免「发一次错一次」。
 *
 * 只收**有证据**的规则（编辑器行为 / 实测错误码），不写猜测：
 *   头条   标题 5~30 字（超出编辑器存不进）；正文每张图必须在头条 CDN，否则整篇 7115
 *   百家号 标题 8-40 字符、正文 ≤20000 字符、origin_url 必填、发布模式必须有封面
 *   腾讯云 --live 正文纯文本 ≥140 字；tagIds 空回 -9993；专栏 149 未加入回 300031
 *
 * 全部是纯函数：不联网、不读环境变量，调用方把配置当参数传进来，便于单测。
 * 发布前的 **网络** 判定（登录态、图床连通性）不在这里，那是 publish 的活。
 */
package cspub

import std.collection.*

/** 单条预检问题：label 是短标签（便于脚本 grep），detail 给判定依据与下一步动作。 */
public struct PlatformIssue {
    public let label: String
    public let detail: String
    public init(label: String, detail: String) {
        this.label = label
        this.detail = detail
    }
}

/** 文案里用的平台名 */
public func platformDisplayName(platform: String): String {
    return match (platform) {
        case "csdn" => "CSDN"
        case "zhihu" => "知乎"
        case "baijiahao" => "百家号"
        case "cnblogs" => "博客园"
        case "juejin" => "掘金"
        case "oschina" => "开源中国"
        case "tencent" => "腾讯云开发者社区"
        case "yuque" => "语雀"
        case "toutiao" => "头条号"
        case "segmentfault" => "SegmentFault"
        case _ => platform
    }
}

/** 按平台规则算问题清单（纯函数，单测覆盖）。
 * 空数组＝本地预检通过（不代表服务端一定收，登录态/图床要联网才知道）。
 * `imgCount` 是正文图片总数，`localImgCount` 是其中未转存的本地图数量，
 * `coverGiven` 是 `--cover` 是否显式指定了封面文件（百家号专用：封面可与正文图解耦）。 */
public func platformCheckIssues(platform: String, title: String, bodyChars: Int64,
    plainChars: Int64, originUrl: String, tagCfg: String, classifyCfg: String,
    imgCount: Int64, localImgCount: Int64, coverGiven: Bool): Array<PlatformIssue> {
    let out = ArrayList<PlatformIssue>()
    let name = platformDisplayName(platform)
    let tchars = utf8CharCount(trimAscii(title))
    if (tchars == 0) {
        out.add(PlatformIssue("标题", "${name} 必须有标题（front-matter 缺 title）"))
    }
    if (platform == "toutiao") {
        if (tchars > 0 && (tchars < TOUTIAO_TITLE_MIN || tchars > TOUTIAO_TITLE_MAX)) {
            out.add(PlatformIssue("标题字数",
                "当前 ${tchars} 字，头条要求 ${TOUTIAO_TITLE_MIN}~${TOUTIAO_TITLE_MAX} 字（按字符计，超了编辑器存不进）"))
        }
        if (imgCount > 0) {
            out.add(PlatformIssue("图片域名",
                "正文 ${imgCount} 张图：头条只认自家 CDN，发布时会逐张转存；任一张失败即整篇拒稿（7115）"))
        }
    }
    if (platform == "baijiahao") {
        if (tchars > 0 && (tchars < 8 || tchars > 40)) {
            out.add(PlatformIssue("标题字数", "当前 ${tchars} 字符，百家号接口要求 8-40 字符"))
        }
        if (bodyChars > 20000) {
            out.add(PlatformIssue("正文长度", "当前 ${bodyChars} 字符，百家号正文上限 20000 字符"))
        }
        if (trimAscii(originUrl).size == 0 && tchars > 0) {
            out.add(PlatformIssue("origin_url", "百家号 origin_url 必填：front-matter 加 origin_url: <原文地址>"))
        }
        if (localImgCount == 0 && !coverGiven) {
            out.add(PlatformIssue("封面",
                "百家号发布模式必须有封面：用 --cover <本地图> 显式指定，或让正文含一张本地图片（浏览器通道取正文首张本地图当封面）"))
        }
    }
    if (platform == "tencent") {
        if (plainChars < TENCENT_MIN_PLAIN) {
            out.add(PlatformIssue("正文字数",
                "正文纯文本 ${plainChars} 字：--live 发布要求不少于 ${TENCENT_MIN_PLAIN} 字（--draft 不受此限）"))
        }
        if (parseTencentTagIds(tagCfg).size == 0) {
            out.add(PlatformIssue("标签",
                "--live 发布 tagIds 必填（空则服务端回 -9993）；先跑 cspub tags --platform tencent 取 id"))
        }
        if (parseTencentClassifyIds(classifyCfg).size > 0 &&
            classifyCfg.size == 0) {
            out.add(PlatformIssue("专栏",
                "未配专栏，回落默认 ${TENCENT_DEFAULT_CLASSIFY}（技术）；账号若未加入该专栏会回 300031"))
        }
    }
    if (localImgCount > 0 && platform != "toutiao") {
        if (platform == "baijiahao") {
            // 百家号与别家相反：正文本地图**不会**被上传（浏览器脚本只上传封面），
            // 留在正文里就是死链——所以这里说的是「改外链」，不是「配 AtomGit token」
            out.add(PlatformIssue("本地图",
                "正文还有 ${localImgCount} 张本地图片：百家号只上传封面、不上传正文图，正文里这些会成死链；改成公网直链，封面用 --cover 单独指定"))
        } else {
            out.add(PlatformIssue("本地图",
                "正文还有 ${localImgCount} 张本地图片：CSPUB_ATOMGIT_TOKEN 未配或未转存时会成死链"))
        }
    }
    return out.toArray()
}

/** 预检结论（纯函数）：有问题且 strict 时返回 true＝调用方应中止。 */
public func platformCheckFailed(issues: Array<PlatformIssue>): Bool {
    return issues.size > 0
}

/** 把问题清单打印成可读文本（main.cj 与测试共用同一种排版） */
public func printPlatformIssues(platform: String, issues: Array<PlatformIssue>): Unit {
    if (issues.size == 0) {
        println("预检（${platformDisplayName(platform)}）：本地规则全部通过")
        return
    }
    println("预检（${platformDisplayName(platform)}）：${issues.size} 条待处理")
    for (it in issues) {
        println("  ✗ ${it.label}：${it.detail}")
    }
}
