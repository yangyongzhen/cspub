# Changelog

cspub 版本变更记录。版本号规则沿用 cjh：重大更新递增中间位，小更新递增末位；版本号单一真相在 `cjpm.toml` 的 `version` 字段。每条变更须带验证证据（实测输出、错误码、转存结果），不写没有证据的条目。

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

### 已知限制

- 表格 / 脚注 / 任务列表等扩展 Markdown 不渲染（原样进段落）；
- 未做多平台（掘金/博客园接口形状不同）；
- Windows 侧未实测（stdx http 在 Linux 验证）；
- CSDN 每日发文限额：单账号每天 1 篇，额度用满时 `saveArticle` 回 `{"code":400300012,...}`，存草稿同样被拒（400300001）——非工具问题，换自然日或换账号。
