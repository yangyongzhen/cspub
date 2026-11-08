<div align="center">

# cspub

**One Markdown file in, ten platforms out — a publishing CLI written in Cangjie.**

It reads your post (Markdown + front-matter), renders HTML, re-hosts images for each target,
signs the gateway calls, submits, and prints the article id back. Ten platforms, ten sets of
quirks — handled once in code instead of by hand.

**English** · [简体中文](./README.zh-CN.md)

`CSDN` · `Zhihu` · `Juejin` · `OSChina` · `CNBlogs` · `Baijiahao` · `Tencent Cloud` · `Yuque` · `Toutiao` · `SegmentFault`

[![Version](https://img.shields.io/badge/version-0.3.2-blue)](https://github.com/yangyongzhen/cspub/releases)
[![Platforms](https://img.shields.io/badge/platforms-10-brightgreen)](#supported-platforms)
[![Language](https://img.shields.io/badge/language-Cangjie%201.2.0-ff69b4)](https://cangjie-lang.cn)
[![Dependencies](https://img.shields.io/badge/dependencies-0%20third--party-lightgrey)](#why-cangjie)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![Website](https://img.shields.io/badge/website-yangyongzhen.github.io%2Fcspub-ffb224)](https://yangyongzhen.github.io/cspub/)
[![GitHub](https://img.shields.io/badge/github-yangyongzhen%2Fcspub-181717?logo=github)](https://github.com/yangyongzhen/cspub)
[![AtomGit](https://atomgit.com/qq8864/cspub/star/badge.svg)](https://atomgit.com/qq8864/cspub)

<img src="docs/imgs/cspub-flow.png" alt="cspub publishing pipeline: parse, re-host images, render HTML, sign, submit" width="780">

</div>

cspub is a CLI for publishing one article to many Chinese developer platforms at once. The source
repository lives on [AtomGit](https://atomgit.com/qq8864/cspub); this GitHub repo is a mirror kept
in sync commit-for-commit.

## Why this exists

Writing is automated already. **Publishing is not.** Every platform wants something different
before it will take your post:

| The thing that actually bites | What cspub does about it |
| --- | --- |
| Logging into each platform and hand-copying cookies | Credentials are exported once (`cookie-export`, an embedded browser — it can read httpOnly `z_c0` / `UserToken` / `sessionid`). After that cspub is pure HTTP and never opens a browser |
| Images break, or the platform strips them | Per-platform re-hosting: CSDN / Zhihu / Toutiao / Tencent Cloud require their own image host; Juejin / SegmentFault take public URLs; OSChina uses its built-in host. Private/loopback addresses are blocked, 30x redirects are refused, 12 MiB per image |
| Publishing by accident, then not being able to take it down | Drafts are the default; `--live` is explicit. `--update <id>` rewrites an existing post instead of stacking duplicates; `cspub delete` removes one (OSChina today) |
| Failing at submit time and burning a daily quota | `check --platform` is a purely local preflight (title length, image hosts, required fields) that catches doomed posts offline. Partial image re-hosting aborts by default; `--force` overrides |
| Not being scriptable | Non-interactive, meaningful exit codes, server error codes echoed verbatim, `CSPUB_DEBUG=1` prints the request chain — usable inside CI or an agent loop |

Nine of the ten channels are pure HTTP. Only the Baijiahao cookie path needs a small Playwright
helper script; its official token API is pure HTTP too.

## Quick start

```bash
# 1. local preflight — no network, catches doomed posts before they cost a daily quota
cspub check   post.md --platform toutiao

# 2. dry-run what happens to each image
cspub imgs    post.md

# 3. publish (draft by default), then for real
cspub publish post.md --platform toutiao
cspub publish post.md --platform toutiao --live
```

A post is a Markdown file with front-matter:

```markdown
---
title: Your title here      # required
tags: cangjie, cli          # comma-separated, max 5
categories: programming
desc: One-line summary      # defaults to the first 200 chars of the body
draft: true                 # default true; --live overrides it
---

Body in Markdown……
```

## Supported platforms

`--platform` selects the target (default `csdn`):

| `--platform` | Platform | Auth | Image policy | Watch out |
| --- | --- | --- | --- | --- |
| `csdn` | CSDN | Gateway HMAC-SHA256 signature (`x-ca-*`) + cookie | **Must re-host to CSDN's image host** (hotlink protection answers 200 + 0 bytes) | 1 post per account per day, drafts count too |
| `zhihu` | Zhihu | Cookie (`z_c0`), three-step draft flow | Re-host to Zhihu CDN (foreign images get stripped) | — |
| `juejin` | Juejin | Cookie (`sessionid`), two-step flow | Public URLs fine; an AtomGit token makes the whole path HTTP-only | Category/tag ids are internal backend ids (optional) |
| `oschina` | OSChina | Cookie (`oscid`) against site APIs | Its own image host (`oscimg`) | Body is submitted as raw Markdown; the server renders it |
| `cnblogs` | CNBlogs | MetaWeblog token (not the login password), no cookies | Best-effort | — |
| `baijiahao` | Baijiahao | Official token (invite-only) / cookie + Playwright form fill | Best-effort | Needs `origin_url`, a cover, title 8–40 chars |
| `tencent` | Tencent Cloud Dev | Cookie (`skey` / `qcommunity_session`), no signature | The server fetches your image URLs | `tagIds` required, column must be one you joined, body ≥140 chars |
| `yuque` | Yuque | Official OpenAPI v2 + `X-Auth-Token` | References kept as-is | Namespace must be `user/repo` (two segments, never one) |
| `toutiao` | Toutiao | Cookie + `X-CSRFToken` | **Everything must be re-hosted to Toutiao's CDN** — any other host rejects the whole post (`7115`) | Title 5–30 chars; there is no draft channel, so `--draft` refuses to submit |
| `segmentfault` | SegmentFault | Cookie + a `Token` scraped from the editor page at submit time | Public URLs (AtomGit token turns local images into URLs) | `--draft` stores a draft |

## What it does

One command runs five steps in order:

1. Parse the Markdown and front-matter (`title` / `tags` / `categories` / `desc` / `draft` / `origin_url`).
2. **Re-host images for the target platform** — the most common slow death of a published post is an
   image that quietly stops resolving.
3. Render Markdown to HTML (the editors want rendered output, not source).
4. Authenticate and submit (signature / cookie / token). Server error codes are echoed verbatim,
   never guessed away.
5. Print the article id, the draft id, and the follow-up commands.

The main path is built entirely on the Cangjie standard library + stdx (HMAC / Base64 / HTTP /
JSON / TLS) — **zero third-party dependencies**. Only the Baijiahao cookie path delegates to a
Playwright helper script.

## Why Cangjie

CSDN's editor endpoint (`bizapi.csdn.net/blog-console-api/v3/mdeditor/saveArticle`) uses an Alibaba
Cloud API Gateway style HMAC-SHA256 signature (`x-ca-*` headers). The key/secret are baked into
public front-end JS, so the only credential needed is your own login cookie. The whole job reduces
to: read a file → parse front-matter → render HTML → sign → POST.

Cangjie 1.2.0's stdx covers every piece of that: `stdx.crypto.digest` (HMAC),
`stdx.encoding.base64`, `stdx.net.http`, `stdx.net.tls`. The result compiles to a single static
binary with **no external dependency**. The real pitfalls met along the way — signature
reconciliation, TLS trust chains, UTF-8 byte semantics, JSON kind dispatch — are written up in
[`docs/开发文档与踩坑记录.md`](./docs/开发文档与踩坑记录.md) and summarized under
[Implementation notes](#implementation-notes-aka-the-gotchas).

## Build

```bash
export CANGJIE_STDX=<stdx>/dynamic/stdx   # stdx bundled with Cangjie 1.2.0
export PATH=$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH
cjpm build
# artifact: target/release/bin/main
# Windows cross-compile: ./scripts/winbuild.sh (exe + self-contained zip)
```

## Credentials

Every platform accepts either an environment variable or a field in `~/.cspub/config.json`.
**Environment variables win** when both are set, so you can swap accounts without editing files.

### Extract cookies with cookie-export (recommended)

![cookie-export tool](docs/imgs/cookie-export-tool.png)

The fields that actually matter — Zhihu `z_c0`, Juejin `sessionid`, CSDN `UserToken` — are usually
**httpOnly**: `document.cookie` cannot read them, and hand-copying from DevTools drops fields.
[`examples/cookie-export`](https://atomgit.com/qq8864/cj-tauri/tree/main/examples/cookie-export)
is a small cj-tauri desktop tool that opens an embedded browser, lets you log in once, and writes
`~/.cspub/config.json` (merged, `chmod 600`) plus `~/.cspub/cookie_<platform>` text files.

It covers 9 platforms: CSDN / Zhihu / Juejin / OSChina / Baijiahao / Tencent Cloud / Toutiao /
Xiaohongshu / Yuque. CNBlogs uses a MetaWeblog token rather than a cookie, so the tool only guides
you. SegmentFault is deliberately **not** included: its token is scraped per-request from the editor
page (`__NEXT_DATA__` → `serverData.Token`), so there is no stable cookie field to validate and
inventing one would mislead. cspub itself supports SegmentFault with a plain Cookie string.

The table below remains the manual path — the tool is a convenience, not a requirement.

| Platform | Environment variable | `config.json` field | How to get it |
| --- | --- | --- | --- |
| `csdn` | `CSPUB_CSDN_COOKIE` | `csdnCookie` | Log in → DevTools → copy the full Cookie header |
| `zhihu` | `CSPUB_ZHIHU_COOKIE` | `zhihuCookie` | Log in at zhuanlan.zhihu.com → full Cookie (must contain `z_c0`) |
| `baijiahao` | `CSPUB_BAIJIAHAO_COOKIE`, or `CSPUB_BAIJIAHAO_APP_ID` + `CSPUB_BAIJIAHAO_APP_TOKEN` | `baijiahaoCookie` / `baijiahaoAppId` / `baijiahaoAppToken` | Cookie must contain `BDUSS`; the developer-token path is invite-only |
| `cnblogs` | `CSPUB_CNBLOGS_BLOG_ID` / `_USERNAME` / `_TOKEN` | `cnblogsBlogId` / `cnblogsUsername` / `cnblogsToken` | Blog settings → enable client access → MetaWeblog **access token** (not your login password) |
| `juejin` | `CSPUB_JUEJIN_COOKIE` (+ optional `_UUID` / `_CATEGORY_ID` / `_TAG_IDS`) | `juejinCookie` … | Full Cookie with `sessionid`; category/tag ids are optional |
| `oschina` | `CSPUB_OSCHINA_COOKIE` (+ optional `_USER_ID` / `_CATALOG` / `_PRIVACY`) | `oschinaCookie` … | Full Cookie with `oscid`; images go to its built-in host, nothing else to configure |
| `tencent` | `CSPUB_TENCENT_COOKIE` + `CSPUB_TENCENT_TAG_IDS` (optional `_CLASSIFY_IDS`) | `tencentCookie` … | Cookie with `skey` or `qcommunity_session` (keep the `*` inside `skey` literal). `tagIds` is mandatory — empty answers `-9993`; the column must be one you joined, otherwise `300031` |
| `yuque` | `CSPUB_YUQUE_TOKEN` + `CSPUB_YUQUE_NAMESPACE` (optional `_PUBLIC`) | `yuqueToken` / `yuqueNamespace` / `yuquePublic` | Token at yuque.com/settings/tokens; namespace is the two segments `user/repo` (one segment always 404s) |
| `toutiao` | `CSPUB_TOUTIAO_COOKIE` (optional `CSPUB_TOUTIAO_CSRF`) | `toutiaoCookie` / `toutiaoCsrf` | Cookie with `sessionid` or `tt_webid`; `X-CSRFToken` is read from the `csrftoken` cookie automatically |
| `segmentfault` | `CSPUB_SEGMENTFAULT_COOKIE` | `segmentfaultCookie` | The full Cookie string; the publishing token is scraped at submit time |
| images (optional) | `CSPUB_ATOMGIT_TOKEN` (+ `_REPO` / `_BRANCH` / `_DIR`) | `atomgitToken` … | AtomGit personal token; defaults to repo `qq8864/images`, branch `main`, dir `cspub` |
| strict images (optional) | `CSPUB_STRICT_IMAGES` | — | `1` aborts the publish when local images remain un-hosted; default is best-effort |
| script dir (optional) | `CSPUB_SCRIPT_DIR` | — | Where the `scripts/*.py` helpers live; otherwise searched from cwd and from the binary directory up 5 levels |

```bash
# temporary (this terminal only)
export CSPUB_CSDN_COOKIE='<the full Cookie header>'
cspub publish post.md --live

# persistent
echo "export CSPUB_CSDN_COOKIE='<cookie>'" >> ~/.bashrc && source ~/.bashrc
```

Cookie strings contain spaces and semicolons — always single-quote them. On a shared machine prefer
`~/.cspub/config.json` with `chmod 600`: environment variables are readable by other processes via
`/proc/<pid>/environ`.

> Baijiahao has two channels. Its official token API is pure HTTP. The cookie channel **must** go
> through the browser: calling its publish API directly lacks the CSRF chain the React button builds
> and always returns 500. So `--platform baijiahao` with a cookie launches
> `scripts/baijiahao_publish.py` (Playwright form fill + click), which needs
> `pip install playwright && playwright install chromium`.

`cspub whoami [platform]` validates that credentials are present (format only, no network; `yuque`
and `segmentfault` are exceptions — they make one real request to verify the session).

## Usage

```
cspub check   <post.md> [--platform p]   parse front-matter + render stats; with --platform also runs
                                         that platform's local preflight (title length, image hosts,
                                         required fields; offline, exits 1 when a rule fails)
cspub html    <post.md>                  print the rendered HTML (debug)
cspub imgs    <post.md>                  dry-run image routing: rehost / skip / BLOCKED (offline)
cspub publish <post.md> [--draft]        draft (default)
                        [--live]         publish for real (overrides draft: true)
                        [--platform p]   target platform, default csdn
                        [--update id]    update an existing post in place (CSDN only)
                        [--cover img]    separate cover image (Baijiahao)
                        [--force]        submit even when some images failed to re-host
                        [--insecure]     skip TLS verification (TrustAll; diagnostics only)
cspub tags    --platform tencent         list joined columns and usable tag ids
cspub delete  --id <id>                  delete a published post (oschina only — the endpoint takes a
                        [--platform oschina]   form body; a JSON body is silently ignored server-side)
cspub whoami  [platform]                 validate credential configuration
cspub help
```

`CSPUB_DEBUG=1` writes the image-host and publishing request chain to stderr (request sizes, OBS
status codes, response prefixes). Not needed for normal use.

## Image re-hosting (automatic)

Policies differ per platform and `publish` picks by `--platform`: **CSDN / Zhihu / Toutiao /
Tencent Cloud** must land on the platform's own image host (the first three strip or reject foreign
images), **Juejin / SegmentFault** accept public URLs (with `CSPUB_ATOMGIT_TOKEN` those go to an
AtomGit repo), **OSChina** uses its built-in host.

The baseline is the same everywhere: private / loopback / link-local addresses are blocked, 30x
redirects are refused, 12 MiB per image, and one failed image keeps its original URL and prints a
warning instead of blocking the post.

CSDN is the most involved path. It hotlink-protects foreign images (a plain `<img>` returns **HTTP
200 with 0 bytes**), so `publish` re-hosts before submitting:

1. Scan image references in the body, skipping code fences.
2. Skip images already on the CSDN host or `data:`; **block** private, loopback and link-local hosts.
3. Download, refusing 30x redirects and capping at 12 MiB per image.
4. Sign the CSDN image-host gateway (HMAC + cookie) → Huawei OBS multipart (policy auth) → the
   callback returns a `csdnimg.cn` URL.
5. Rewrite the Markdown back-to-front so offsets do not shift. Best-effort per image.

`cspub imgs <post.md>` previews the routing offline, without touching the network.

**Verified on 2026-10-21**: a real post with two `raw.githubusercontent.com` images re-hosted 2/2,
rewritten to `https://i-blog.csdnimg.cn/direct/<hash>.png`, and rendered correctly after publishing.

**A gotcha worth repeating**: in the image-host signature response `customParam.isAudit` is a **JSON
number**. Reading it with a string-only helper yields an empty string, and sending an empty
`x:isAudit` to OBS returns **HTTP 200 with 0 bytes** — which looks like the gateway swallowing the
request but is really a missing field. The fix is a kind-dispatching reader (`jsonScalar`).

### Juejin: public URLs, AtomGit as the image host

Juejin **accepts external images** (measured: an API-created draft reports `naturalWidth > 0` for
AtomGit-hosted images). With `CSPUB_ATOMGIT_TOKEN` set, `--platform juejin` uploads each local image
to the AtomGit repo `contents` API and rewrites the body to
`https://atomgit.com/api/v5/repos/<owner>/<repo>/raw/<path>?ref=<branch>`; failures fall back to the
Playwright helper, then keep the original reference. The payoff is that the image path no longer
needs `python3 + playwright + chromium`.

### OSChina: its own image host first

Uploads go to `POST /oschinapi/upload/img` (multipart field `file`, login cookie only) and return
`https://oscimg.oschina.net/.../up-<md5>.png`. Priority: platform host → AtomGit fallback → keep the
original reference. The direct URL contains a `//null/` segment (an unused bucket slot) but is
valid: browsers fetch it fine, while a bare `curl` without a UA gets a CDN 403 — not a dead link.

### OSChina: three measured publishing facts

1. **Submit Markdown, the server stores HTML.** The body is `contentType: 1` plus raw Markdown, but
   `blog/detail` already returns rendered `<h2>`/`<p>`. Pre-rendering converts it twice.
2. **Tags are extracted by the platform.** Tags in front-matter are ignored; the server derives them
   from body keywords. Categories do respect `catalog` (name match, else the first one).
3. **The article URL is `/blog/{id}`**, not `/u/{userId}/blog/{id}` (that 404s). The SPA shell also
   answers **200 for any id**, so an HTTP status says nothing about visibility — only a rendered page
   or `blog/detail` does.

> **Publishing succeeded ≠ publicly visible.** With a new account the first posts go through manual
> review; treat the returned id as "accepted", not "live".

## Implementation notes (aka the gotchas)

- **`content` must be rendered HTML.** Sending raw Markdown makes CSDN display literal `##` and
  `![]()`. The built-in renderer covers headings / paragraphs / lists / quotes / fenced code /
  images / links / inline code / bold; tables and footnotes are not covered — check with
  `cspub html` first.
- **HMAC reconciliation.** The signature implementation was checked byte-for-byte against Python
  `hmac + sha256`; the nonce is 16 random bytes as hex (`std.random.nextBytes`).
- **UTF-8 safety.** Summaries truncate on a lead-byte boundary (`(b & 0xC0) != 0x80`) so a Chinese
  character is never split; inline rendering transcodes whole spans, never byte-by-byte.
- **Foreign images must be re-hosted first.** CSDN's hotlink protection answers 200 + 0 bytes;
  `publish` handles it (see above), verified end-to-end on 2026-10-21.
- **Cookies expire.** On 401/403 the CLI tells you to re-extract. If a WAF answers with HTML,
  change network or redo the captcha and retry.
- **Known TLS issue.** CSDN's certificate chain roots at Certum (a small CA). On this machine stdx
  TLS reports unknown CA in both default and CustomCA mode (with a byte-identical Certum root
  embedded), while system `curl` validates the same chain — suspected OpenSSL dynamic-loading
  behaviour in stdx, recorded and open. `--insecure` (TrustAll) is the escape hatch: try the default
  first, add the flag only on failure. Traffic stays encrypted; only the server identity is unverified.
- **stdx 1.2.0 compilation differences.** `CertificateVerifyMode` moved to `stdx.net.tls.common`
  and needs an explicit import plus qualified variants; `CustomCA` takes `Array<Certificate>`
  (interface) while `decodeFromPem` returns `Array<X509Certificate>` (class), so the array must be
  copied explicitly. The source here targets 1.2.0.

## Version maintenance

- **Single source of truth** for the version is `version` in `cjpm.toml`: middle digit for major
  updates, last digit for small ones. `CHANGELOG.md` is updated in the same commit.
- **Changelog** follows Keep a Changelog (Added / Changed / Fixed / Docs / Build). Every entry
  carries evidence — measured output, error codes, re-hosting results. No unverified claims.
- **Two remotes.** Source of truth is [AtomGit](https://atomgit.com/qq8864/cspub) (`origin`);
  [GitHub](https://github.com/yangyongzhen/cspub) is the mirror (`github`). A release pushes both.
- **Release flow.** `cjpm build` → artifacts into `dist/` → `SHA256SUMS` checked with
  `sha256sum -c` → tag (`v0.3.2` form) → release attached to that tag. Details in
  [`docs/发布与版本维护.md`](./docs/发布与版本维护.md).
- **Current version: `0.3.2`.** On top of 0.3.1 (ten channels, platform preflight, image-failure
  gate, Toutiao upload retry, AtomGit fallback endpoint) it fixes HTML-unescaping of image URLs in
  the Toutiao path, adds a PNG-encoding diagnosis for Toutiao `1050`, decouples the Baijiahao cover
  from body images (`--cover`), and adds `cspub delete` for OSChina.

## Known limitations

- Extended Markdown (tables, footnotes, task lists) is not rendered — it becomes plain paragraphs.
- In-place update (`--update <id>`) is CSDN only; `delete` is OSChina only. No verified endpoints
  exist for the others, and this project does not invent them.
- **Toutiao has no draft channel.** Any non-zero `save` submits and publishes; `save=0` (a real
  draft) needs a one-off browser risk-control signature (`msToken` / `a_bogus` / `tt-anti-token`)
  that plain HTTP cannot reproduce. `--platform toutiao --draft` therefore refuses and explains
  instead of silently publishing.
- **Baijiahao's cookie channel needs Playwright** on the host: `pip install playwright &&
  playwright install chromium`.
- **OSChina visibility.** A returned blog id is not proof of a public page: new accounts and first
  posts are reviewed manually, and the SPA shell answers 200 for any id. Only a rendered page tells.
- **Windows.** `./scripts/winbuild.sh` cross-compiles an exe (8.2 MB, mingw-stripped) plus a
  self-contained zip (exe + libboundscheck / libcangjie-runtime / libcrypto-3-x64 /
  libssl-3-x64). The publishing paths have not been run on a real Windows machine.
- **CSDN publishes once per account per day.** Over the limit `saveArticle` returns
  `{"code":400300012,...}`; drafts are rejected too (`400300001`). That is an account quota, not a
  tool bug.
- End-to-end verified on 2026-10-21: image re-hosting 2/2, publishing returned an article id,
  `--update <id>` rewrote the post in place.

## Docs

- [`README.zh-CN.md`](./README.zh-CN.md) — the Chinese README (same content, more narrative)
- [`docs/开发文档与踩坑记录.md`](./docs/开发文档与踩坑记录.md) — field notes, each entry with
  symptom → hard evidence → fix → reusable recipe
- [`docs/发布与版本维护.md`](./docs/发布与版本维护.md) — release and versioning process
- [`CHANGELOG.md`](./CHANGELOG.md) — every change with its evidence
- [`AGENTS.md`](./AGENTS.md) — delivery gates and code organization
- Website: <https://yangyongzhen.github.io/cspub/>

## License

MIT — see [LICENSE](./LICENSE).
