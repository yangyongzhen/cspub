# cspub 项目指令（AGENTS.md）

> 本文件由 agent 自动加载注入 system prompt，人类开发者与 AI 开发者共同遵守。
> 版本：2026-11-04

## 项目定位（改代码前先读）

cspub 是一个 CSDN 自动发文 CLI：一份 Markdown（带 front-matter），一条命令完成图片转存、HTML 渲染、网关签名与发布。它同时是 [cjh](https://atomgit.com/qq8864/cjh) 的实战交付物——整个项目在 cjh 里开发，任何改动也应优先在 cjh 里完成。

## 强制门禁（CI 红线）

任何代码变更交付前，必须满足：

1. **`cjpm build` 通过且编译零警告**。核对命令：
   `cjpm build 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | grep -c 'warning:'` —— 期望 `0`。
   unused 函数/导入/常量一律当场清理；改完代码必回头查"旧调用方"（删函数/改签名后，其辅助函数与导入会立刻变 unused）。
2. **行为变更必须有对应测试**：`--insecure`、`jsonScalar` 这类修复都先有复现手段再修。测试放 `src/*_test.cj`（`cjpm test` 运行，测试专用辅助按约定改名 `*_test.cj` 被发布构建排除）。
3. **端到端验证凭证**：发文链路改动的唯一交付凭证是真机跑一篇——`publish`（先草稿）回显 article id、`imgs` 预演输出、图片转存后 `curl` 图床直链返回 `200 + 非零字节`。禁止以"改动小"为由跳过。
4. **不允许"先交付后补测"**——测试与代码同批交付。

## 代码组织原则

- 单一职责按文件切分：`main.cj`（CLI 分发）/ `article.cj`（front-matter 与正文解析）/ `md.cj`（Markdown→HTML 渲染器）/ `csdn.cj`（签名与发文接口）/ `images.cj`（图床转存流水线）/ `util.cj`（JSON/编码等工具函数）。新功能先判断落在哪个文件，不要往 `main.cj` 堆。
- **可复用函数不重复定义**：新增前先查 `util.cj` 是否已有（`jsonScalar`、UTF-8 安全截断等都在那）。
- 网络请求安全约束（改动 images/csdn 不得破坏）：
  - 外链图下载**拒绝 30x 重定向**（重定向可能把请求带到没检查过的主机）；
  - 内网/回环/链路本地地址**拦截**（防把本机服务当图源）；
  - 单张图上限 12 MiB；
  - 图片转存 best-effort：单张失败保留原链接并提示，**不阻断发文**。

## 踩坑沉淀（已踩，勿重踩）

详见 [docs/开发文档与踩坑记录.md](./docs/开发文档与踩坑记录.md)，以下是最容易复踩的：

1. **JSON 取值必须按 Kind 取**：签名响应里 `customParam.isAudit` 是 JSON 数字，用只认字符串的 `jsonStr` 取得空串 → 空的 `x:isAudit` 发给 OBS 得到"HTTP 200 + 0 字节"空图。取 JSON 字段一律用 `jsonScalar`（按 JsonKind 分派）。
2. **UTF-8 字节语义**：摘要截断按首字节判界（`(b & 0xC0) != 0x80`），不在汉字中间切开；行内渲染按区间整体转码，不逐字节 append（逐字节会把汉字拆成非法序列）。
3. **CSDN 证书链**：根是 Certum（小众 CA），stdx TLS 默认与 CustomCA 模式均报 unknown CA（系统 curl 验同链通过，疑 stdx 动态加载 OpenSSL 行为问题，已记录待查）。`--insecure`（TrustAll）是逃生口；**正式发文先试默认模式，失败再加 `--insecure`**，不要默认带上。
4. **stdx 1.2.0 编译差异**：`CertificateVerifyMode` 在 `stdx.net.tls.common` 子包，需显式 import 且用限定名；`CustomCA` 收 `Array<Certificate>`（接口）而 `decodeFromPem` 返回 `Array<X509Certificate>`（类），Array 不协变需显式搬移。源码以 1.2.0 为准。
5. **CSDN 每日发文限额**：单账号每天 1 篇（存草稿同算），错误码 400300012/400300001——不是工具问题，不要往代码方向排查。
6. **本地构建缺库**：直接跑 `target/release/bin/main` 报 `libstdx.encoding.json.so` 缺失时，补 `LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/linux_x86_64_cjnative:<cangjie>/third_party/llvm/lib`，不要重编译。

## 版本与发布规范

- 版本号单一真相：`cjpm.toml` 的 `version`；规则沿用 cjh（重大更新递增中间位、小更新递增末位）。
- 发版必须同批更新 `CHANGELOG.md`（Keep a Changelog 风格，分节：新增/变更/修复/文档/构建，每条带证据）。
- 发布流程与产物规范见 [docs/发布与版本维护.md](./docs/发布与版本维护.md)：`dist/` 产物 + SHA256SUMS + tag（`v0.1.0` 格式）+ 基于 tag 的 release 附件。

## 文档规范

- 踩坑写进 `docs/开发文档与踩坑记录.md`：现象 → 排查铁证 → 修复方案 → 复用配方，四段齐全才收。
- 流程/方案类写进 `docs/` 独立文档（如发布与版本维护），README 只留指针，不堆细节。
- README 中的图放 `docs/imgs/`，源图（svg）与导出图（png）同仓版本化。
