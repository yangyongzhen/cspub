---
name: cspub-troubleshoot
description: "cspub 踩坑速查：OBS 200+0字节空图（isAudit JSON 数字坑）、CSDN 防盗链真面目、TLS unknown CA、stdx 1.2.0 编译差异、UTF-8 字节语义、每日发文限额、libstdx 缺失、开源中国 40001 Cookie 双前缀、发布成功但页面 404（SPA 外壳+审核态）、图床直链 403 是 CDN 拦 UA、raw.gitcode.com 418、头条 1050/7115、腾讯云 -9993/300031、语雀 namespace 404——发文链路任何异常先看这篇"
---

# cspub 踩坑速查

详细排查过程见 `docs/开发文档与踩坑记录.md`，此处按症状索引。

## 先按这四步收窄

1. `cspub whoami <平台>` —— 凭证字段是否齐（只验格式，零成本）；
2. `cspub check 文章.md --platform <平台>` —— 本地预检把服务端硬约束提前（标题字数、图片域名、必填项）；
3. `cspub imgs 文章.md` —— 图片去向是否符合该平台要求（非目标图床的图在头条必被拒）；
4. `CSPUB_DEBUG=1 cspub publish …` —— 看请求体积与上游原始响应首段，别猜。

## 症状 → 根因 → 处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 图片转存返回 200 但直链是 0 字节空图 | 签名响应里 `isAudit` 是 JSON **数字**，用只认字符串的 `jsonStr` 取得空串；空 `x:isAudit` 发 OBS 得空文件 | 已修（`jsonScalar` 按 Kind 取值）。若再遇"取 JSON 字段"，一律按 Kind 取，不假设类型 |
| 外链图发出去正文裂图（CSDN） | 防盗链：站外图 `<img>` 直连 **HTTP 200 + 0 字节** | 唯一解法是转存站内（publish 已内置）；先 `cspub imgs` 预演 |
| 头条整篇被拒 `7115 图片uri非法` | 正文里有任何非头条域名的图 | 全部转存头条 CDN；`check --platform toutiao` 会在本地先报「图片域名」不合规 |
| 头条单图上传失败 `1050` | 瞬时抖动而非稳定拒绝（同一批 6 张，每次失败的图集合都不同） | 已内置重传 2 次（间隔 1s）；仍失败就整篇重跑一次。`1000`/`100004`/`100005`（未登录）与 `7115` 不重传 |
| 腾讯云 `-9993 请选择文章标签` | `tagIds` 为空 | 配 `CSPUB_TENCENT_TAG_IDS`；用 `cspub tags --platform tencent` 查可用标签 |
| 腾讯云 `300031 user not the column member` | 用的专栏不是本账号已加入的（默认 149 常踩） | 换自己已加入的专栏 id → `CSPUB_TENCENT_CLASSIFY_IDS` |
| 腾讯云图片转存 6/6 全失败 | 本机访问 `raw.gitcode.com` 被 CloudWAF 拦成 **HTTP 418**（3223 字节挑战页） | 已内置换算到 `api.gitcode.com` 端点重试；实测 `成功 0/6` → `成功 6/6` |
| 语雀 `404` | namespace 只给了一段 | 必须 `user/repo` 两段式 |
| 图片转存部分失败就中止了 | 0.3.1 起默认门禁：`fail > 0` 直接中止，避免白烧每日额度 | 确认要硬发再加 `--force`；或先修图源 |
| TLS 报 unknown CA | CSDN 证书链根是 Certum，stdx TLS 默认/CustomCA 均过不了（系统 curl 可过，疑 stdx OpenSSL 行为问题） | 正式发文先试默认模式，失败再加 `--insecure`（TrustAll）；不要默认带上 |
| stdx 1.2.0 编译不过 | `CertificateVerifyMode` 移到 `stdx.net.tls.common` 子包；`CustomCA` 收接口数组而 `decodeFromPem` 返回类数组 | 显式 import 子包 + 限定名变体；接口数组逐元素显式搬移（Array 不协变） |
| 摘要截断乱码 / 行内渲染汉字变非法序列 | 按 Byte 处理中文：截断切进多字节序列、逐字节 append 拆散汉字 | 截断按首字节判界（`(b & 0xC0) != 0x80`）；行内渲染按区间整体转码 |
| 发布回 `400300012` / `400300001` | CSDN 每日限额：单账号 1 篇/天，**存草稿同算** | 换自然日或换账号；不是工具问题，不要往代码排查 |
| 直接跑二进制报缺 `libstdx.encoding.json.so` | 动态链接产物缺运行时库路径 | 补 `LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/...`；不是功能缺失 |
| 开源中国回 `code 40001 用户未登录` | Cookie 文件本身已含 `oscid=`，又被拼了一次前缀 → 服务端收到 `oscid=oscid=…` | 整串透传：`-H "Cookie: $(cat cookie 文件)"`，别再手拼 `oscid=` |
| 开源中国/掘金文章链接打开是「找不到您访问的页面」 | 路由写错，或文章已入库但**待审核**未公开；且 SPA 外壳对任意 id 都回 200，`curl` 判不出 | URL 用 `https://www.oschina.net/blog/{id}`（`/u/{userId}/blog/{id}` 是 404）；判可见性用浏览器渲染（`document.title`、`body.innerText` 长度、`img.naturalWidth`）或 `blog/detail` 接口 |
| 平台图床直链 `curl` 得 403 / 146 字节 | CDN（oscimg、掘金 CDN）拦非浏览器客户端返回 `TLB` 页，**不是死链** | 验收带浏览器 UA + `Referer` 取回，并与源图**比字节**；别用裸 curl 状态码判图坏 |
| 图床直链里出现 `//null/`、双斜杠 | 服务端未使用的桶位段，不影响对象 | 照常使用；仍按上一条带 UA 取回验字节 |
| 头条 `--draft` 被拒绝提交 | 头条没有草稿通道（`save` 非 0 即发布；`save=0` 需浏览器风控一次性签名，纯 HTTP 不可复现） | 这是**设计如此**：改用 `--live`，别去找"补字段"的偏方 |
| 401/403（发文接口） | Cookie 过期 / WAF 拦截（403+HTML） | 重取 Cookie；换网络过验证码再试 |

## 诊断工具

- `CSPUB_DEBUG=1`：stderr 打请求体积、OBS 状态码与响应首段——排查上传/发文链路先开它。
- `cspub html 文章.md`：渲染结果目验（表格/脚注不渲染属已知限制）。
- `cspub check 文章.md --platform p`：不联网的平台预检，`exit 1` 即表示该平台必失败。
- 图床直链验收：`curl -sI` 返回 `200 + 非零 Content-Length` 才算真图。
