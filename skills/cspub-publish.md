---
name: cspub-publish
description: "cspub 发文操作手册：Cookie 配置、publish/check/imgs/html/whoami 子命令、--live 与 --update 语义、发文前预演清单——要用 cspub 发 CSDN 文章或排查发文失败时看这篇"
---

# cspub 发文操作手册

## Cookie 配置（二选一，先做）

```bash
export CSPUB_CSDN_COOKIE='<浏览器 F12 复制的 Cookie 整串>'   # 推荐，不落盘
# 或 ~/.cspub/config.json 写 {"csdnCookie": "..."} 并 chmod 600
cspub whoami    # 校验配置（只验格式不联网）
```

## 运行前补动态库路径（直接跑二进制报 libstdx 缺失时）

```bash
export LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/linux_x86_64_cjnative:<cangjie>/third_party/llvm/lib
```

## 发文标准流程（三步，先预演后发文）

```bash
cspub imgs    文章.md     # 预演：列出每张图 rehost/skip/BLOCKED，不联网
cspub check   文章.md     # 校验 front-matter + 渲染统计
cspub publish 文章.md --live   # 或省略 --live 先发草稿
```

发布成功回显 `文章链接` 与 `文章 id`，改稿后原地更新：

```bash
cspub publish 文章.md --update <id> --live
```

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

## 图文处理要点

- Markdown 里图片写**本机绝对路径**（如 `/root/test/cj/img/xx.png`）最稳：跳过下载直接上图床；外链图会自动转存（拒绝重定向、单张 12 MiB 上限）。
- 代码围栏内的 `![]()` 是示例文本，转存自动跳过。
- 排版只保证标题/段落/列表/引用/代码围栏/图片/链接/行内代码/加粗；表格/脚注不渲染，复杂排版先 `cspub html` 目验。

## 失败速查

- `401/403`：Cookie 过期 → 重取；WAF 拦截（403+HTML）→ 换网络过验证码。
- `400300012/400300001`：CSDN 每日限额（1 篇/天，草稿同算）→ 换自然日或换账号，不是工具问题。
- TLS 报错：默认模式失败再加 `--insecure`（TrustAll），不要默认带上。
- `CSPUB_DEBUG=1` 打开发文链路诊断（请求体积、OBS 状态码）。
