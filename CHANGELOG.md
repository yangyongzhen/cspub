# Changelog

cspub 版本变更记录。版本号规则沿用 cjh：重大更新递增中间位，小更新递增末位；版本号单一真相在 `cjpm.toml` 的 `version` 字段。每条变更须带验证证据（实测输出、错误码、转存结果），不写没有证据的条目。

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
