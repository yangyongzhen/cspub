---
name: cspub-release
description: "cspub 发版流程与规范：发版门禁（零警告/测试绿/端到端凭证/CHANGELOG 更新）、dist 打包与 SHA256SUMS、tag 命名、release 发布——给 cspub 发新版本时照这篇走"
---

# cspub 发版流程

## 发版门禁（全部通过才可发）

1. `cjpm build` 通过且**编译零警告**：
   `cjpm build 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | grep -c 'warning:'` → `0`
2. `cjpm test` 全绿；行为变更必须有对应测试
3. 端到端凭证：真机 `publish`（草稿）回显 article id + `imgs` 预演 + 图床直链 `curl` 返回 `200 + 非零字节`
4. `cjpm.toml` 的 `version` 已更新，`CHANGELOG.md` 顶部已有本版本条目（每条带验证证据）

## 发布六步（详细说明见 docs/发布与版本维护.md）

```bash
# 1) 构建
cjpm build    # 产物 target/release/bin/main

# 2) 产物入 dist/（命名 cspub-v<版本>-linux-x64）
mkdir -p dist && cp target/release/bin/main dist/cspub-v0.1.0-linux-x64
(cd dist && tar czf cspub-v0.1.0-linux-x64.tar.gz cspub-v0.1.0-linux-x64)

# 3) 校验清单（注意：sha256sum -c 必须在 dist/ 内跑，清单里是相对路径）
(cd dist && sha256sum cspub-v0.1.0-linux-x64 cspub-v0.1.0-linux-x64.tar.gz > SHA256SUMS)
(cd dist && sha256sum -c SHA256SUMS)   # 必须逐项 OK

# 4) 冒烟（补 LD_LIBRARY_PATH，见 cspub-troubleshoot 技能）
./dist/cspub-v0.1.0-linux-x64 help

# 5) 打 tag（格式 v<版本>）
git tag v0.1.0 && git push origin v0.1.0

# 6) 基于 tag 发 release，附 dist/ 产物与 SHA256SUMS
```

## 规范要点

- 版本号单一真相：`cjpm.toml` 的 `version`；规则沿用 cjh（重大更新递增中间位、小更新递增末位）
- `dist/` 只放当前版本产物；旧版本保留但不再列入 `SHA256SUMS`（沿用 cjh 做法）
- CHANGELOG 条目分节（新增/变更/修复/文档/构建/已知限制），**不写没有证据的条目**
- Windows 侧交叉编译未实测；跑通后按 `cspub-v<版本>-windows-x64.exe` 命名补充
