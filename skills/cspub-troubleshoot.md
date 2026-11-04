---
name: cspub-troubleshoot
description: "cspub 踩坑速查：OBS 200+0字节空图（isAudit JSON 数字坑）、CSDN 防盗链真面目、TLS unknown CA、stdx 1.2.0 编译差异、UTF-8 字节语义、每日发文限额、libstdx 缺失——发文链路任何异常先看这篇"
---

# cspub 踩坑速查

详细排查过程见 `docs/开发文档与踩坑记录.md`，此处按症状索引。

## 症状 → 根因 → 处置

| 症状 | 根因 | 处置 |
| --- | --- | --- |
| 图片转存返回 200 但直链是 0 字节空图 | 签名响应里 `isAudit` 是 JSON **数字**，用只认字符串的 `jsonStr` 取得空串；空 `x:isAudit` 发 OBS 得空文件 | 已修（`jsonScalar` 按 Kind 取值）。若再遇"取 JSON 字段"，一律按 Kind 取，不假设类型 |
| 外链图发出去正文裂图 | CSDN 防盗链：站外图 `<img>` 直连 **HTTP 200 + 0 字节** | 唯一解法是转存站内（publish 已内置）；先 `cspub imgs` 预演 |
| TLS 报 unknown CA | CSDN 证书链根是 Certum，stdx TLS 默认/CustomCA 均过不了（系统 curl 可过，疑 stdx OpenSSL 行为问题） | 正式发文先试默认模式，失败再加 `--insecure`（TrustAll）；不要默认带上 |
| stdx 1.2.0 编译不过 | `CertificateVerifyMode` 移到 `stdx.net.tls.common` 子包；`CustomCA` 收接口数组而 `decodeFromPem` 返回类数组 | 显式 import 子包 + 限定名变体；接口数组逐元素显式搬移（Array 不协变） |
| 摘要截断乱码 / 行内渲染汉字变非法序列 | 按 Byte 处理中文：截断切进多字节序列、逐字节 append 拆散汉字 | 截断按首字节判界（`(b & 0xC0) != 0x80`）；行内渲染按区间整体转码 |
| 发布回 `400300012` / `400300001` | CSDN 每日限额：单账号 1 篇/天，**存草稿同算** | 换自然日或换账号；不是工具问题，不要往代码排查 |
| 直接跑二进制报缺 `libstdx.encoding.json.so` | 动态链接产物缺运行时库路径 | 补 `LD_LIBRARY_PATH=<stdx>/dynamic/stdx:<cangjie>/runtime/lib/...`；发布包内无此问题 |
| 401/403（发文接口） | Cookie 过期 / WAF 拦截（403+HTML） | 重取 Cookie；换网络过验证码再试 |

## 诊断工具

- `CSPUB_DEBUG=1`：stderr 打请求体积、OBS 状态码与响应首段——排查上传/发文链路先开它。
- `cspub html 文章.md`：渲染结果目验（表格/脚注不渲染属已知限制）。
- 图床直链验收：`curl -sI` 返回 `200 + 非零 Content-Length` 才算真图。
