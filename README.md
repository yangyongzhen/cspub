<div align="center">

# cspub

**多平台文章发布助手 —— 用华为仓颉语言实现**

一份 Markdown（带 front-matter），一条命令发到多个平台：CSDN / 知乎 / 百家号，自动签名/登录、自动转存图片、默认发草稿。

[![Language](https://img.shields.io/badge/%E8%AF%AD%E8%A8%80-%E4%BB%93%E9%A2%89%201.0.5%2B-ff69b4)](https://cangjie-lang.cn)
[![License](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-MIT-green)](./LICENSE)
[![Platform](https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-Linux%20%E5%AE%9E%E6%B5%8B-blue)](#已知限制)

</div>

```bash
cspub publish 我的文章.md --platform csdn       # CSDN（Cookie + 网关签名，默认发草稿）
cspub publish 我的文章.md --platform zhihu      # 知乎专栏（Cookie 登录态，图片自动转存知乎 CDN）
cspub publish 我的文章.md --platform baijiahao  # 百家号（Cookie 浏览器通道 / 开发者凭证）
cspub publish 我的文章.md --platform cnblogs    # 博客园（官方 MetaWeblog API，纯 HTTP）
cspub publish 我的文章.md --live                # 直接发布
```

## 它做什么

1. 读 Markdown + front-matter（title / tags / categories / desc / draft / origin_url）；
2. **按平台自动转存图片**：CSDN 外链图转 CSDN 图床（防盗链），知乎图转知乎 CDN（知乎剥离站外图）；
3. 把 Markdown 渲染成 HTML（各平台编辑器都要求发渲染后的 HTML，不是 Markdown 源文）；
4. 按平台鉴权发文：CSDN 走网关 HMAC-SHA256 签名（`x-ca-*`）+ Cookie；知乎走 Cookie 草稿接口三步流；百家号走 Cookie 浏览器自动化（Playwright 伴生脚本）或官方开发者凭证；
5. 回显文章链接与 id（CSDN 支持更新用 `--update <id>`）。

主链路全部用仓颉标准库 + stdx 实现（HMAC / Base64 / HTTP / JSON），零第三方依赖；仅百家号 Cookie 通道需要一个 Playwright 伴生脚本。

## 发文数据流

一条命令背后是六环节流水线，全部自动完成：

![cspub 发文数据流](docs/imgs/cspub-flow.png)

> 源图 `docs/imgs/cspub-flow.svg`（可编辑）。第②步"图片自动转存"的防线细节见下文「图片转存」一节。

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
# Windows 交叉编译：./scripts/winbuild.sh（方案沿用 cjh，产出 exe + 自包含 zip）
```

## 配置凭证（各平台二选一）

| 平台 | 环境变量 | config.json 字段 | 获取方式 |
| --- | --- | --- | --- |
| csdn | `CSPUB_CSDN_COOKIE` | `csdnCookie` | 浏览器登录 → F12 → 复制 Cookie 整串 |
| zhihu | `CSPUB_ZHIHU_COOKIE` | `zhihuCookie` | 登录 zhuanlan.zhihu.com → F12 → 复制 Cookie 整串（须含 `z_c0`） |
| baijiahao | `CSPUB_BAIJIAHAO_COOKIE`（通用）或 `CSPUB_BAIJIAHAO_APP_ID` / `CSPUB_BAIJIAHAO_APP_TOKEN` | `baijiahaoCookie` 或 `baijiahaoAppId` / `baijiahaoAppToken` | ①Cookie：登录 baijiahao.baidu.com → F12 → 复制整串（须含 `BDUSS`）②开发者：后台「开发 → 基本配置」（现为定向邀请制，有入口才可用） |
| cnblogs | `CSPUB_CNBLOGS_BLOG_ID` / `CSPUB_CNBLOGS_USERNAME` / `CSPUB_CNBLOGS_TOKEN` | `cnblogsBlogId` / `cnblogsUsername` / `cnblogsToken` | 后台设置 → 开启「允许博客客户端访问」→ 复制 MetaWeblog 访问地址尾巴（博客名）、登录名与访问令牌（**非登录密码**） |

配置文件：`~/.cspub/config.json`（`chmod 600`），例：
`{"csdnCookie": "...", "zhihuCookie": "...", "baijiahaoCookie": "..."}`

### 环境变量方式（推荐，不落盘）

环境变量与 config.json 二选一即可；**环境变量优先**——同时配置时以环境变量为准（临时换号/测试时不必改配置文件）。

**临时生效**（当前终端会话，关闭即失效）：

```bash
export CSPUB_CSDN_COOKIE='<浏览器 F12 复制的 Cookie 整串>'
cspub publish 我的文章.md --live
```

**持久生效**（写进 shell profile，每次新开终端自动带上）：

```bash
# ~/.bashrc（zsh 用户写 ~/.zshrc）
echo "export CSPUB_CSDN_COOKIE='<Cookie 整串>'" >> ~/.bashrc
source ~/.bashrc

# 多平台就各写一行
echo "export CSPUB_ZHIHU_COOKIE='<Cookie 整串>'" >> ~/.bashrc
```

> Cookie 整串含空格与分号，写 profile 时务必用单引号包裹（单引号内 shell 不展开，原样存为变量值）；
> Cookie 过期后重取整串，`sed -i` 定向替换旧行或重新 `echo >>` 即可。

**安全提示**：环境变量对同机其他进程可见（`/proc/<pid>/environ`），共享机器建议改用 config.json + `chmod 600`；个人机器两者皆可。

> 百家号双通道：纯 Cookie 直调其发布接口不可行（React 发布按钮需完整事件链，直调 API 缺 CSRF 必 500），所以 **Cookie 通道走浏览器自动化**——`--platform baijiahao` 自动调起 `scripts/baijiahao_publish.py`（Playwright 填表单 + 点发布），宿主机需 `pip install playwright && playwright install chromium`；配置了开发者凭证则优先走官方 token 接口。

`cspub whoami [csdn|zhihu|baijiahao]` 校验凭证是否就位（只验格式不联网）。

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

## 版本维护

- **版本号**：`cjpm.toml` 的 `version` 字段是单一真相；发版时同步更新 `CHANGELOG.md`，规则沿用 cjh——重大更新递增中间位、小更新递增末位。
- **变更记录**：`CHANGELOG.md` 按 Keep a Changelog 风格维护（新增 / 变更 / 修复 / 文档 / 构建 分节），每条带验证证据（实测输出、错误码、转存结果），不写没有证据的条目。
- **发布流程**：`cjpm build` → 产物入 `dist/`（tar.gz + SHA256SUMS）→ 打 tag（`v0.1.0` 格式）→ 基于 tag 发 release 并附产物。详见 `docs/发布与版本维护.md`。
- **开发规范**：见 [AGENTS.md](./AGENTS.md)——变更交付门禁、代码组织原则、踩坑沉淀与文档规范。

## 已知限制

- 表格 / 脚注 / 任务列表等扩展 Markdown 不渲染（原样进段落）；
- 更新文章只支持 `--update <id>`（id 在首次发布成功后回显）；
- 未做多平台（掘金/博客园接口形状不同，要了再加）；
- **Windows 侧**：`./scripts/winbuild.sh` 交叉编译产出 exe（8.2 MB，mingw strip 后）+ 自包含 zip（exe + libboundscheck / libcangjie-runtime / libcrypto-3-x64 / libssl-3-x64 四 DLL，解压同目录即用）；发文链路未在真机 Windows 实测；
- **CSDN 每日发文限额**：实测该账号每天只能发 1 篇，额度用满时 `saveArticle` 直接回
  `{"code":400300012,"msg":"今天发表文章数量已达到限制的1篇。"}`；存草稿（`status=2` / `pubStatus=draft`）
  同样被拒（错误码 400300001）——这不是工具问题，换自然日或换账号即可；
- 上传/发文链路已端到端跑通（2026-10-21）：图片转存 2/2、发文成功回显 article id、`--update <id>` 原地更新可用。
