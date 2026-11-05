---
name: cspub-publish
description: "cspub 发文操作手册：多平台（CSDN/知乎/百家号/博客园/掘金/开源中国）Cookie 配置、publish/check/imgs/html/whoami 子命令、--platform/--live/--update 语义、各平台图片策略与发文前预演清单——要用 cspub 发文章或排查发文失败时看这篇"
---

# cspub 发文操作手册

## Cookie 配置（各平台二选一：env 或 ~/.cspub/config.json，后者 chmod 600）

| 平台 | 环境变量 | config.json 字段 | 必须包含 |
| --- | --- | --- | --- |
| csdn | `CSPUB_CSDN_COOKIE` | `csdnCookie` | 登录 Cookie 整串 |
| zhihu | `CSPUB_ZHIHU_COOKIE` | `zhihuCookie` | `z_c0` |
| baijiahao | `CSPUB_BAIJIAHAO_COOKIE` | `baijiahaoCookie` | `BDUSS`（另需 python3+playwright+chromium） |
| cnblogs | `CSPUB_CNBLOGS_*`（BLOG_ID/USERNAME/TOKEN） | `cnblogs*` | MetaWeblog 令牌（非登录密码） |
| juejin | `CSPUB_JUEJIN_COOKIE` | `juejinCookie` | `sessionid` |
| oschina | `CSPUB_OSCHINA_COOKIE` | `oschinaCookie` | `oscid` |

```bash
cspub whoami            # 校验 CSDN 配置（只验格式不联网）
cspub whoami oschina    # 单平台自检：凭证、userId/catalog 是否预置、图片通道
```

> **Cookie 文件直接透传，别二次拼前缀**：`cookie_kaiyuan` 这类文件里存的常是 `oscid=xxx` 整串，
> 再写 `-b "oscid=$(cat file)"` 会得到 `oscid=oscid=…`，服务端判「用户未登录」（code 40001）。

## 运行前补动态库路径（直接跑二进制报 libstdx 缺失时）

```bash
export LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/linux_x86_64_cjnative:<cangjie>/third_party/llvm/lib
```

## 发文标准流程（先预演后发文）

```bash
cspub imgs    文章.md                          # 预演：每张图 rehost/skip/BLOCKED，不联网
cspub check   文章.md                           # 校验 front-matter + 渲染统计
cspub publish 文章.md --platform oschina        # 默认存草稿
cspub publish 文章.md --platform oschina --live # 正式发布
cspub publish 文章.md --platform csdn --update <id> --live   # 原地更新
```

`--platform` 必须放在子命令**后面**（写前面会报「未知命令或参数不足」）。省略 `--platform` 默认 csdn。

## 各平台图片策略

| 平台 | 顺序 | 备注 |
| --- | --- | --- |
| csdn | 外链 → CSDN 图床 | 站外图直连 200+0 字节，必须转存 |
| zhihu | 转存知乎 CDN | 知乎剥离站外图 |
| juejin | AtomGit 外链 → playwright 浏览器 → 内置 ImageX | 配 `CSPUB_ATOMGIT_TOKEN` 即走第一级 |
| oschina | **平台自带图床** → AtomGit 外链 → 保留原引用 | 有 Cookie 就能传，无需额外配置 |
| baijiahao / cnblogs | 见各自伴生脚本/接口 | best-effort，单图失败不阻断发文 |

- 图片写**本机绝对路径**最稳（跳过下载直接上图床）；Markdown 里相对路径按**当前工作目录**解析。
- 代码围栏内的 `![]()` 是示例文本，自动跳过；单张上限 12 MiB，外链图拒绝 30x 重定向。
- 排版只保证标题/段落/列表/引用/代码围栏/图片/链接/行内代码/加粗；表格与脚注不渲染。

## 开源中国专属要点

- 正文按**原始 Markdown** 提交（`contentType: 1`），服务端自己转 HTML——**不要预渲染**，否则双重转换。
- front-matter 的 `tags` 不生效，平台按正文关键词自动提取；`categories` 按名字匹配账号分类，匹配不到取第一个。
- 文章地址是 `https://www.oschina.net/blog/{id}`；`/u/{userId}/blog/{id}` 是服务端 404。
- **发布成功 ≠ 立刻公开**：接口回 id、`blog/detail` 能读到正文，但公开页可能仍是「找不到您访问的页面」
  （新号/首篇走审核），过段时间复验。判可见性只能靠浏览器渲染，`curl` 一律 200 没信息量。
- `CSPUB_OSCHINA_PRIVACY=true` 可切私密，但该字段语义未实测确认，默认公开。

## front-matter 形状

```markdown
---
title: 必填标题
tags: 逗号分隔,最多5个
categories: 编程
desc: 摘要一行（缺省自动取正文前 200 字）
draft: true    # 缺省 true；--live 覆盖
---
```

## 失败速查

- `401/403`：Cookie 过期 → 重取；WAF 拦截（403+HTML）→ 换网络过验证码。
- 开源中国 `40001 用户未登录`：Cookie 值重复拼了 `oscid=` 前缀，或 Cookie 里没有 `oscid`。
- `400300012/400300001`：CSDN 每日限额（1 篇/天，草稿同算）→ 换自然日或换账号，不是工具问题。
- TLS 报错：默认模式失败再加 `--insecure`（TrustAll），不要默认带上。
- 图床直链验收：带浏览器 UA 取回并**和源图比字节**；开源中国图链裸 `curl` 无 UA 会被 CDN 403（不是死链）。
- `CSPUB_DEBUG=1` 打开发文链路诊断（请求体积、上游状态码与响应首段）。
