---
title: 我用仓颉写了个多平台发文工具：一份 Markdown，一条命令发六个平台
tags: 仓颉,CLI工具,自动化,多平台发布,效率工具
categories: 编程
desc: cspub 是用华为仓颉实现的多平台发文 CLI——一份带 front-matter 的 Markdown，自动完成图片转存、HTML 渲染、网关签名与发布，支持 CSDN、知乎、百家号、博客园、掘金、开源中国六个平台，主链路零第三方依赖。
draft: true
origin_url: https://blog.csdn.net/m0_46384600/article/details/170149773
---

# 我用仓颉写了个多平台发文工具：一份 Markdown，一条命令发六个平台

写技术文章的人大概都有过这个体验：文章在本地 Markdown 里写得干干净净，往编辑器里一贴——图片全裂了。

CSDN 对站外图片有防盗链，`<img>` 直连外部图床时返回的是 **HTTP 200 + 0 字节**。状态码看着挺好，页面上却只剩一个占位框。于是流程变成：下载图片、逐张上传、替换链接、重新检查排版。文章五分钟写完，图片折腾半小时。

后来我开始了"一稿多投"的折腾：同一篇文章要发到 CSDN、知乎、掘金、开源中国、百家号、博客园，每个平台的编辑器各有各的脾气，图片策略各不相同，有的要传它自己的图床，有的会悄悄把站外图剥掉。六个平台贴六遍，一晚上就没了。

于是我给自己写了个工具，叫 **cspub**。

## 它到底是什么

一句话：**一份 Markdown（带 front-matter），一条命令发到一个平台；写六条命令就是六个平台。**

```bash
cspub publish 我的文章.md --platform csdn       # CSDN（Cookie + 网关签名，默认发草稿）
cspub publish 我的文章.md --platform zhihu      # 知乎专栏（Cookie 登录态，图片转知乎 CDN）
cspub publish 我的文章.md --platform baijiahao  # 百家号（Cookie 浏览器通道 / 开发者凭证）
cspub publish 我的文章.md --platform cnblogs    # 博客园（官方 MetaWeblog API，纯 HTTP）
cspub publish 我的文章.md --platform juejin     # 掘金（Cookie 两步流，图片外链优先）
cspub publish 我的文章.md --platform oschina    # 开源中国（Cookie 直通站点接口）
```

参数就两个是常用的：`--draft`（默认，发草稿）和 `--live`（直接公开）。CSDN 老文章要改内容，用 `--update <id>` 原地更新，不用重新发。

它不是那种"帮你调 API"的薄壳子。一条命令背后是六个环节：

![cspub 发文数据流](https://yangyongzhen.github.io/cspub/assets/imgs/cspub-flow.png)

1. 读 Markdown + front-matter（title / tags / categories / desc / draft）；
2. **按平台转存图片**——CSDN 转 CSDN 图床，知乎转知乎 CDN，开源中国用它自带图床；
3. 把 Markdown 渲染成 HTML（各平台编辑器要的都是渲染后的 HTML，不是 Markdown 源文）；
4. 按平台鉴权发文：CSDN 走阿里云 API 网关风格的 HMAC-SHA256 签名，知乎走 Cookie 草稿三步流，博客园走 MetaWeblog；
5. 回显文章链接和 id。

## 为什么用仓颉写

不是因为要蹭热度，纯粹是刚好够用且我想真练一次。

仓颉的 stdx 恰好齐活一条「HTTP 客户端 + HMAC 签名 + Base64 + JSON」链路：`stdx.net.http` 发请求、`stdx.crypto.digest` 算 HMAC、`stdx.encoding.base64` 编解码、`stdx.encoding.json` 解析响应。这四个拼起来正好是一个正经 CLI 工具需要的全部，加上标准库的文件读写和字符串处理，**主链路零第三方依赖**。

对写过网络程序的人来说这点挺爽的：没有依赖树要维护，没有版本冲突要处理，`cjpm build` 出来就是个可执行文件。

（顺带说，整个项目是在我的另一个开源项目 [cjh](https://atomgit.com/qq8864/cjh)——一个用仓颉从零实现的终端 Coding Agent——里开发出来的。后面我会单独写一篇讲这件事，那可能比工具本身更有意思。）

## 装它

需要仓颉 SDK 1.0.5 或以上，外加配套的 stdx：

```bash
git clone https://atomgit.com/qq8864/cspub.git
cd cspub

export CANGJIE_STDX=<你的 stdx>/dynamic/stdx
export PATH=$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH

cjpm build
# 产物：target/release/bin/main
```

跑起来需要把 stdx 的动态库路径带上：

```bash
export LD_LIBRARY_PATH=$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative
./target/release/bin/main help
```

Windows 想交叉编译的话仓库里有 `./scripts/winbuild.sh`，产出 exe 加一个自包含 zip。

## 配置凭证：这是唯一麻烦的一步

六个平台的鉴权方式没有一个是统一的，这是整件事里最烦的部分，我没法帮你消除，只能帮你省事。

先说结论：**用 cookie-export 工具提取，别手抄。**

登录态里最关键的那几个字段——知乎的 `z_c0`、掘金的 `sessionid`、CSDN 的 `UserToken`——绝大多数是 **httpOnly**，`document.cookie` 根本读不到。F12 里手抄还容易漏字段、少分号，抄完发现 401，再回去猜是哪个字段错了。

![cookie-export 工具界面](https://yangyongzhen.github.io/cspub/assets/imgs/cookie-export-tool.png)

`cookie-export` 是我在 [cj-tauri](https://atomgit.com/qq8864/cj-tauri) 仓库里写的桌面小工具：内嵌浏览器登录一次，点「提取」它按各平台字段硬需求逐项校验，缺哪个字段直接点出来（比如「已提取，但缺必需字段：UserToken」），点「导出」写进 `~/.cspub/config.json` 并 `chmod 600`。全程本机运行，不上报任何 cookie。

不想用工具也行，环境变量和配置文件二选一，**环境变量优先**：

```bash
export CSPUB_CSDN_COOKIE='<浏览器 F12 复制的 Cookie 整串>'
export CSPUB_ZHIHU_COOKIE='<须含 z_c0>'
export CSPUB_JUEJIN_COOKIE='<须含 sessionid>'
export CSPUB_OSCHINA_COOKIE='<须含 oscid>'
export CSPUB_BAIJIAHAO_COOKIE='<须含 BDUSS>'

cspub whoami csdn      # 只验格式不联网，先确认字段齐了
```

博客园是个例外，它不用 cookie，走官方 MetaWeblog：后台「设置 → 允许博客客户端访问」，拿博客名、登录名和访问令牌（**注意是访问令牌，不是登录密码**），填 `CSPUB_CNBLOGS_BLOG_ID` / `CSPUB_CNBLOGS_USERNAME` / `CSPUB_CNBLOGS_TOKEN`。

Cookie 会过期，过期了就是 401/403，工具会提示你重取。这没办法，各平台就是这样。

## 一篇文章长什么样

front-matter 就五个字段，都很直白：

```markdown
---
title: 文章标题            # 必填，其他平台也靠它
tags: 仓颉, 工具           # 逗号或顿号分隔，最多 5 个（API 上限）
categories: 编程
desc: 摘要一行             # 不写就从正文剥掉 Markdown 取前 200 字
draft: true                # 缺省 true，publish 时 --live 或 draft: false 可覆盖
---

正文 Markdown……
```

写完先跑一遍 `cspub check`，它不联网，只告诉你 front-matter 解析结果和渲染统计，比如有多少个标题、多少张图、多少行代码块。要肉眼确认渲染效果就用 `cspub html`，直接把 HTML 打到终端。

这两个命令看起来很朴素，但帮我省了很多次"发出去才发现排版炸了"。

## 六个平台的脾气，我都试过了

同样是"发文章"，六个平台的实现路径完全不同：

- **CSDN**：走它编辑器自己的接口 `bizapi.csdn.net/blog-console-api/v3/mdeditor/saveArticle`，请求要带**阿里云 API 网关风格的 HMAC-SHA256 签名**（`x-ca-*` 头），key/secret 就烙在 CSDN 公开的前端 JS 里，你只需要自己的登录 Cookie。正文必须是渲染后的 HTML。
- **知乎**：Cookie 草稿接口三步流，图片必须转知乎自己的 CDN——知乎会剥掉站外图，这跟 CSDN 是两种脾气（一个是防盗链不显示，一个是直接去掉）。
- **掘金**：Cookie 两步流，**接受外链图片**（我实测过 API 建草稿后外链图 `naturalWidth>0`），所以不必把图搬进掘金图床。
- **开源中国**：直接打它站点的 `apiv1`，只要 Cookie 就能用。它有自己的图床（`/oschinapi/upload/img`），登录了就能传，所以图片优先走它自己的。
- **百家号**：这个是唯一必须开浏览器的。纯 Cookie 直调它的发布接口不可行——React 发布按钮需要完整事件链，直调 API 缺 CSRF 一律 500。所以 Cookie 通道走 Playwright 自动化填表单，另外官方也给了开发者凭证通道（目前是定向邀请制）。
- **博客园**：最省心的一个，官方 MetaWeblog API，纯 HTTP，不需要浏览器也不需要签名。

有意思的是，越是"大厂"的平台，接口越是反直觉。CSDN 的签名看着唬人，其实逻辑很干净；百家号反过来，接口看着简单，实际上非走浏览器不可。

## 图片：这才是真正费劲的地方

如果说发文接口是"每种平台一套鉴权"，那图片就是"每种平台一套生态"。

cspub 的处理方式是**按平台分流**：

```bash
cspub imgs 我的文章.md      # 先预演：只扫描不联网，列出每张图会被怎么处理
```

预演会标出 `rehost`（转存）、`skip`（跳过）、`BLOCKED`（拦截）。真正 `publish` 时：

1. 扫描正文图片引用，代码围栏内的跳过；
2. 已是平台图床或 `data:` 的开局就跳过；**内网、回环、链路本地地址直接拦截**——防止把本机服务当图源；
3. 下载外链图，**拒绝 30x 重定向**（重定向可能把请求带到没检查过的主机），单张上限 12 MiB；
4. 走平台图床，拿到新 URL；
5. 从后往前回写正文（偏移不会挪位）。

最后一条尤其重要：**best-effort**。单张图失败就保留原链接并提示，绝不因为一张图阻断整篇文章的发布。写文章已经够累了，我不想再因为图床抽风丢一次草稿。

## 几个踩过的坑，值得单独说

这些坑都记在仓库的 `docs/开发文档与踩坑记录.md` 里，捡最有代表性的说三个。

**其一：JSON 字段必须按类型取。** CSDN 图床的签名响应里 `customParam.isAudit` 是个 **JSON 数字**，我一开始用只认字符串的 `jsonStr` 去取，拿到空串，把空的 `x:isAudit` 发给华为 OBS，OBS 回的是 **HTTP 200 + 0 字节**。看起来像"请求被网关吞了"，实际上是回调拿不到字段。改法是按 JsonKind 分派取值——数字、字符串、布尔各走各的。

**其二：UTF-8 截断不能按字节切。** 摘要截断要判断首字节 `(b & 0xC0) != 0x80` 才算字符边界，否则会把汉字切成半个，文章里出现一串乱码。行内渲染同理，必须按区间整体转码，逐字节 append 会把汉字拆成非法序列。

**其三：CSDN 的证书链很奇怪。** 它的根是 Certum——一个小众 CA。实测本机 stdx TLS 在 1.0.5.1 和 1.2.0.1 两代上，默认模式和 CustomCA 模式（内嵌了逐字节一致的 Certum 根）都报 unknown CA，而系统 curl 验同一条链是通过的。这事我还没查完，怀疑和 stdx 动态加载 OpenSSL 的验证行为有关。所以留了个 `--insecure`（TrustAll）逃生口，但**正式发文请先试默认模式**，失败再考虑——HTTPS 内容仍然加密，只是不验证服务器身份，风险自己承担。

## 已知限制，先告诉你

- 表格、脚注、任务列表这些扩展 Markdown 不渲染，会原样进段落。内置渲染器只覆盖标题、段落、列表、引用、代码围栏、图片、链接、行内代码和加粗——够用，但你得知道边界。
- 更新文章只有 CSDN 支持 `--update <id>`，其他平台要改就得删了重发。
- **CSDN 每天只能发 1 篇**（存草稿同算）。额度用满时接口直接回 `400300012`，这不是工具的问题，换自然日或换账号。
- 开源中国"发布成功 ≠ 立刻公开"：接口返回了 id，`blog/detail` 也能读到完整正文，但公开页可能还是「找不到您访问的页面」——新号首篇大概率走人工审核。
- Windows 侧只做了交叉编译（exe + 自包含 zip），发文链路还没在真机 Windows 上跑过。

## 最后

这个项目对我来说有个特殊意义：它是我在 [cjh](https://atomgit.com/qq8864/cjh) 里"自己写工具给自己用"的第一批成果之一。项目本身不大，但从签名对账、TLS 信任、UTF-8 字节语义到六套平台鉴权，每一处都是真刀真枪踩出来的。

如果你也在一稿多投，欢迎拿去用、提 issue、或者直接把某个平台的适配改得更顺手。

**相关链接：**

- 官网（六平台矩阵、流水线图、实测数据）：<https://yangyongzhen.github.io/cspub/>
- 项目主页（AtomGit，主仓）：<https://atomgit.com/qq8864/cspub>
- GitHub 镜像：<https://github.com/yangyongzhen/cspub>
- 桌面取证工具 cookie-export：<https://atomgit.com/qq8864/cj-tauri>
- 开发它的 Agent：<https://atomgit.com/qq8864/cjh>

许可证 MIT，随手拿去用。
