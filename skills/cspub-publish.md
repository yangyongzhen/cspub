---
name: cspub-publish
description: "cspub 发文操作手册：十平台（CSDN/知乎/掘金/开源中国/博客园/百家号/腾讯云/语雀/头条号/SegmentFault）凭证配置、check/imgs/html/publish/tags/whoami 子命令、--platform/--live/--draft/--force/--update 语义、各平台图片策略与发文前预检清单——用 cspub 发文章或排查发文失败时看这篇"
---

# cspub 发文操作手册

## 凭证配置（env 优先，其次 `~/.cspub/config.json`，后者 `chmod 600`）

| 平台 | 环境变量 | config.json 字段 | 必须包含 / 备注 |
| --- | --- | --- | --- |
| csdn | `CSPUB_CSDN_COOKIE` | `csdnCookie` | 登录 Cookie 整串 |
| zhihu | `CSPUB_ZHIHU_COOKIE` | `zhihuCookie` | `z_c0`（另需 `XSRF-TOKEN`） |
| juejin | `CSPUB_JUEJIN_COOKIE`（+ 可选 `CSPUB_JUEJIN_UUID/CATEGORY_ID/TAG_IDS`） | `juejinCookie` 等 | `sessionid` |
| oschina | `CSPUB_OSCHINA_COOKIE`（+ 可选 `USER_ID/CATALOG/PRIVACY`） | `oschinaCookie` 等 | `oscid` |
| cnblogs | `CSPUB_CNBLOGS_BLOG_ID/USERNAME/TOKEN` | `cnblogs*` | MetaWeblog 令牌（**非登录密码**） |
| baijiahao | `CSPUB_BAIJIAHAO_COOKIE` 或 `CSPUB_BAIJIAHAO_APP_ID/APP_TOKEN` | `baijiahaoCookie` 或 `baijiahaoAppId/AppToken` | `BDUSS`；Cookie 通道另需 python3+playwright+chromium |
| tencent | `CSPUB_TENCENT_COOKIE` + `CSPUB_TENCENT_TAG_IDS`（+ `CSPUB_TENCENT_CLASSIFY_IDS`） | `tencentCookie` / `tencentTagIds` / `tencentClassifyIds` | `skey` 或 `qcommunity_session`；**tagIds 必填**（空回 `-9993`）；专栏须自己**已加入**（否则 `300031`） |
| yuque | `CSPUB_YUQUE_TOKEN` + `CSPUB_YUQUE_NAMESPACE`（+ `CSPUB_YUQUE_PUBLIC`） | `yuqueToken` / `yuqueNamespace` / `yuquePublic` | namespace 必须 `user/repo` 两段，单段必 404 |
| toutiao | `CSPUB_TOUTIAO_COOKIE`（+ 可选 `CSPUB_TOUTIAO_CSRF`） | `toutiaoCookie` / `toutiaoCsrf` | `sessionid` 或 `tt_webid`；CSRF 默认自动取 cookie 的 `csrftoken` |
| segmentfault | `CSPUB_SEGMENTFAULT_COOKIE` | `segmentfaultCookie` | 整串 Cookie；Token 由 cspub 发文时从写文章页实时取 |
| 图片外链（可选） | `CSPUB_ATOMGIT_TOKEN`（+ `REPO/BRANCH/DIR`） | `atomgitToken` 等 | 掘金/思否走外链时用；默认仓 `qq8864/images` · `main` · `cspub` |
| 图片门禁（可选） | `CSPUB_STRICT_IMAGES=1` | — | 转存后仍有本地图就中止（默认 best-effort） |
| 伴生脚本目录（可选） | `CSPUB_SCRIPT_DIR` | — | 百家号/掘金的 `scripts/*.py` 查找根 |

```bash
cspub whoami               # 校验 cspub 默认（csdn）凭证配置，只验格式不联网
cspub whoami segmentfault  # 单平台自检（yuque / segmentfault 会真发一次请求验登录态）
```

> **Cookie 整串直接透传，别二次拼前缀**：`cookie_kaiyuan` 这类文件里存的常是 `oscid=xxx` 整串，
> 再写 `-b "oscid=$(cat file)"` 会得到 `oscid=oscid=…`，服务端判「用户未登录」（code 40001）。

## 运行前补动态库路径（直接跑二进制报 libstdx 缺失时）

```bash
export LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/linux_x86_64_cjnative:<cangjie>/third_party/llvm/lib
```

（官方 `dist/*.tar.gz` 发布的二进制同样需要；这是仓颉运行时动态库路径问题，不是缺功能。）

## 发文标准流程（预检 → 预演 → 草稿 → 发布）

```bash
cspub check   文章.md --platform toutiao    # ① 平台预检：标题字数/图片域名/必填项，不联网，不过返回 1
cspub imgs    文章.md                       # ② 图片预演：每张 rehost / skip / BLOCKED，不联网
cspub publish 文章.md --platform toutiao    # ③ 发草稿（默认）
cspub publish 文章.md --platform toutiao --live          # ④ 公开发布（不可逆，先确认）
cspub publish 文章.md --platform csdn --update <id> --live  # 原地更新（仅 csdn）
cspub publish 文章.md --platform tencent --force         # 图片转存有失败时仍提交
```

`--platform` 必须放在子命令**后面**（写前面会报「未知命令或参数不足」）。省略默认 `csdn`。

## 子命令速查

| 命令 | 作用 | 联网 |
| --- | --- | --- |
| `cspub check <md> [--platform p]` | 解析 front-matter + 渲染统计；带 `--platform` 按该平台规则预检 | 否 |
| `cspub html <md>` | 打印渲染后的 HTML（目验排版） | 否 |
| `cspub imgs <md>` | 预演图片去向 | 否 |
| `cspub publish <md> [--draft\|--live] [--platform p] [--update id] [--force] [--insecure]` | 发文 | 是 |
| `cspub tags --platform tencent` | 查本账号已加入专栏 + 可用标签，直接给 `export` 建议 | 是 |
| `cspub whoami [平台]` | 凭证自检（只验格式；yuque/segmentfault 例外） | 否/是 |

## 各平台图片策略

| 平台 | 顺序 | 备注 |
| --- | --- | --- |
| csdn | 外链 → CSDN 图床 | 站外图直连 200+0 字节，必须转存 |
| zhihu | 转存知乎 CDN | 知乎剥离站外图 |
| toutiao | **全部转存头条 CDN** | 任何非头条域名图 → 整篇拒稿 `7115`；单张失败会自动重传 2 次（`1050` 是瞬时抖动） |
| tencent | 服务端抓链转存 | 交给腾讯云前把 `raw.gitcode.com` 换成 `api.gitcode.com` 端点（raw 被 CloudWAF 拦 418） |
| juejin | AtomGit 外链 → playwright 浏览器 → 内置 ImageX | 配 `CSPUB_ATOMGIT_TOKEN` 即走第一级 |
| segmentfault | 公网 URL（配 AtomGit token 自动转外链） | 私有/内网图会失败 |
| oschina | **平台自带图床** → AtomGit 外链 → 保留原引用 | 有 Cookie 就能传 |
| baijiahao / cnblogs / yuque | best-effort | 单图失败不阻断发文 |

- **转存有失败默认中止**（打印失败清单 + 三条出路），确认要硬发才加 `--force`——头条这类「一张非自家图就整篇拒稿」的平台，明知必败还提交等于白烧每日额度。
- 图片写**本机绝对路径**最稳；Markdown 里相对路径按**当前工作目录**解析。
- 代码围栏内的 `![]()` 是示例文本，自动跳过；单张上限 12 MiB；外链图**拒绝 30x 重定向**；内网/回环地址拦截。
- 排版只保证标题/段落/列表/引用/代码围栏/图片/链接/行内代码/加粗；表格与脚注不渲染。

## 平台脾气（发之前值得知道的硬约束）

- **头条号**：标题 5~30 字；**没有草稿通道**——`--draft` 会拒绝提交并打印原因（`save` 非 0 即发布，`save=0` 需浏览器风控签名），要发就显式 `--live`。
- **腾讯云**：`--live` 正文纯文本 ≥140 字；`tagIds` 必填；专栏必须是自己已加入的（先跑 `cspub tags --platform tencent`）。
- **百家号**：标题 8–40 字符、正文 ≤20000 字符、front-matter `origin_url` 必填；**无本地图则卡封面**。
- **语雀**：Markdown 原样提交（服务端渲染）；`--draft` 建成 `public=0` 私密文档。
- **思否**：正文是 HTML 富文本；`--draft` 存草稿箱、`--live` 直接发布。
- **开源中国**：正文按**原始 Markdown** 提交（`contentType: 1`），服务端自己转 HTML——**不要预渲染**，否则双重转换；front-matter 的 `tags` 不生效，平台按正文关键词自动提取；文章地址 `https://www.oschina.net/blog/{id}`，`/u/{userId}/blog/{id}` 是 404；**发布成功 ≠ 立刻公开**（新号/首篇走审核）。
- **CSDN**：单账号每日 1 篇，**存草稿同算**（`400300012`/`400300001`），不是工具问题。

## front-matter 形状

```markdown
---
title: 必填标题
tags: 逗号分隔,最多5个
categories: 编程
desc: 摘要一行（缺省自动取正文前 200 字）
draft: true         # 缺省 true；publish 时 --live 覆盖
origin_url: ...     # 百家号必填：原文地址/首发链接
---
```

## 失败速查

- `401/403`：Cookie 过期 → 重取；WAF 拦截（403+HTML）→ 换网络过验证码。
- 开源中国 `40001 用户未登录`：Cookie 值重复拼了 `oscid=` 前缀，或 Cookie 里没有 `oscid`。
- `400300012/400300001`：CSDN 每日限额（1 篇/天，草稿同算）→ 换自然日或换账号。
- 腾讯云 `-9993`：缺标签 → 配 `CSPUB_TENCENT_TAG_IDS`；`300031`：专栏不是自己已加入的 → 换 `CSPUB_TENCENT_CLASSIFY_IDS`。
- 头条 `7115 图片uri非法`：正文有非头条域名图；`1050`：单图上传抖动（已自动重传 2 次，仍失败就重跑一次）。
- 语雀 `404`：namespace 只给了一段，必须 `user/repo`。
- TLS 报错：默认模式失败再加 `--insecure`（TrustAll），不要默认带上。
- 图床直链验收：带浏览器 UA 取回并**和源图比字节**；开源中国图链裸 `curl` 无 UA 会被 CDN 403（不是死链）。
- `CSPUB_DEBUG=1` 打开发文链路诊断（请求体积、上游状态码与响应首段）。
