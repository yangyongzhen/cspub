# Changelog

cspub 版本变更记录。版本号规则沿用 cjh：重大更新递增中间位，小更新递增末位；版本号单一真相在 `cjpm.toml` 的 `version` 字段。每条变更须带验证证据（实测输出、错误码、转存结果），不写没有证据的条目。

## [0.3.2] - 2026-11-08

按《AI 时代，我为什么推荐用 cj-tauri 开发桌面应用》十平台实战发布的复盘，修掉 3 个有实证的问题——
两个是「本地就能看出、却要等到发布现场才发现」的误报，一个是「照预检提示做反而埋雷」的能力缺口。

### 新增

- **百家号 `--cover <本地图>`**（`publishToBaijiahaoCookie` / `cmdPublish` / `cmdCheck` / `platformCheckIssues`）：
  封面与正文图解耦。此前封面来源被写死成「正文第一张本地图」，而伴生脚本
  `scripts/baijiahao_publish.py` 只有 `--cover-file` 一个图片入口、**不上传正文里的图**——于是正文全外链就
  没有封面（被拒），正文放本地图就有封面但那张图死链，形成死角。现在 `--cover` 单独指定封面，正文可以全用
  公网直链；`check` 同样接受 `--cover`，给了就不再要求正文含本地图。预检里百家号的本地图告警也改成准确描述
  （「百家号只上传封面、不上传正文图」），不再误导成「配 `CSPUB_ATOMGIT_TOKEN` 就好」。
  证据：`check /tmp/cspub_cover_check.md --platform baijiahao` → 无 `--cover` 报「封面」1 条、`EXIT=1`；
  加 `--cover docs/imgs/cjt-vs-tauri-rgb.png` → 「本地规则全部通过」、`EXIT=0`。

### 修复

- **头条图片转存 URL 未做 HTML 反转义**（新增纯函数 `htmlUnescape`，`rehostToutiaoImages` 接入）：
  `rehostToutiaoImages` 处理的是 `mdToHtml` 渲染后的 HTML，URL 里的 `&` 已被转义成 `&amp;`，而
  `collectImgSrcs` 直接取 `src` 原文去下载，签名参数名变成 `amp;policy` → 服务端按无效签名拒绝。
  实战里一篇 5 图文章 5 张全部打印「⚠ 读不到图片（头条会拒稿 7115）」，但链接浏览器打开正常。
  现在下载与取扩展名都走反转义后的 URL，`map` 的 key 仍保留 HTML 原文串（`rewriteHtmlImgs` 要按原 `src` 匹配回写）。
  `htmlUnescape` 只反转义一层（`&amp;amp;` → `&amp;`）、未知实体（`&nbsp;`）原样保留、分段 append 整段 UTF-8 不拆汉字。
- **头条 1050 失败时给出真实排查方向**（`uploadToutiaoImage`）：1050 除瞬时抖动外还有**确定性**成因——
  图片编码格式。实测 rsvg 导出的 8-bit RGBA（带 alpha）与 16-bit/color PNG 稳定被拒，转 8-bit RGB（PNG24）
  后一次通过；此前重试耗尽只打印「上传最终失败」，容易误判成限流。现在直接打印编码成因与
  `convert in.png -alpha off -depth 8 -type TrueColor PNG24:out.png` 的转码命令。

### 文档

- `docs/开发文档与踩坑记录.md`：新增 §27（`&amp;` 导致头条转存误报）、§28（百家号封面与正文图互相绑架），
  并给 §24（头条 1050）补上「确定性成因 = 图片编码」的实测数据与改判方法。

### 构建

- `cjpm build` 零警告（`grep -c 'warning:'` → `0`）；`cjpm test` → `TOTAL: 95 / PASSED: 95 / FAILED: 0`
  （新增 4 个 `htmlUnescape` 用例、1 个 `--cover` 豁免封面用例；`platformCheckIssues` 多一个 `coverGiven` 参数，
  既有 9 处调用同步更新）。
- 本版**未重跑真机发文**：头条当日额度已用、CSDN 当日发文限额已触顶（`400300012`），
  端到端验证以 `check` 预检 + 单测为准；图文发布链路的真机凭证见 0.3.1 与本次实战记录。

## [0.3.1] - 2026-11-07

按「十平台发文实战复盘」的 13 项问题清单修掉前四项：把「发一次错一次」的失败提前到本地，把注定失败的提交挡在发文额度之外。

### 新增

- **头条图床上传重传**（`uploadToutiaoImage` / `uploadToutiaoImageOnce` / `toutiaoUploadRetryable`）：实战里一轮 6 张图，
  每次失败的图集合都不一样（1/6、3/6、2/3 成功不定），说明 1050「图片上传失败」是瞬时抖动而非稳定拒绝。
  现在单张最多重传 2 次（`TOUTIAO_UPLOAD_MAX_ATTEMPTS`），每次间隔 1s；可重试判据单列为纯函数：
  `code` 命中 `1050`/`5009`、HTTP 5xx/429/0、以及「HTTP 200 但响应不可解析」都算瞬时；
  `1000`/`100004`/`100005`（未登录）与 `7115`（正文图链非法）立即失败不重传，别把时间花在必然失败的重跑上。
  顺带把成功判据从只认 `state == "SUCCESS"` 改成 `code == "0"` 或 `state == "SUCCESS"`——实测响应是**扁平结构**，
  新版成功时 `state` 常为空串，只认 state 会把成功判成失败。
- **图片转存部分失败即中止**（`rehostFailGate`）：`publish` 遇到 `fail > 0` 默认中止并打印三条出路，
  `--force` 才继续提交。头条对非自家域名的图片整篇拒稿（7115），明知必败还提交等于白烧一次每日额度
  （头条约 4 篇/天）。此前是「打条警告照发」。
- **`check --platform <p>` 平台预检**（`src/platform_rules.cj`）：不联网、纯本地规则，把服务端硬约束提前。
  头条标题 5~30 字 / 有图即提示必须全部进头条 CDN（失败即 7115）；百家号标题 8-40 字符、正文 ≤20000 字符、
  `origin_url` 必填、**无本地图则卡封面**（实测「请添加封面」来源）；腾讯云 `--live` 正文 ≥140 字、`tagIds` 必填
  （空回 -9993）、未配专栏提示回落 149 有 300031 风险。任一条不通过返回 1，可直接串进 CI。
- **`cspub tags --platform tencent`**（`cmdTencentTags`）：调 `FetchJoinedColumnList` 列出**本账号已加入**的专栏，
  再对前 5 个专栏调 `FetchColumnTags` 打印可用标签（每栏最多展示 12 个），末尾直接给出可复制的
  `export CSPUB_TENCENT_CLASSIFY_IDS=…` / `CSPUB_TENCENT_TAG_IDS=…`。此前 help 里写的是别的账号的 id
  （`149`/`10757,17183`），照抄必撞 `300031`/`-9993`。新增 `tencentColumnRpcUrl`（namespace 是 `column/column`，
  不是发文的 `column/article`）、`tencentRespCode`、`tencentItemArray` 与 `parseTencentColumns`/`parseTencentTags`
  两个防御式解析器（兼容 `columnId|classifyId|id`、`list|items|columns|tags|result|records` 等包法）。

- **图片下载备用端点**（`atomgitApiFallbackUrl` / `downloadImageTry` / `downloadImage`）：真机验证时腾讯云转存
  **6/6 全失败**，查下来不是图床问题——本机访问 `raw.gitcode.com` 被 CloudWAF 拦成 `HTTP 418`（3223 字节挑战页），
  同一张图换 `api.gitcode.com` 端点 `HTTP 200 / 286732 bytes`。现在主端点失败且是 raw 直链时，自动换算到
  `https://api.gitcode.com/api/v5/repos/{u}/{r}/raw/{path}?ref={branch}` 重试一次（下载改为不抛异常的
  `downloadImageTry` 返回值串联，失败信息保留主端点原因）。腾讯云那条路是**服务端抓链**（`SaveHttpImageCommon`
  只收 url，不走本机下载），所以在交给它之前就把 URL 换成 api 端点——**实测转存从 `成功 0，失败 6` 变成
  `成功 6，失败 0`**。非 raw 直链（其它域名/段数不够/第 6 段不是 `raw`）返回空串，不造坏 URL。

### 变更

- `--force` 进入 `publish` 参数表；`check` 由 `cmdCheck(path)` 改为 `cmdCheck(args)` 以吃 `--platform`。
- help 版本行同步 0.3.1，用法区新增 `check --platform`、`--force`、`tags` 三行。

### 构建与测试

- `cjpm build` 零警告：`cjpm build 2>&1 | grep -c 'warning:'` → `0`（两轮均 0）。
- `cjpm test` 全绿：`Summary: TOTAL: 91 / PASSED: 91, SKIPPED: 0, ERROR: 0, FAILED: 0`。
  本轮新增 7 个用例：`toutiaoUploadRetryableTest`、`tencentColumnRpcUrlTest`、`tencentRespCodeTest`、
  `tencentColumnParseTest`、`tencentTagParseTest`、`platformCheckToutiaoTest` / `platformCheckTencentTest` /
  `platformCheckBaijiahaoTest` / `rehostFailGateTest`、`atomgitFallbackUrlTest`。

### 真机验证（2026-11-07，v0.3.1 二进制）

| 验证项 | 命令 | 实测结果 |
| --- | --- | --- |
| 头条预检 | `check docs/cjh内嵌接入-发布稿.md --platform toutiao` | `exit 1`，命中「标题字数：当前 44 字，头条要求 5~30 字」+「图片域名：正文 6 张图…7115」 |
| 百家号预检 | `… --platform baijiahao` | `exit 1`，命中标题 8-40 字符、`origin_url` 必填、**封面**（纯外链图不触发放封面） |
| 腾讯云预检 | `… --platform tencent` | `exit 1`，命中标签必填（-9993）与专栏回落 149 的 300031 风险 |
| 专栏/标签查询 | `tags --platform tencent` | `uin 100009199133`；已加入 1 个专栏 `[88542] 独行猫a的沉淀积累总结`；该专栏 **177 个标签**，展示前 12 个并给出 `export` 建议 |
| 图片预演 | `imgs docs/cjh内嵌接入-发布稿.md` | 列出 6 张待转存图（arch-diagram / embed-arch / web-ui / cjnote-ai-panel / ai-chat-agent / embed-brain） |
| 腾讯云草稿留痕 | `publish … --platform tencent --draft`（`CSPUB_TENCENT_CLASSIFY_IDS=88542`、`TAG_IDS=10663,10308`） | 草稿 `draftId 342313`，编辑地址 `…/write?draftId=342313`；图片转存 `成功 6，失败 0`（对照：备用端点生效前 342310/342312 两次均 `成功 0，失败 6`） |

### 文档

- **README 重写**：首屏改为价值定位（「AI 时代的分发层——写完的文章，一条命令发遍十个平台」）+「为什么需要它」对照表
  （凭证一次导出 / 图片按平台转存 / 默认草稿 / 预检挡掉注定失败的提交 / 可交给 agent 跑）；新增「支持的平台」十平台矩阵表
  （鉴权方式 / 图片策略 / 每平台硬约束）与 `check --platform`、`tags`、`--force` 用法；「为什么是仓颉」「为什么自己写」两节合并去重；
  已知限制补「头条号没有草稿通道」「百家号 Cookie 通道需 playwright」。
- **`skills/cspub-publish.md`**：凭证表补齐十家（新增腾讯云 / 语雀 / 头条号 / SegmentFault），补 `tags --platform tencent` 与
  `--force`/`--insecure` 语义、子命令速查表、各平台图片策略表、平台脾气（头条无草稿通道、腾讯云 `tagIds` 必填、
  百家号标题 8-40 字符 + `origin_url`、语雀 namespace 两段、开源中国提交原始 Markdown）、失败速查。
- **`skills/cspub-troubleshoot.md`**：按症状索引重写，补头条 `1050` 重传判据与 `7115` 图片域名、腾讯云 `-9993`/`300031`、
  语雀 namespace `404`、`raw.gitcode.com` 被 CloudWAF 拦 `418` 的备用端点、转存失败门禁、开源中国 `40001`（Cookie 双前缀）等。
- **版本回显统一**：官网 `website/index.html`（`softwareVersion` / 首屏角标 / 页脚）与 `docs/发布与版本维护.md`、
  `src/yuque.cj` 的 `YUQUE_UA` 全部对齐 `0.3.1`。

### 发布产物（v0.3.1）

- `dist/cspub-v0.3.1-linux-x64`（12,232,688 B）与 `dist/cspub-v0.3.1-linux-x64.tar.gz`（4,016,358 B）。
- `dist/cspub-v0.3.1-windows-x64.exe`（8,729,600 B，mingw strip 后）与 `-selfcontained.zip`（17,927,168 B，
  含 `libboundscheck` / `libcangjie-runtime` / `libcrypto-3-x64` / `libssl-3-x64` 四个 DLL）。
- `dist/SHA256SUMS` 四项 `sha256sum -c` 全部 `OK`；产物冒烟 `./cspub-v0.3.1-linux-x64 help` 回显
  `cspub v0.3.1 — 多平台自动发文 CLI`（exit 0）。

## [Unreleased]

新增四个平台通道：腾讯云开发者社区（纯 Cookie）、语雀（官方 OpenAPI v2 + Token）、头条号（模拟后台 mp/agw 接口）、SegmentFault 思否（`/gateway` 网关 + 页面取 Token）。其中**腾讯云已端到端跑通草稿与正式发布**（草稿 `draftId 341903`，正式文章 `articleId 2777717`，均服务端核验）；语雀 / SegmentFault 两家是「实现 + 单测」交付，**端到端发布待凭证**；头条号已端到端跑通（见「未验证」节）。

### 新增

- **腾讯云开发者社区**（`src/tencent.cj`，`--platform tencent`）：改走编辑器自身的 RPC
  `POST /developer/services/ajax/column/article?action=CreateArticleDraft&uin=<uin>`（纯 Cookie、零签名），
  请求体 `{action, payload}`，payload 12 字段（`articleId` / `title` / `content` / `plain` / `columnIds` /
  `tagIds` / `keywords` / `sourceType` / `openComment` / `focusReadTotalAfterFollowAuthor` / `closeTextLink` /
  `classifyIds`）。`uin` 取自 Cookie 的 `uin=o100009199133` 并**去掉前导 `o`**（留 `o` 会被当无效账号）；
  `csrfCode` 实测**可带可不带**（原以为必需）。正文
  `content = base64(urlencode(JSON.stringify(jsonpack.pack(rawDraft))))`，`plain` 同法包纯文本——三层，错一层就 400。
  **旧实现调的 `/developer/api/article/addArticle` 是废弃接口**：该串在前端 bundle 里出现 0 次，参数再全也恒 400，
  这轮整体换掉。`--draft` **现在真存草稿**（回显 `draftId` 与编辑地址），不再冒充 dry-run；
  正文不足 140 字仍按 UTF-8 字符本地拦截，但草稿阶段不拦（实测 6 字符也能存），`classifyIds` 空配置回落 149（技术）。
- **腾讯云图片转存**（`saveTencentHttpImage` / `rehostTencentImages`，namespace `image`）：正文外链图逐张换成
  腾讯云自家图床直链。**实测推翻了「必须 `regionKey` + `bucketConfigKey`」的假设**——payload 只给 `url` 就
  `code:0`，回 `data.url`（`https://developer.qcloudimg.com/operation/attachment/<uid>/<date>-<hash>.png`），
  直连校验 `HTTP 200 / 130318 bytes / PNG 1770x840`；这两个键在 bundle 里只是形参、取不到真实常量，实测省掉不影响，
  所以「等抓包再实现」这一步直接取消。已是 `qcloudimg.com` / `cloud.tencent.com` 的图不重复转；单张失败保留原链接、
  不阻断发文（与其它平台一致）。图片 RPC 的 namespace 是 `image`，与发文的 `column/article` 混用会回 501，故单开一条调用通道。
- **腾讯云正式发布（`CreateArticle`）端到端跑通**（`articleId 2777717`）：`--live` = 建草稿拿到 `draftId` 后再调
  `CreateArticle` 转正。连通后连撞 5 个**字段语义**坑（不是鉴权也不是编码），全部已修并各留一条断言：
  `sourceType` 必须 `1`（传 `0` 回 `-9996 文章来源类型错误`，前端枚举 `ORIGINAL:1/REPRODUCED:2/TRANSLATED:3`）；
  IMAGE entity 的 `data` 必须给 `imageUrl`（只给 Draft.js 惯例的 `src` 会回 `500 …Cannot read property
  'startsWith' of undefined`）；原创**不能**带 `sourceDetail`（带空串回 `400 参数错误`，去掉即通过）；
  `tagIds` 不能为空（回 `-9993 请选择文章标签`）；专栏必须是自己已加入的（默认 `149` 会回 `300031 user not the
  column member`）。新增 `CSPUB_TENCENT_TAG_IDS` 配置（`parseTencentTagIds`），发布前本地校验标签非空并给可行动提示。
  专栏/标签查询在 `column/column` namespace：`FetchJoinedColumnList` / `FetchColumnTags`（不在 `column/article`，用错回 501）。
- **jsonpack 打包器移植**（`src/jsonpack.cj`，284 行）：把 Draft.js 的 `RawDraftContentState` 压成
  `blocks|key|421q5|text|...` 形式。**弃用 `stdx` 的 `JsonObject`**——`getFields()` 返回 `HashMap`、遍历顺序不保证，
  字典会错位；改为自建有序节点树 `JpNode` + `JpDict`（插入顺序的 `strings`/`integers` 双表 + 下标映射），
  保证字典与官方 node 版逐字节一致。单测 `src/jsonpack_test.cj` 对照 node 生成的黄金样本，覆盖空容器 /
  单 block / 多 block / `%|^+ ` 转义。
- **语雀**（`src/yuque.cj`，`--platform yuque`）：走官方 OpenAPI v2 `POST /api/v2/repos/{namespace}/docs`，`X-Auth-Token` 鉴权，Markdown 原样提交（`format: markdown`，不预渲染 HTML）。`--draft` 建成 `public=0` 私密文档（等同草稿），`--live` 用 `CSPUB_YUQUE_PUBLIC` 配置或不传（继承知识库公开性）。`whoami yuque` 真调 `GET /api/v2/user` 联网校验 Token —— 目前唯一能真验凭证的平台。
- `util.cj:utf8CharCount`（按 UTF-8 首字节判界计数，不在汉字中间切开），供腾讯云 140 字校验使用。
- **头条号**（`src/toutiao.cj`，`--platform toutiao`）：无开放 API，模拟后台 `mp/agw` 实测端点——发文
  `POST /mp/agw/article/publish`、图片 `POST /mp/agw/article_material/photo/upload_picture/?type=json&pgc_watermark=1&action=uploadimage&encode=utf-8`
  （multipart 字段 `upfile`）、媒体信息 `GET /mp/agw/media/get_media_info`；鉴权是 Cookie + `X-CSRFToken`
  （默认自动取 cookie 的 `csrf_session_id`，兼容 `csrftoken` / `passport_csrf_token`）。标题按 UTF-8 字符校验 `5~30` 字。
  **这条接口没有「只存草稿」这一档**：`save` 非 0 即提交并发布（`1`/`3`/`4` 等价，后台 `status=6 审核中`
  → `status=3 已发布`、公开页可访问）；`save=0` 是编辑器发布档，要浏览器风控签名（`msToken`/`a_bogus`/
  `tt-anti-token`/`x-secsdk-csrf-token`），脚本重放恒 `7050 保存失败`；`save=2` 回 `5009 发布失败`。
  所以 `--live` = `save=1` 提交（进审核队列），`--draft` 一律不提交（详见「修复」）。
- **头条图片转存管线**（`rehostToutiaoImages` / `uploadToutiaoImage` / `collectImgSrcs` / `rewriteHtmlImgs`）：
  头条是唯一「外链也必须转存」的平台——正文任一非头条域名图片会让整篇被拒 `7115 图片uri非法`。实现为：正文所有
  `<img>` 逐张下载 → multipart 上传头条 CDN → 按 `origin_web_uri` 改写成 `<img src="<头条链接>" web_uri="<头条uri>">`；
  失败张数 > 0 时在提交前明确告警「本次很可能被 7115 拒稿」，不静默照发。
  **端到端实测「图片（头条 CDN）：成功 2，失败 0」**，转存后直链 `curl` 回 `HTTP 200 / PNG 100x100`，
  正文 `<img>` 已带 `web_uri`——这条链路不再有未验证项。
- **SegmentFault 思否**（`src/segmentfault.cj`，`--platform segmentfault`）：走前端自用的 `/gateway` 网关，零签名。发文 `POST /gateway/article`、存草稿 `POST /gateway/draft`（**两个不同端点**，所以 `--draft` 真能落草稿箱）。鉴权是三件套：Cookie + `Token` 头 + `Authorization: Bearer <同值>`，其中 Token **不在 Cookie 里**，发文时从写文章页 `__NEXT_DATA__` 的 `serverData.Token` 实时取（`extractSegmentfaultToken`，未登录时空串即判「Cookie 不是登录态」）。请求必带 `Origin`/`Referer`，否则先被 CSRF 网关挡成 403。正文渲染成 HTML 富文本（`text` 字段），`tags` 传数组；图片需公网 URL，配 `CSPUB_ATOMGIT_TOKEN` 自动转 AtomGit 外链，未配只警告不阻断。错误分诊写死：401=未登录/Token 失效、403=CSRF、404=路径变了（明确提示「不是 Cookie 问题」）。`whoami segmentfault` 会联网 GET `/write` 抠 Token 做真实登录态校验。

### 修复

- `parseYuquePublic` 不再借用「非数字返回 0」的兜底：`0` 在语雀语义里是合法的「私密」，脏配置（如 `abc`）必须走 `-1`（不传该字段），否则会被静默发成私密。首轮单测 `yuquePublicParseTest` 正是因此红。
- **头条号 `7050 保存失败` 的根因是 body 编码，不是缺字段**：同一 URL、同一 Cookie、同一份正文，
  `Content-Type: application/json` → `{"code":7050,"message":"保存失败"}`；换成 `application/x-www-form-urlencoded`
  → `{"code":0,"message":"提交成功"}` + `pgc_id`。`buildToutiaoArticleBody`（JSON）整体换成
  `buildToutiaoArticleForm`（复用 `tencent.cj` 的 `urlEncodeComponent` 逐键值转义），请求头同步改表单类型。
  `Referer` 用 v3 还是 v4、带不带 `X-CSRFToken`、加 `source`/`abstract` 等字段、URL 带不带尾斜杠——四组对照
  **全部仍是 7050**，这条排查线已彻底排除，过程记入 `docs/开发文档与踩坑记录.md` §22。
- **头条 `X-CSRFToken` 兜底键名少一个下划线**：本机这串 Cookie 只有 `csrf_session_id`，旧代码取 `csrf_sessionid`
  永远得到空串（等于把空 CSRF 头发出去）。现按 `csrftoken` → `csrf_session_id` → `passport_csrf_token` 依次取。
- **头条 `--draft` 其实在静默公开发文**：这个坑代价最大。`save=1` 一直被当成「存草稿」，但实测提交后
  后台列表状态是 `status=3 已发布`、`https://www.toutiao.com/article/{pgc_id}/` 回 `HTTP 200`；反过来
  `save=0`（原 `--live`）恒回 `7050 保存失败`——补 `abstract`/`pgc_feed_covers`、改成「先建草稿再按
  pgc_id 提交」的两阶段，分别得到 `7050` 与 `3014 审核中，无法修改`；`save_ugc_draft`（form 与 JSON 都试）
  恒回 `1066 草稿内容为空`。**结论：没有可用的真草稿通道**。现在 `--live` = `save=1` 提交，
  `--draft` **一律不提交**并打印原因，把「要不要公开」交回用户——宁可少一个功能，不可再静默发出去。
- **头条 `save` 取值矩阵（2026-11-06 真机 A/B，补齐上一轮的空白）**：`save=0` → `7050`；
  `save=1`/`save=3`/`save=4` → `code 0` + `pgc_id`，回读文章列表均为 `status=6 审核中`（随后转 `已发布`）；
  `save=2` → `5009 发布失败，请重试`。**`save=0` 的失败不是字段缺失**：按抓包形态带齐整套编辑器字段
  （`source=29`/`extra`/`title_id`/`mp_editor_stat`/`draft_form_data`/`search_creation_info` 等 25 字段）
  与真实草稿 `pgc_id` 仍回 `7050`；再原样补上 `msToken`/`a_bogus` 与 `tt-anti-token`/`x-secsdk-csrf-token`
  也仍是 `7050`——这些是 webmssdk 的一次性风控产物，重放即失效，**脚本无法复现 `save=0`**。
  `save=1/3/4` 这条免风控通路的发现，解释了为什么同一工具里「另存一档就一定发布」。
- **头条草稿箱客观存在，但没有脚本写入通道**：`GET /mp/agw/creator_center/draft_list?type=0&count=20&app_id=1231`
  回 `{"code":0,"draft_list":[…17 条…]}`（`draft_type=2`，`gid` 即 `pgc_id`），
  `GET /mp/agw/article/edit?pgc_id=…&format=json` 能读回草稿正文——这批真草稿全部由**编辑器自动保存**产生。
  `save_ugc_draft` 实测 `draft_type=1` → `1066 草稿内容为空`（`content`/`article_content`/`draft_content`/
  `graphic_content`/`content_html`/`body` 六个键名全试过），`draft_type=2` → `1064 草稿类型参数错误`。
  因此 `--draft` 对头条保持「安全拒绝 + 打印证据」，不冒充能存草稿。
- **`cspub` 回显版本号与实际版本不一致**：`main.cj:usage()` 里硬编码 `v0.2.6`，而 `cjpm.toml` 已是 `0.3.0`，
  跑起来会看到错的版本。已同步为 `0.3.0` 并加注释说明「版本号唯一真相在 `cjpm.toml`，此处仅回显」。
- **头条图片上传的两处硬参数**：`upload_picture` 必须以 `?type=json&...&encode=utf-8` 且**带尾斜杠**的形态请求，
  旧的 `?type=ueditor&...`（无尾斜杠）恒回 `1050 图片上传失败`；请求还必须带 `x-requested-with: XMLHttpRequest`，
  缺了同一张图同样回 `1050`。补齐后同一张图回 `code 0` + `web_uri`。
- **头条上传的成功判据不能只看 `state`**：这份响应是**扁平结构**（无 `data` 包裹），且实测成功时 `state` 可能为空串；
  现改为 `code == 0` 且拿到 `web_uri` 即算成功，`pubUrl` 依次兜底 `url` → `origin_web_url` → `web_url`。

### 文档

- **README 与官网平台清单同步到十家**：README 顶部徽章 `star/new_badge.svg` → `star/badge.svg`；两侧平台清单补齐
  腾讯云开发者社区 / 语雀 / 头条号 / SegmentFault，官网平台矩阵新增 4 张卡片（共 10 张），
  「发遍六个平台」及 `<meta name="description">` / `og:*` / JSON-LD 描述全部改为十平台。
- **官网版本回显对齐 `cjpm.toml`**：`website/index.html` 的 `softwareVersion`、导航 `brand__ver`、页脚三处
  `v0.2.6` → `v0.3.0`；页面内版本串现仅剩 `0.3.0`。
- **README 修三处与实现不符的说明**：腾讯云 `--draft` 是**真存草稿**（旧写「dry-run，无草稿态」）、接口是
  `column/article`（旧写已废弃的 `addArticle`）、`CSPUB_TENCENT_TAG_IDS` 必填且专栏须为自己已加入的；
  `whoami` 已支持任意平台（`yuque`/`segmentfault` 会联网真验）；「图片转存」一节由「只讲 CSDN」改为按平台策略总述；
  用法块补 `imgs` 与 `--platform`。
- **`src/yuque.cj` 的 UA 版本串** `cspub/0.2.6` → `cspub/0.3.0` 并加注释（其余平台 UA 不带版本号）；
  **`docs/发布与版本维护.md`**「当前状态」改为「已发布 v0.2.6 / 待发布 v0.3.0（`cjpm.toml` 已置，未打 tag）」。

### 测试

- `cjpm test` **81 个用例全绿 / FAILED: 0**（本轮腾讯云 15 + jsonpack 4），`cjpm build` **零警告**。
- 官网结构校验：`div` 开合 134/134、`section` 10/10、平台卡片 10 张，页面内版本串只剩 `0.3.0`。
- 头条断言从「JSON 结构」改为「form 字段」：守住 `save=0` / `save=1`、`pgc_id=0`、
  `pgc_feed_covers=%5B%5D`、`content=%3Cp%3Ex%3C%2Fp%3E`（尖括号与斜杠必须转义），并加一条
  `startsWith("{") == false` 把「退回 JSON body」这个已证伪的形态钉死在测试里。
- 腾讯云最强的一条用例拿**线上真包的 base64 原文**当期望值（`tencentContentEncMatchesCaptureTest`）：
  pack → JSON.stringify → urlencode → base64 整条链路只要偏一个字节就红，比「能存进去就算过」硬。

### 未验证（明确标注，不作通过处理）

- 腾讯云**已无未验证项**：草稿（`draftId 341903` / `341905`）、图片转存（回显 `图片（腾讯云图床）：成功 2，失败 0`）、
  正式发布（`articleId 2777717`）三条链路均端到端跑通，证据见上文「新增」与 `docs/多平台发文调研.md` §11.3 的 ⑦。
- 语雀的**端到端发布没有跑**：本机没有语雀 Token。当前交付边界是「请求体构造 + 响应解析 + 错误映射全部有单测覆盖」，**不等于线上真能发出去**。拿到凭证后须真发一篇（先草稿）并回显文档直链才算跑通。
- 头条号**已无未验证项，且实测确认「草稿档」在无浏览器环境下不可实现**：`save=1` 提交后后台列表状态为
  `status=6 审核中` → 数分钟自动转 `status=3 已发布`。**本轮回归实跑**：`--live` 提交
  `pgc_id 7704942273524236826` → 后台先 `审核中` 后 `已发布`，公开页
  `https://www.toutiao.com/article/7704942273524236826/` 回 `HTTP 200 / 72914 bytes`（验完即删）；
  早前的 `.../7704932867448603187/`、`.../7704929083666334258/` 同样 200。
  注意 `/item/<id>/` 是老路径，同日实测**已 404**，`toutiaoArticleUrl` 用的正是 `/article/`。
  图片管线回显「成功 2，失败 0」，转存直链 `curl` 回 `HTTP 200 / PNG 100x100`，正文 `<img>` 已带 `web_uri`
  （反复调试同一篇会触发限流回 `1050`，那是平台行为不是代码 bug）。
  `save` 取值矩阵：`0 → 7050`（补齐 25 个编辑器字段 + 原样风控四件套仍 7050）、`1/3/4 → 提交并发布`、
  `2 → 5009`；`save_ugc_draft` `draft_type=1 → 1066`、`draft_type=2 → 1064`。
  所以「只存草稿」写不进去，`--draft` 已改为拒绝提交（详见「修复」）。
- 头条**同名标题是否判重**未单独验证：本轮 3 篇同名「仓颉多平台发文工具」均提交成功，未触发查重拦截；
  但这不足以证明头条没有查重策略。
- SegmentFault 的**端到端发布没有跑**：本机没有思否登录态。已单测覆盖「token 抠取（含未登录空串与锚点缺失）/ 请求体字段与 tags 数组 / cover 空值不带 / HTML 转义 / 响应解析（字符串错误体、对象、坏 JSON）」。**未经真机验证的三项**：①成功响应体的具体形状——正因未知，成功判据已放宽为「HTTP 200 即视为已提交，抠到 id 才打印」，不会把已发出的文章报成失败；②`tags` 传**标签名数组**（编辑器传入形态），若后端要求标签 id 会回参数错误；③本模块**没有**调用 `/gateway/image` 上传本地图片（multipart 字段名登录后才可知），正文图片统一走 `CSPUB_ATOMGIT_TOKEN` 转 AtomGit 外链。跑通凭证：`--draft` 后草稿箱 <https://segmentfault.com/user/draft> 可见该篇，`--live` 后文章管理 <https://segmentfault.com/user/articles> 可见（思否有审核队列，发布成功≠已公开）。
- **51CTO 未实现**：实测 `POST /blogger/publish` 直接 302 跳登录页，`/blogger/*`、`/api/*` 候选发布路由全 404，首页无 JS bundle——**登录前拿不到发文请求体形状**。按「不写猜测端点」的红线，只在 `docs/多平台发文调研.md` §十留下实测结论与待确认清单，等真实 Cookie 后再做。

## [v0.2.6] - 2026-11-05

修掉三处「静默骗人」的缺陷：图片全失败照发死链、`imgs` 预演把要上传的本地图报成 skip、伴生脚本只有站在仓库根目录才找得到。

### 修复

- **图片全失败不再静默照发**：新增收口门禁 `imagesRemainGate`（`src/images.cj`），csdn / zhihu / juejin / oschina
  四个平台转存后统一判定——正文仍残留本地图片就醒目告警（写清后果与排查方向）；配
  `CSPUB_STRICT_IMAGES=1/true/yes` 时直接中止发布（默认仍是 best-effort 照发，不改既有语义）。
  掘金死链事故（`7704603488899366939`，5/5 图失败仍发出）正是这条缺口的产物。
- **`imgs` 预演不再把本地图报成 `skip (not http)`**：`rehostImages` 的 `/` 分支实际会读文件上传，
  旧标签会让人误判「这张图不会转存」。抽成纯函数 `imgPreviewAction`，本地绝对路径标
  `upload (local file)`。
- **伴生脚本寻径回退**：`scripts/*.py` 原先硬编码相对路径，只有 cspub 仓库根目录能命中
  （百家号曾因此直接报「须在仓库根目录下运行」而失败）。新增 `resolveCompanionScript`（`src/util.cj`）
  按 `CSPUB_SCRIPT_DIR` → 当前目录 → **可执行文件目录向上回溯 5 级** 查找；百家号、掘金两处调用点同步改用。

### 变更

- `hasLocalImages` 由 `localImageCount` 取代（门禁要张数不要布尔），其单测用例迁入新测试，用例不丢。
- 帮助文本补 `CSPUB_STRICT_IMAGES` / `CSPUB_SCRIPT_DIR`；CLI 版本回显修正到与 `cjpm.toml` 一致（原为 v0.2.4）。

### 测试

- `cjpm test` **34 个用例全绿**，新增 `imagePreviewActionTest` / `localImageCountAndGateTest` /
  `companionScriptPathTest`；`cjpm clean && cjpm build` **零警告**。

### 验证（真机铁证）

- **缺陷 2**：`cspub imgs AI时代为什么推荐cj-tauri开发桌面应用.md` 五张本地图全部输出
  `[upload (local file)]`（旧版全部 `skip (not http)`）。
- **缺陷 3**：从**非仓库目录** `/root/test/cj` 执行 `publish … --platform juejin`——旧版此场景找不到
  `scripts/juejin_upload.py`，降级内置 ImageX 会 5 张全失败并发出死链；现靠可执行文件目录回溯命中脚本，
  输出「图片转存：5 张待转，成功 5，失败 0」，建草稿成功 `7704528634183122971`。
- **缺陷 1**：`CSPUB_STRICT_IMAGES=1` + 一张不存在的本地图 → 输出
  `⚠⚠ 图片未转存成功：正文仍有 1 张本地图片（juejin）… 已按 CSPUB_STRICT_IMAGES 中止发布`，
  进程 `exit=1` 且**未创建草稿**（旧版会照发一篇死链文）。
- **CSDN（新 Cookie 复测）**：`cookie_xiao`（2026-11-05 18:32 更新）下默认 TLS 仍报
  `certificate verify failed (134), unknown CA`（Certum 链，见踩坑 §3），加 `--insecure` 后成功发草稿
  **`170146741`**（https://blog.csdn.net/m0_46384600/article/details/170146741）；5 张本地图全部转存到
  `i-blog.csdnimg.cn/direct/…`，直链 `curl` 逐张 **200**：181456 / 95037 / 159044 / 342709 / 478469 字节。
  默认 TLS 那次「图片 0/5 + 发文失败」正好走到本版新增的收口告警：
  `⚠⚠ 图片未转存成功：正文仍有 5 张本地图片（csdn）`——缺陷 1 的修复在真实故障里被触发验证。
  注：CSDN 网关对 `mdeditor/*` 全家族要求 `X-Ca-Key` 签名（仅 `saveArticle` 已签名），草稿正文无法程序化回读。

## [v0.2.5] - 2026-11-05

开源中国 `--live` 正式发布实跑，修掉一处把文章地址拼错的 bug，并记录三条「发布成功≠立刻公开」的平台特性。

### 修复

- **`oschinaArticleUrl` 拼错文章地址**：原实现给 `${OSCHINA_SITE}/u/{userId}/blog/{id}`，实测该路径服务端
  直接 **404**（1548 字节错误页）；正确的 SPA 路由是 `${OSCHINA_SITE}/blog/{id}`。函数签名随之简化为
  `oschinaArticleUrl(id)`（userId 已不再需要），单测断言同步改为实测可用形式。

### 新增

- **README「开源中国：正式发布的三个实测特性」**：正文提交 Markdown 但服务端存 HTML（别预渲染）、
  tags 由平台按正文自动提取（front-matter 写的标签不生效）、文章 URL 形式与 SPA 外壳陷阱。

### 验证

- **正式发布（铁证）**：`publish /tmp/oschina_live.md --platform oschina --live` 输出
  `分类 catalog：6616684（front-matter：工作日志）` / `图片（oschina 图床）：成功 3，失败 0` /
  `发布成功，博客 id 19787222`。发的是 cj-tauri 仓库的带图长文（`docs/cj-tauri-介绍与movie实战.md`，
  3 张本地图共 1.55MB）。
- **正文与图片线上核验（铁证）**：`GET /oschinapi/blog/detail?id=19787222` 回读 `contentType=1`、
  `catalog=6616684`，正文为服务端渲染后的 HTML（`<h2>/<p>`），3 张图已换成
  `oscimg.oschina.net//null/up-<md5>.png`；三张直链浏览器 UA 取回均 `HTTP 200`，大小
  617773 / 705372 / 259509 字节，与源图**逐字节一致**。
- **待确认（未解决）**：公开页面 `https://www.oschina.net/blog/19787222` 用 chromium 渲染得到
  「找不到您访问的页面」（正文长度 113、oscimg 图 0），带登录 Cookie 亦然——文章已入库但未对外可见，
  判断为新号/首篇走人工审核。**该条不构成发布链路失败**，但「发布后多久可见」需过一段时间复验。
- `cjpm build` 零警告；`cjpm test` **32/32 通过**。

## [v0.2.4] - 2026-11-05

新增第六个平台：开源中国（OSCHINA）博客。纯 Cookie HTTP，零浏览器，且直接用它**自带的图床**。

### 新增

- **开源中国发文通道**（`src/oschina.cj`，约 320 行）：走站点编辑器自用的 apiv1（不是要注册应用的官方
  OpenAPI）——`POST /oschinapi/api/draft/save_draft` 存草稿、`POST /oschinapi/blog/web/add` 正式发布，
  正文以 `contentType: 1`（Markdown）原样提交。鉴权只要 Cookie 里的 `oscid`，请求带
  `Referer/Origin: https://www.oschina.net`。
- **自带图床通道**：`POST /oschinapi/upload/img`（multipart 字段 `file`），返回 `oscimg.oschina.net`
  直链；实测 2MB 图片单请求即可，无需分片。图片优先级改为 **平台图床 → AtomGit 外链兜底 → 保留原引用**。
- **`--platform oschina` 分发 + `whoami oschina` 自检**：显示 oscid 字节数、userId/catalog 是否预置、
  privacy 语义与图片通道。
- **分类自动匹配**：`GET /oschinapi/blog_catalog/list_by_user`，front-matter `categories` 名匹配 →
  取账号第一个分类；可用 `CSPUB_OSCHINA_CATALOG` 直接指定。
- **单元测试新增 8 例**（总 32 例全过）：Cookie 登录态判定、数字兜底解析、草稿/发布请求体对账
  （`contentType=1`、`type` 1 原创/4 转载、`draft=0`）、响应解析（草稿 `result.id` / 发布标量 `result` /
  图床 `result` 直链 / 未登录 40001 / 非 JSON 保 -1）、分类三级兜底、标题兜底、本地图检测。

### 修复

- **`parseOschinaResp` 的 code 缺省值**：非 JSON 响应原先被算成 `code=0` 而非 `-1`，会被误判成成功；
  改为 code 字段缺失时保留 `-1`。
- **标题兜底不能用 `stripMarkdown`**：它把多行拼成一行，会把正文前半段当标题；改为逐行取首个非空行
  并剥掉行首 `#/>/- /*` 标记。

### 验证

- **真机草稿（铁证）**：`publish /tmp/oschina_test.md --platform oschina` 输出
  `分类 catalog：6616685（front-matter：日常记录）` / `图片（oschina 图床）：成功 1，失败 0` /
  `草稿已保存，id 3343548`；随后 `GET /api/draft/edit/detail?id=3343548` 回读，正文 Markdown 原样、
  图片已回写为 `https://oscimg.oschina.net//null/up-5792a5fa58f99feee8a4f3a58e7aef54.png`。
- **图床直链可用（铁证）**：浏览器 UA + Referer 取该链接 → `HTTP 200`、`130318` 字节、
  `content-type: image/png`，与源图 `docs/imgs/cspub-flow.png` **逐字节一致**（裸 curl 无 UA 会被
  CDN 返回 146 字节 403，属正常拦截，不是死链）。
- `cjpm build` clean 全量重建 **零警告**；`cjpm test` **32/32 通过**。
- **待补**：`--live` 正式发布未跑（会公开一篇文章，等确认）；`privacy` 字段语义（true 是否=仅自己可见）
  尚未实测确认，故做成 `CSPUB_OSCHINA_PRIVACY` 可配置项，默认 `false`（公开）。

## [v0.2.3] - 2026-11-05

掘金图片改「外链优先」：本地图上传 AtomGit 图床，正文嵌 raw 外链，不再依赖浏览器通道。

### 新增

- **AtomGit 图床外链通道**（`src/atomgit.cj`）：配置 `CSPUB_ATOMGIT_TOKEN` 后，掘金发文前的本地图片改由
  AtomGit 仓库承载——`POST /api/v5/repos/{owner}/{repo}/contents/{path}`（base64 内容 + 分支），
  正文回写 `https://atomgit.com/api/v5/repos/{owner}/{repo}/raw/{path}?ref={branch}`。默认仓库
  `qq8864/images`、分支 `main`、目录 `cspub`（可用 `CSPUB_ATOMGIT_REPO/BRANCH/DIR` 覆盖）。
  令牌走 `Authorization: Bearer` 头，不落 URL（避免被日志带走）。
- **`whoami juejin` 增加图片通道自检行**：显示「外链优先（AtomGit …）」或「平台图床（走 ImageX 浏览器通道）」。
- **单元测试新增 4 例**（总 24 例全过）：raw 外链拼接（含空分支兜底 main）、仓库路径生成（斜杠/空白裁剪、
  扩展名归一、空目录不留前导斜杠）、新建文件请求体对账（含 branch 省略）、`commit.sha` 解析（错误结构与非 JSON 兜底）。

### 变更

- **掘金图片通道改为三级降级**：① AtomGit 外链（配了令牌）→ ② 伴生脚本 `scripts/juejin_upload.py`
  （浏览器通道 ImageX）→ ③ 仓颉内置 ImageX。① 里单张失败自动往 ②③ 降、最终仍失败保留原引用并提示，
  **best-effort 语义不变，不阻断发文**。

### 验证

- **掘金认外链（铁证）**：`https://juejin.cn/post/7704394460696461350` 正文 3 张图全为
  `atomgit.com/api/v5/repos/qq8864/cj-tauri/raw/...?ref=main`，浏览器渲染 `loaded=True`；
  再用 cspub 以 API 建草稿复验（非编辑器手写）：正文外链图 `loaded=True 3120x2080`，草稿 `7704389851194605594`
  → 外链不需要转存到掘金图床。
- **raw 外链匿名可直取**：`.../qq8864/images/raw/cjh/arch-diagram.png?ref=main` → `HTTP 200`
  `content-type: image/jpeg`，210777 字节。
- **降级链真机验证**：故意用无效令牌跑 `publish /tmp/jj_local.md --platform juejin --insecure`
  → 输出 `⚠ AtomGit 令牌无效或权限不足（HTTP 401）` → 依次尝试浏览器通道与内置 ImageX（后者仍报已知的
  `SignatureDoesNotMatch`）→ 最终「保留原引用」且**草稿照常建成** `7704345988459397158`，发文未被阻断。
- **构建**：`cjpm build` 零警告（clean 全量重建），`cjpm test` 24/24 通过（2026-11-05）。
- **待补**：有效令牌下的成功上传尚无真机回显（本机无 AtomGit 令牌），配置 `CSPUB_ATOMGIT_TOKEN` 后需跑一篇
  带本地图文章的草稿确认正文图片渲染。

## [v0.2.2] - 2026-11-05

新增掘金平台（Cookie 两步流，纯 HTTP 零浏览器）。

### 新增

- **掘金图片自动转存（浏览器通道，尽力而为）**：掘金把正文相对路径图片渲染成 `juejin.cn/<路径>` 死链，`--platform juejin` 发文前自动把本地图转存到掘金图床并回写真实 CDN 地址。通道选型：**主通道 = Python 伴生脚本 `scripts/juejin_upload.py` 驱动的真实浏览器上传**（playwright 打开掘金编辑器 → file input 上传 → 拦 `get_img_url` 响应取 `main_url`），拿到的正是编辑器自己会写进正文的同一条地址；副通道 = 仓颉内置 `uploadJuejinImage`（纯 HTTP ImageX 五步链：gen_token → ApplyImageUpload(AWS SigV4) → CRC32 直传 → Commit(best-effort) → get_img_url）作脚本缺失时兜底。单张失败保留原链接并提示，不阻断发文。
  **为什么放弃直调签名（根因铁证，2026-11-05）**：浏览器抓包显示真实 ApplyImageUpload 的 `SignedHeaders` 只有 `x-amz-date;x-amz-security-token`（不含 `host`），query 原序为 `Action,Version,ServiceId`；照抄该组合重放（含字母序/原序、有无 host、GET/POST、签不签 content-sha256、sk 是否 base64 解码、火山原生 HMAC-SHA256 等 10+ 变体）**全部仍被回 `SignatureDoesNotMatch`**，而同一时刻浏览器上传一次成功 → 网关按客户端 TLS 指纹而非签名内容校验。另：`scope` 用令牌内 `LTAccessKeyId` 会改报 `CheckAuthenticationError`，用 `AccessKeyId` 才走到签名比对，说明 AK 本身正确。
  **真机验证**：`publish /tmp/jj_test.md --platform juejin --insecure` 输出「图片转存：1 张待转，成功 1，失败 0」→ 草稿 `7704480304496853043`；浏览器打开该草稿取证，正文图片 `loaded=True 1770x840`，src 为 `p0-xtjj-private.juejin.cn/tos-cn-i-73owjymdk6/...awebp?...`，正文采样为 `![流程图](https://p0-xtjj-private...awebp?policy=...)` → 图片真实渲染，链路打通。
  **注意**：该 CDN 地址对 `curl` 直连返回 403（边缘节点拦非浏览器客户端，`TLB` 页），属防盗链正常行为，不代表图片坏——须以浏览器内 `naturalWidth>0` 判定。代码：`src/juejin.cj` + `scripts/juejin_upload.py`（依赖 python3 + playwright + chromium）。
- **`publish --platform juejin`（见上）**：走 `api.juejin.cn` 两步流——①POST `/content_api/v1/article_draft/create`（`edit_type:10` Markdown 模式）→ draft_id → ②POST `/content_api/v1/article/publish {draft_id}` → article_id → `https://juejin.cn/post/<id>`。写接口实测无需反爬签名（`article/detail` 等读接口才要 msToken+a_bogus）。判成功只看 `err_no==0`（社区实测 `err_msg` 可能恒为 "success"）。坑点处理：`brief_content` 硬性 50-100 字（`normalizeJuejinBrief` 从 front-matter desc 取、不足从正文剥文本补齐）；`category_id` 必须字符串；发布强制至少一个分类与标签（err_no=1002/1003）——未配置时自动拉 `/tag_api/v1/query_category_list`（读接口免签名），分类按 front-matter 名称匹配、标签取所选分类的 `hot_tags` 前 3 个。配置：`CSPUB_JUEJIN_COOKIE`（须含 sessionid）+ 可选 `CSPUB_JUEJIN_UUID/CATEGORY_ID/TAG_IDS`。代码：`src/juejin.cj`。**真机验证（2026-11-05）**：草稿模式回显 draft_id `7704230915765370931`；`--live` 发布 cjh 文章成功回显 `https://juejin.cn/post/7704237589776220186`（分类自动选中「后端」+ 热门标签 3 个自动兜底）。**踩坑**：函数参数不可变（`tagIds = …` 编译报 cannot assign to immutable value），兜底结果须用局部变量承接；cjpm 增量构建可能不重编改动文件（改动后产物 mtime 不变），构建报"成功"实为旧产物——clean 重建才暴露真实编译错误。
- **`whoami juejin`**：校验 Cookie 含 `sessionid` 及可选配置项。

### 构建

- `cjpm build` 零警告；`cjpm test` 20/20 通过（新增 4 例：建草稿/发布请求体对账、摘要 50-100 字规整、err_no 解析含非 JSON 兜底）（2026-11-05）。真机验证待用户掘金 Cookie 后补跑。

## [v0.2.1] - 2026-11-04

新增博客园平台（官方 MetaWeblog API，纯 HTTP 零浏览器）；README 更名为「多平台文章发布助手」。

### 新增

- **`publish --platform cnblogs`**：走博客园官方 MetaWeblog API（XML-RPC，`metaWeblog.newPost`），纯仓颉实现零浏览器。端点 `https://rpc.cnblogs.com/metaweblog/<博客名>`；鉴权用后台「设置 → 允许博客客户端访问」开启后显示的 MetaWeblog 登录名 + 访问令牌（**不是登录密码**）。正文传 Markdown 原文，`categories` 自动带上 `[Markdown]`（缺失时博客园不按 MD 渲染，社区实测坑）；front-matter 的 `categories` 拆分为随笔分类、`tags` 进 `mt_keywords`、`desc` 进摘要。默认草稿（`publish=false`），`--live` 公开发布，回显 postid 与文章链接。配置：`CSPUB_CNBLOGS_BLOG_ID/USERNAME/TOKEN` 或 config.json 的 `cnblogsBlogId/Username/Token`。代码：`src/cnblogs.cj`。
- **`whoami cnblogs`**：校验 blogId/username/token 三项配置。
- **单元测试新增 4 例**（总 16 例全过，`cjpm test`）：XML 转义、XML-RPC dateTime 格式、newPost 请求体对账（含转义/[Markdown]/publish 布尔）、响应 postid 与 fault 解析（含非 XML 兜底）。

### 变更

- **README 定位更新**：标题从「CSDN 自动发文 CLI」改为「多平台文章发布助手」，`cjpm.toml` 描述同步。

### 修复

- **`xmlEscape` 逐字节转码把多字节字符拆成非法 UTF-8**（踩坑记录 2 同款新犯）：改为 `s.runes()` 按 Rune 迭代，中文标题/正文转义不再抛 `IllegalArgumentException: Invalid utf8 byte sequence`。单测 `xmlEscapeTest` 覆盖。

### 构建

- `cjpm build` 零警告；`cjpm test` 16/16 通过（2026-11-04）。端到端真机验证待用户博客园凭证后补跑。

## [v0.2.0] - 2026-11-04

多平台自助发文：新增知乎（Cookie）与百度百家号（开发者凭证）两个平台，`--platform` 分发。

### 新增

- **`publish --platform zhihu`**：知乎无官方发文 API，走 Cookie 模拟 Web 接口三步——①POST `zhuanlan.zhihu.com/api/articles/drafts` 建空草稿 → ②PATCH `/api/articles/{id}/draft` 写标题与渲染后 HTML → ③PUT `/api/articles/{id}/publish` 发布（草稿模式止步②）。鉴权用浏览器登录态 Cookie 整串（须含 `z_c0`），`XSRF-TOKEN` 作 `x-xsrftoken` 头回传。配置：`CSPUB_ZHIHU_COOKIE` 或 `~/.cspub/config.json` 的 `zhihuCookie`。代码：`src/zhihu.cj`。**真机验证（2026-11-04，Cookie 整串无 XSRF-TOKEN 也能通过）**：冒烟文章草稿模式回显 draft id `2101309061220382671`；`--live` 发布回显 `https://zhuanlan.zhihu.com/p/2101309149501976785`（用户确认可见）；正式文章（25KB 鸿蒙移植对比文，含表格/引用/链接）直发成功回显 `https://zhuanlan.zhihu.com/p/2101309879893939156`，`GET zhuanlan.zhihu.com/api/articles/{id}` 取证 `type: article` 且标题/摘要完整。
- **知乎图片自动转存**：知乎保存时剥离非 zhimg.com 图源，`publish --platform zhihu` 发文前自动转存——外链图走 `POST zhuanlan.zhihu.com/api/uploaded_images {url, source:"article"}`（知乎服务端抓取，acedatacloud/skills 生产配方）；本地图走 `POST api.zhihu.com/images {image_hash, source}` 二进制通道（MD5 去重命中直接查 hash，未命中拿 OSS STS token 做 HMAC-SHA1 签名 PUT），draft 临时 URL 归约为 `picx/pic4.zhimg.com/{hash}.{ext}` 长期链接；best-effort，单张失败保留原链接并提示。**踩坑**：响应里的 `access_timestamp` 比 UTC 快 1 小时，直接当 `x-oss-date` 用必 403 `RequestTimeTooSkewed`（MaxAllowedSkew 900s），须用本机当前 UTC 时间（`DateTime.now(timeZone: TimeZone.UTC)`）。**真机验证**：带 2 张本地图的 cjh 文章直发成功 `https://zhuanlan.zhihu.com/p/2101315456896340220`，API 取证正文内图片均为 `zhimg.com` CDN 链接（转存 2/2 成功，含 OSS 签名 PUT 与去重两条路径）。
- **`publish --platform baijiahao`（双通道）**：①官方开发者接口 `builderinner/open/resource/article/publish`（后台「开发 → 基本配置」的 `app_id`+`app_token`；现为**定向邀请制**，有入口才可用）——`origin_url` 按官方必填校验（front-matter 加 `origin_url:`），publish 模式自动取正文第一张图作 `cover_images`（内嵌 JSON 字符串，官方要求），无封面按官方规则落草稿；②**Cookie 浏览器自动化通道**（通用兜底）——纯 Cookie 直调发布接口不可行（React 发布按钮需 `preCheck→paramProxy` 完整事件链，直调 `/rest/2.0/elite/article/publish` 缺 CSRF 必 500，社区可用实现全走浏览器自动化），故 `--platform baijiahao` 在无开发者凭证时自动调起伴生脚本 `scripts/baijiahao_publish.py`（Playwright：Cookie 注入 → 打开编辑页 → 关新手引导与 AI 推广弹窗 → 填标题 → 填正文 → publish 模式经「选择封面」对话框上传本地图 → 点「存草稿/发布」），凭证经临时文件传递用完即删，宿主机需 python3+playwright+chromium。代码：`src/baijiahao.cj` + `scripts/baijiahao_publish.py`。**真机验证（2026-11-04）**：草稿模式存草稿成功（截图取证：标题「cspub 冒烟测试文章」+ 正文标题/加粗/链接/列表/代码块全渲染，字数 88）；`--live` 正式发布带图文章成功（截图取证：「文章发布成功」toast +「提交成功，正在审核中...」页，封面经对话框本地上传）。**踩坑**：新版编辑器是 Lexical（`data-lexical-editor`），标题/正文是两个同名 class 的编辑器（正文=不在 `[data-testid='news-title-input']` 里的那个）；headless 下合成 paste/execCommand 均不生效，逐字键入实测可靠；「确定 (1)」按钮文案带计数须包含匹配；AI 推广弹窗/智能标题气泡/空弹窗包裹层时序不定地拦截点击，须循环关闭并把空包裹层去指针化。
- **`whoami [platform]`**：按平台自检凭证格式（zhihu 验 `z_c0`/`XSRF-TOKEN`，baijiahao 验 app_id/token，csdn 原样验 UserName）。
- **front-matter 新键 `origin_url`**（baijiahao 必填），`src/article.cj` 解析。
- **单元测试 `src/platform_test.cj`**（6 例全过，`cjpm test`）：知乎建草稿/写正文请求体构造、草稿 id 解析（数字/字符串/缺失/非 JSON）、百家号请求体（含 cover_images 内嵌 JSON 回解）、响应 errno 解析、标题长度校验、`origin_url` 解析。

### 变更

- **凭证加载泛化**：`loadConfigString(envName, jsonKey)` 统一环境变量优先 + `~/.cspub/config.json` 兜底，三平台共用；CSDN 行为与报错文案不变。
- **HTTP 执行抽公共助手**：`execRequest`/`applyHeaders`/`HttpResp` 落 `src/util.cj`，TLS 默认 CustomCA（系统根集 + Certum 根追加，与 csdn.cj 同一套），`--insecure` 语义各平台一致。

### 文档

- **平台选型调研结论**：知乎纯 Cookie 可行（草稿接口，社区多实现佐证）；百家号纯 Cookie 直调发布接口不可行（`/rest/2.0/elite/article/publish` 缺 CSRF 参数必 500，社区 Cookie 工具全靠浏览器自动化），故用官方 token 通道。参考资料见 `docs/仓颉资源地址.md`（同批自 cjh 拷入）。

### 构建

- `cjpm build` 零警告；`cjpm test` 6/6 通过（2026-11-04）。端到端真机验证待用户各平台凭证后补跑。

## [v0.1.0] - 2026-11-04

首个 tag 版本：CSDN 自动发文 CLI 全链路端到端跑通（图片转存 + 签名 + 发文 + 原地更新）。

### 新增

- **发文主链路**：读 Markdown + front-matter（title/tags/categories/desc/draft）→ 内置渲染器转 HTML → 网关 HMAC-SHA256 签名（`x-ca-*`，key/secret 取自 CSDN 公开前端 JS，nonce 用 `std.random.nextBytes` 16 字节 hex）→ 携登录 Cookie POST `bizapi.csdn.net` → 回显文章链接与 id。默认发草稿（宁可草稿不误发布），`--live` 直发，`--update <id>` 原地更新。
- **图片自动转存（publish 内置）**：扫描正文图片引用（代码围栏内跳过）→ 分流（CSDN 图床 / `data:` 跳过；内网/回环/链路本地等非公网地址拦截）→ 下载（拒绝 30x 重定向、单张上限 12 MiB）→ CSDN 图床签名接口 → 华为 OBS multipart → 回写 `i-blog.csdnimg.cn` 直链；从后往前回写防偏移挪位；best-effort——单张失败保留原链接并提示，不阻断发文。
- **本地图片直传**：图片引用为本机绝对路径时跳过下载环节，直接上图床。实测：本文数据流图 `cspub-flow.png` 直传成功（`https://i-blog.csdnimg.cn/direct/eb2de994d717446b948a0135ead6176e.png`）。
- **图片处理预演 `cspub imgs`**：只扫描不联网，列出每张图的处理方式（rehost / skip / BLOCKED）。
- **辅助子命令**：`check`（解析 + 渲染统计，不联网）、`html`（打印渲染后 HTML 调试）、`whoami`（校验 Cookie 配置，只验格式不联网）。
- **Cookie 双通道配置**：环境变量 `CSPUB_CSDN_COOKIE`（推荐不落盘）或 `~/.cspub/config.json`（`chmod 600`）。
- **TLS 逃生口 `--insecure`**：TrustAll 跳过证书校验。背景：CSDN 证书链根是 Certum（小众 CA），本机 stdx TLS（1.0.5.1 与 1.2.0.1 两代）默认与 CustomCA 模式均报 unknown CA，而系统 curl 验同链通过，疑 stdx 动态加载 OpenSSL 验证行为问题（已记录待查）。
- **`CSPUB_DEBUG=1` 诊断**：stderr 打图床/发文链路诊断行（请求体积、OBS 状态码与响应首段）。
- **内置 Markdown → HTML 渲染器**：标题/段落/列表/引用/代码围栏/图片/链接/行内代码/加粗；复杂排版（表格/脚注）未覆盖，`cspub html` 目验。
- **示例文章**：`examples-smoke.md` 演示 front-matter 形状。

### 修复

- **OBS 上传"HTTP 200 + 0 字节"空响应**（stdx 1.2.0 适配期发现）：图床签名响应里 `customParam.isAudit` 是 JSON **数字**，用只认字符串的 `jsonStr` 取得空串；空的 `x:isAudit` 发给华为 OBS 得到 200 + 0 字节空文件，表象像"请求被网关吞了"。解法：新增 `jsonScalar` 按 JsonKind 分别取字符串/数字/布尔字面量。修复后端到端验证：图片转存 2/2 成功、发文回显 article id、`--update` 原地更新可用（2026-10-21）。
- **本地图片路径的空响应守卫**：本地路径分支补齐与外链分支相同的空响应检查，防止零字节文件静默上图。

### 兼容性说明

- **stdx 1.2.0 编译适配**：`CertificateVerifyMode` 移至 `stdx.net.tls.common` 子包，需显式 `import stdx.net.tls.common.*` 且变体写限定名；`CustomCA` 收 `Array<Certificate>`（接口）而 `X509Certificate.decodeFromPem` 返回 `Array<X509Certificate>`（类），Array 不协变需显式搬移。源码以 1.2.0 为准，1.0.5.1 下这几处编译不过。

### 构建

- **双平台产物**：Linux `cspub-v0.1.0-linux-x64`（7.1 MB）+ tar.gz（2.3 MB）；Windows 交叉编译 `cspub-v0.1.0-windows-x64.exe`（8.2 MB，mingw strip 后）+ 自包含 zip（exe + libboundscheck / libcangjie-runtime / libcrypto-3-x64 / libssl-3-x64 四 DLL，解压同目录即用）。交叉编译方案沿用 cjh（`scripts/winbuild.sh`：临时替换 link-option 为 `-lcrypt32 -lws2_32`、补 windows target stdx 静态库路径、mingw strip 裁剪、结束恢复基线）；PE 导入表核对：CRYPT32 / KERNEL32 / libcangjie-runtime / msvcrt / SHELL32 / WS2_32，无第三方运行时 DLL 链接。`dist/SHA256SUMS` 覆盖四产物，逐项 OK。
- 新增 `scripts/winbuild.sh`（cjh 同款方案，cspub 适配：link-option 由空串替换填入）。

### 已知限制

- 表格 / 脚注 / 任务列表等扩展 Markdown 不渲染（原样进段落）；
- 未做多平台（掘金/博客园接口形状不同）；
- Windows exe 本机交叉编译产出（导入表核对），未在真机 Windows 实测发文链路；
- CSDN 每日发文限额：单账号每天 1 篇，额度用满时 `saveArticle` 回 `{"code":400300012,...}`，存草稿同样被拒（400300001）——非工具问题，换自然日或换账号。
