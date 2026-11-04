# Changelog

cspub 版本变更记录。版本号规则沿用 cjh：重大更新递增中间位，小更新递增末位；版本号单一真相在 `cjpm.toml` 的 `version` 字段。每条变更须带验证证据（实测输出、错误码、转存结果），不写没有证据的条目。

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
