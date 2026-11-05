/** AtomGit 图床：把正文图片提交进仓库，用 raw 外链直接嵌进正文。
 * 为什么需要：掘金/博客园这类平台接受外链图片（实测 API 建草稿时外链图渲染
 * naturalWidth>0），走外链就省掉了往平台图床搬的上传链（掘金 ImageX 的浏览器通道
 * 依赖 python3+playwright）。本地图片先落到 AtomGit 仓库，正文里嵌 raw 链接即可。
 *
 * 接口（AtomGit API v5，https://atomgit-api-doc.atomgit.com/1.repositories/4.create_new_file.html）：
 *   POST https://api.atomgit.com/api/v5/repos/{owner}/{repo}/contents/{path}
 *   Authorization: Bearer <令牌>
 *   {"content":"<base64>","message":"<提交说明>","branch":"<分支>"}
 * 外链形态（实测匿名直取 200 + image 类型）：
 *   https://atomgit.com/api/v5/repos/{owner}/{repo}/raw/{path}?ref={branch}
 */
package cspub

import stdx.encoding.base64.*
import stdx.encoding.json.*
import stdx.net.http.*

public const ATOMGIT_API: String = "https://api.atomgit.com"

/** raw 外链（纯函数，供测试对账）。path 不加前导斜杠。 */
public func atomgitRawUrl(repo: String, path: String, branch: String): String {
    var br = branch
    if (br.size == 0) {
        br = "main"
    }
    return "https://atomgit.com/api/v5/repos/${repo}/raw/${path}?ref=${br}"
}

/** 仓库内文件路径（纯函数）：<dir>/<随机段>.<扩展名>。
 * 随机段保证重复发文不撞路径——contents 接口对已存在路径返回 400，新建不会复用旧文件。 */
public func atomgitImagePath(dir: String, rand: String, ext: String): String {
    var e = ext
    if (e.size > 0 && !e.startsWith(".")) {
        e = "." + e
    }
    if (e.size == 0) {
        e = ".png"
    }
    let name = "${rand}${e}"
    let d = trimSlash(dir)
    if (d.size == 0) {
        return name
    }
    return "${d}/${name}"
}

func trimSlash(s: String): String {
    let t = trimAscii(s)
    let bytes = t.toArray()
    let slash = UInt8(47)
    let space = UInt8(32)
    var a: Int64 = 0
    var b: Int64 = bytes.size
    while (a < b && (bytes[a] == slash || bytes[a] == space)) {
        a++
    }
    while (b > a && (bytes[b - 1] == slash || bytes[b - 1] == space)) {
        b--
    }
    return String.fromUtf8(bytes[a..b])
}

/** 新建文件请求体（纯函数，供测试对账） */
public func buildAtomgitCommitBody(contentB64: String, message: String, branch: String): String {
    let obj = JsonObject()
    obj.put("content", JsonString(contentB64))
    obj.put("message", JsonString(message))
    if (branch.size > 0) {
        obj.put("branch", JsonString(branch))
    }
    return obj.toJsonString()
}

/** 从响应里取 commit.sha；取不到（400/401/403 错误结构）返回空串，即上传失败。 */
public func parseAtomgitCommitSha(respText: String): String {
    let root = try { JsonValue.fromStr(respText) } catch (e: Exception) {
        let _ = e
        JsonValue.fromStr("{}")
    }
    match (root.kind()) {
        case JsonKind.JsObject =>
            if (let Some(c) <- root.asObject().get("commit")) {
                match (c.kind()) {
                    case JsonKind.JsObject =>
                        if (let Some(s) <- c.asObject().get("sha")) {
                            match (s.kind()) {
                                case JsonKind.JsString =>
                                    return s.asString().getValue()
                                case _ => ()
                            }
                        }
                    case _ => ()
                }
            }
        case _ => ()
    }
    return ""
}

/** 正文里是否有本地图片引用（非 http(s)/data）——决定要不要提示「没配令牌会死链」 */
public func hasLocalImages(md: String): Bool {
    for (img in findExternalImages(md)) {
        let src = img.url
        if (!src.startsWith("http://") && !src.startsWith("https://") && !src.startsWith("data:")) {
            return true
        }
    }
    return false
}

/** 把正文里的本地图片批量上传 AtomGit 并回写成 raw 外链。
 * 返回 (新正文, 成功数, 失败数)；已是外链的引用原样保留。
 * 失败不抛异常、不改原引用——调用方可据此决定降级到平台图床还是仅提示（best-effort）。 */
public func rehostImagesAtomGit(md: String, token: String, repo: String, branch: String,
    dir: String, insecure: Bool): (String, Int64, Int64) {
    if (token.size == 0) {
        return (md, 0, 0)
    }
    let imgs = findExternalImages(md)
    var ok: Int64 = 0
    var fail: Int64 = 0
    var out = md
    // 从后往前替换，避免前面的替换把后面的区间偏移搞乱
    var i = Int64(imgs.size) - 1
    while (i >= 0) {
        let ref = imgs[i]
        let src = ref.url
        i--
        if (src.startsWith("http://") || src.startsWith("https://") || src.startsWith("data:")) {
            continue
        }
        let data = try { readImageBytes(src) } catch (e: Exception) {
            let _ = e
            Array<Byte>(0, repeat: 0)
        }
        if (data.size == 0) {
            fail++
            println("⚠ 读不到本地图片，保留原引用：${src}")
            continue
        }
        let path = atomgitImagePath(dir, randomHex(12), extOf(src))
        let url = uploadImageAtomGit(token, repo, path, branch, data, insecure)
        if (url.size == 0) {
            fail++
            continue
        }
        out = out[0..ref.urlStart] + url + out[ref.urlEnd..out.size]
        ok++
    }
    return (out, ok, fail)
}

/** 上传一张图到 AtomGit 仓库，成功返回 raw 外链，失败返回空串（调用方保留原引用）。
 * repo 形如 "owner/repo"；token 走 Authorization 头（不落 URL，避免日志带走令牌）。 */
public func uploadImageAtomGit(token: String, repo: String, path: String, branch: String,
    data: Array<Byte>, insecure: Bool): String {
    if (token.size == 0 || repo.size == 0 || path.size == 0 || data.size == 0) {
        return ""
    }
    let url = "${ATOMGIT_API}/api/v5/repos/${repo}/contents/${path}"
    let body = buildAtomgitCommitBody(toBase64String(data), "cspub: 上传正文图片 ${path}", branch)
    let b = HttpRequestBuilder()
        .url(url)
        .post()
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("Authorization", "Bearer ${token}")
        .body(body)
    let r = execRequest(b.build(), insecure)
    dbg("atomgit 上传 HTTP ${r.status}：${r.text}")
    if (r.status != 200) {
        if (r.status == 401 || r.status == 403) {
            println("⚠ AtomGit 令牌无效或权限不足（HTTP ${r.status}）：${r.text}")
        } else {
            println("⚠ AtomGit 上传失败（HTTP ${r.status}）：${r.text}")
        }
        return ""
    }
    if (parseAtomgitCommitSha(r.text).size == 0) {
        println("⚠ AtomGit 响应里没有 commit.sha，按失败处理：${r.text}")
        return ""
    }
    return atomgitRawUrl(repo, path, branch)
}
