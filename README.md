<div align="center">

# cspub

**CSDN 自动发文 CLI —— 用华为仓颉语言实现**

一份 Markdown（带 front-matter），一条命令发成 CSDN 文章：自动签名、自动把外链图转存到 CSDN 图床、默认发草稿。

[![Language](https://img.shields.io/badge/%E8%AF%AD%E8%A8%80-%E4%BB%93%E9%A2%89%201.0.5%2B-ff69b4)](https://cangjie-lang.cn)
[![License](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-MIT-green)](./LICENSE)
[![Platform](https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-Linux%20%E5%AE%9E%E6%B5%8B-blue)](#已知限制)

</div>

```bash
cspub publish 我的文章.md          # 默认发草稿（宁可草稿也不误发布）
cspub publish 我的文章.md --live  # 直接发布
```

## 它做什么

1. 读 Markdown + front-matter（title / tags / categories / desc / draft）；
2. **自动转存外链图**到 CSDN 图床（CSDN 对站外图有防盗链，外链图直接发会显示不出来）；
3. 把 Markdown 渲染成 HTML（CSDN 编辑器要求发渲染后的 HTML，不是 Markdown 源文）；
4. 按 CSDN 编辑器前端的同款算法做网关 HMAC-SHA256 签名（`x-ca-*`），带着你的登录 Cookie 发到 `bizapi.csdn.net`；
5. 回显文章链接与 id（更新用 `--update <id>`）。

全部用仓颉标准库 + stdx 实现（HMAC / Base64 / HTTP / JSON），零第三方依赖。

## 为什么是仓颉

这是个真实场景练手项目：华为仓颉的 stdx 恰好齐活一条「HTTP 客户端 + HMAC 签名 + JSON」链路，
够写一个正经的 CLI 工具。实现过程的坑（HMAC 对账、TLS 信任、UTF-8 字节语义、struct 可变性）
都记录在文末「实现要点」里，对写仓颉网络程序有直接参考价值。

## 为什么自己写

CSDN 的编辑器接口（`bizapi.csdn.net/blog-console-api/v3/mdeditor/saveArticle`）走**阿里云 API 网关风格的 HMAC-SHA256 签名**（`x-ca-*` 请求头），key/secret 烙在 CSDN 公开的前端 JS 里；账号凭据只需要你自己的登录 Cookie。整个工具就是：读文件 → 解析 front-matter → Markdown 渲染成 HTML → 签名 → POST。仓颉 1.2.0 的 stdx（`stdx.crypto.digest` HMAC、`stdx.encoding.base64`、`stdx.net.http`）恰好齐活，不用任何外部依赖。

## 构建

```bash
export CANGJIE_STDX=<stdx>/dynamic/stdx      # 1.2.0 配套的 stdx
export PATH=$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH
cjpm build
# 产物：target/release/bin/main
```

## 配置 Cookie（二选一）

1. 环境变量（推荐，不落盘）：`export CSPUB_CSDN_COOKIE='<浏览器复制的 Cookie 整串>'`
2. 配置文件：`~/.cspub/config.json` 写 `{"csdnCookie": "..."}`（`chmod 600`）

Cookie 获取：浏览器登录 CSDN → F12 → 任一 `blog.csdn.net` 请求 → 复制请求头里 Cookie 的整串。
`cspub whoami` 校验配置是否就位（解析 UserName/UserNick，只验格式不联网）。

## 用法

```
cspub check   <文章.md>            解析 front-matter + 渲染统计（不联网）
cspub html    <文章.md>            打印渲染后的 HTML（调试用）
cspub publish <文章.md> [--draft]  发草稿（默认）
                   [--live]        直接发布（覆盖 front-matter 的 draft: true）
                   [--update <id>] 原地更新指定文章
                   [--insecure]    跳过 TLS 证书校验（TrustAll，仅诊断/自担风险）
cspub whoami                       校验 Cookie 配置
cspub help
```

环境变量 `CSPUB_DEBUG=1`：往 stderr 打图床/发文链路的诊断行（请求体积、OBS 状态码与响应首段），
排查上传异常时用；正常使用无需设置。

## 图片转存（publish 自动做）

CSDN 对站外图有防盗链（典型形状：`<img>` 直连返回 **HTTP 200 + 0 字节**）。`publish` 在发文前**自动**把
站外图转存到 CSDN 图床（csdnimg.cn）并回写 URL：

1. 扫描正文图片引用（代码围栏内跳过）；
2. 分流：已是 CSDN 图床 / `data:` 的跳过；内网、回环、链路本地等非公网地址**拦截**（防把本机内网服务当图源）；
3. 下载（**拒绝 30x 重定向**——重定向可能把请求带到没检查过的主机；单张上限 12 MiB）；
4. CSDN 图床签名接口（网关 HMAC + Cookie）→ 华为 OBS multipart（policy 授权）→ 回调返回 csdnimg.cn URL；
5. 从后往前回写 Markdown（偏移不挪位）；**best-effort**：单张失败保留原链接并提示，不阻断发文。

发文前可先 `cspub imgs <文章.md>` 预演：只扫描不联网，列出每张图会被如何处理（rehost / skip / BLOCKED）。

**已验证（2026-10-21）**：一篇带 2 张 `raw.githubusercontent.com` 外链图的真实文章，转存 2/2 成功，
回写后的链接形如 `https://i-blog.csdnimg.cn/direct/<hash>.png`，发文后正文图片正常显示。

**这条链路的坑（值得记一笔）**：图床签名响应里 `customParam.isAudit` 是 **JSON 数字**，用只认字符串的
`jsonStr` 去取会得空串；把空的 `x:isAudit` 发给华为 OBS，OBS 回的是 **HTTP 200 + 0 字节**——看起来像
"被网关吞了"，实际是回调拿不到字段。改法是 `jsonScalar`：按 JsonKind 分别取字符串/数字/布尔字面量。

## front-matter

```markdown
---
title: 文章标题            # 必填
tags: 仓颉, 工具           # 逗号/顿号分隔，最多 5 个（API 上限）
categories: 编程
desc: 摘要一行             # 缺省从正文剥 Markdown 取前 200 字
draft: true                # 缺省 true；publish 时 --live 可覆盖
---

正文 Markdown……
```

## 实现要点（也是坑）

- **content 必须是渲染后的 HTML**：直接发 Markdown 原文，CSDN 页面显示字面 `##` 与 `![]()`。
  内置了一个**够用即可**的 Markdown → HTML 渲染器（标题/段落/列表/引用/代码围栏/图片/链接/行内代码/加粗），
  复杂排版（表格、脚注）未覆盖——要用就先 `cspub html` 目验。
- **HMAC 对账**：签名实现用 Python `hmac+sha256` 逐字节对过账；nonce 用随机 16 字节 hex（`std.random.nextBytes`）。
- **UTF-8 安全**：摘要截断按首字节判界（`(b & 0xC0) != 0x80`），不在汉字中间切开；行内渲染按区间整体转码，
  不逐字节 append（逐字节会把汉字拆成非法序列）。
- **外链图必须先转存**：CSDN 对站外图有防盗链（典型形状 200 + 0 字节）；`publish` 已内置自动转存
  （见「图片转存」一节），2026-10-21 用真实文章端到端验证通过。
- **Cookie 会过期**：401/403 时工具会提示重取；WAF 若拦截（403 + HTML），换网络/重新过验证码再试。
- **TLS 信任的已知问题**：CSDN 的证书链根是 Certum（小众 CA），实测本机 stdx TLS（1.0.5.1 与 1.2.0.1
  两代）默认模式与 CustomCA 模式（内嵌逐字节一致的 Certum 根）都报 unknown CA，而系统 curl 验同一条链
  通过——疑 stdx 动态加载的 OpenSSL 验证行为问题（已记录待查）。`--insecure`（TrustAll）是逃生口：
  探针已用它验证签名/请求形状可过网关（401 = 只缺登录 Cookie）。正式发文先试默认模式，失败再加
  `--insecure`（HTTPS 内容仍加密，只是不验服务器身份，风险自担）。
- **stdx 1.2.0 的编译差异**：`CertificateVerifyMode` 已移到 `stdx.net.tls.common` 子包，需显式
  `import stdx.net.tls.common.*`、变体写限定名（`CertificateVerifyMode.TrustAll` / `CertificateVerifyMode.CustomCA`）；
  且 `CustomCA` 收的是 `Array<Certificate>`（接口），而 `X509Certificate.decodeFromPem` 返回
  `Array<X509Certificate>`（类）——Array 不协变，得显式搬一次。源码以 1.2.0 为准，1.0.5.1 下这几处编译不过。

## 已知限制

- 表格 / 脚注 / 任务列表等扩展 Markdown 不渲染（原样进段落）；
- 更新文章只支持 `--update <id>`（id 在首次发布成功后回显）；
- 未做多平台（掘金/博客园接口形状不同，要了再加）；
- **Windows 侧未实测**（stdx http 在 Linux 验证；理论上可交叉编译）；
- **CSDN 每日发文限额**：实测该账号每天只能发 1 篇，额度用满时 `saveArticle` 直接回
  `{"code":400300012,"msg":"今天发表文章数量已达到限制的1篇。"}`；存草稿（`status=2` / `pubStatus=draft`）
  同样被拒（错误码 400300001）——这不是工具问题，换自然日或换账号即可；
- 上传/发文链路已端到端跑通（2026-10-21）：图片转存 2/2、发文成功回显 article id、`--update <id>` 原地更新可用。
