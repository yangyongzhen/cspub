---
title: 13MB 单文件、一条命令变服务：把仓颉写的 cjh 内嵌进你的应用，当它的 AI 大脑
tags: 仓颉,Agent,内嵌集成,WebSocket,桌面开发
categories: 编程
desc: cjh 是用仓颉从零实现的 coding agent harness，单文件、零运行时依赖。这篇讲怎么用「进程外 web 模式」把它内嵌成宿主应用的本地大脑：一条命令变服务、REST + WebSocket 双通道、六条生命周期语义、三个已验证案例（cjnote / ai-chat / lingqu）与踩坑清单。
draft: true
---

# 13MB 单文件、一条命令变服务：把仓颉写的 cjh 内嵌进你的应用，当它的 AI 大脑

想给自己的桌面应用加一个 AI 助手，绕不开第一个工程决策：**这个 agent 放在哪**。

我试过三种姿势，前两种都走不通，最后落在第三种上——而落点好的前提，恰好是 cjh 足够小。

先说结论：**cjh 是一个单文件、零运行时依赖的 coding agent harness。`cjh web` 一条命令把它变成 `127.0.0.1:8765` 上的 REST + WebSocket 服务，宿主应用像调一个本地服务那样调它**。你的应用不必懂仓颉，也不必把 agent 的崩溃面、升级节奏、模型密钥塞进自己的进程里。

---

## 一、先看它有多小，就明白它为什么好嵌

cjh 是我用华为仓颉语言从零写的交互式编码代理：终端里说一句话，它自己规划、调工具、读结果、迭代到完成，全程 TUI 实时可见。它对自己的两条硬指标是「省 token」和「高执行效率」，但今天这篇不谈这个，只谈一件事——**它的体积和依赖，决定了它能不能塞进别人的应用**。

| 维度 | 实测值 |
|---|---|
| Linux 产物 | 单个可执行文件 **18.4 MB**（本机 `dist/cjh-linux-x64` = 18,480,568 字节） |
| 运行时依赖 | **零**：仓颉 `cjnative` 静态编译，只要系统 libc，不需要 Python / Node / JVM |
| Windows 产物 | 一个 exe + 4 个 DLL（自包含 zip 约 8 MB） |
| 源码规模 | `src/` 下约 **4.1 万行**仓颉代码 |

![cjh 分层架构：入口层 / TUI / Web / Agent 主循环 / 工具系统 / 模型层](https://raw.gitcode.com/qq8864/images/raw/main/cjh/arch-diagram.png)

*分层架构：TUI 与 Web 只是两个入口，底下共用同一个 Agent 主循环——这正是能"进程外接入"的结构基础。*

"小"这件事对内嵌有三个直接好处：

1. **随包分发不肉疼**。宿主把 agent 当资产放进 `vendor/`，18 MB 塞进安装包是可以接受的；换成带 `node_modules` 或 Python venv 的方案，这一步就够劝退了。
2. **宿主的用户不用装任何东西**。没有解释器版本、没有虚拟环境、没有 `pip` 装一半失败。
3. **一份内核，三种界面**。同一个 agent 既能跑 TUI，也能被浏览器驱动，还能被桌面应用托管——不需要为宿主重写一套逻辑。

---

## 二、为什么不"嵌库"，而要"拉起一个进程"

这是我踩过的第一个思维定式：既然要集成，当然是 `import cjh` 当库调。

**不行。** cjh 是一个 executable 根包，而仓颉的根包不能被其他包导入。就算绕开语言限制，把 agent 塞进宿主进程也不划算：一个工具调用跑飞、一次 TLS 异常、一个 OOM，宿主界面跟着一起没。

三种形态的取舍摆在这里：

| 形态 | 结论 |
|---|---|
| 进程内嵌 cjh 为库 | **不可行**：仓颉根包不能被导入；agent 崩溃面会耦合进 UI |
| 自己写一个 mini-agent | 丢掉 cjh 的技能 / 审批 / 上下文压缩 / 工具 / MCP 生态，得不偿失 |
| **进程外 `cjh web` 子进程** | **选用**：REST + WS 走回环；崩溃隔离；可独立升级 cjh；TUI / 浏览器 / 桌面共享同一套 agent 与工具链 |

第三种还有个隐性好处：**升级是替换一个文件**。宿主的 AI 能力不再和宿主的发版绑在一起，用户想用新版 agent，换掉 `vendor/cjh/linux-x64/cjh` 就行。

---

## 三、一条命令变服务

```bash
# 最小拉起命令（bind 必须写，cjh web 默认绑 0.0.0.0 且默认无鉴权）
cjh web --port 8765 --bind 127.0.0.1 --token my-secret
```

拉起之后，宿主面对的就是两个标准通道：

- **REST `/api/*`**：健康检查、会话、模型、技能、MCP、工作区、设置；
- **WebSocket `/ws`**：一回合对话的流式帧（文本增量、工具调用、审批、结束）。

![cjh 内嵌接入全景：宿主应用 ↔ cjh web 子进程](https://raw.gitcode.com/qq8864/images/raw/main/cjh/embed-arch.png)

*接入全景：左边是宿主（前端页面 + 宿主后端），右边是 `127.0.0.1:8765` 上的 cjh 子进程。两条通道分工明确，中间那六条生命周期语义是踩出来的。*

顺便说，cjh 自带的 Web 界面就是这个服务的前端 SPA——所以"宿主界面"这件事它自己已经演示过一遍：

![cjh 内置 Web 界面](https://raw.gitcode.com/qq8864/images/raw/main/cjh/web-ui.png)

*`cjh web` 拉起的浏览器界面：同一套 REST + WS，换成你自己的前端，就是他的界面。*

---

## 四、六条生命周期语义：照抄不会错

宿主管理这个子进程，最容易被"看起来能跑"骗过去。三个真实集成方（ai-chat、cjnote、lingqu）踩完同一批坑，沉淀成六条：

1. **就绪判据只有一条**：`GET /api/health` 返回 200。没有"看着像起来了"这种模糊态；等待口径 100ms × 10s，超时**不算成功**，留进程等重试。
2. **复用优先，不抢不杀**：8765 上已有活的 cjh（可能是用户自己在终端里开的）就复用，退出时**也不动它**。
3. **只收自己拉起的**：宿主记录一个 `owned=true` 标志，只有自己拉起的实例才在退出时终止。
4. **拉起必须隐藏窗口**：宿主是 GUI 子系统时，普通 `launch` 会给子进程配一个黑窗口（Windows）。要用 `launchHidden`（`CreateProcessW` + `DETACHED_PROCESS`）。
5. **只绑回环**：自己拉起的一律加 `--bind 127.0.0.1`——cjh web 默认绑 `0.0.0.0` 且默认无鉴权，别让 agent 被整个局域网摸到。
6. **收尾用守护线程**：新形态应用常没有 onExit 钩子；守护线程 `waitForExit()` 之后收，而且**收 5 轮**，覆盖"用户秒关窗口"导致子进程抢跑的场景。

这六条听着琐碎，但少一条就是线上事故：少第 3 条，宿主把自己没拉起的 agent 杀掉；少第 5 条，端口对全网开放；少第 6 条，用户关窗后端口上留一堆孤儿进程。

---

## 五、REST 和 WebSocket 各管什么

**REST 负责"状态"，WS 负责"过程"。** 这个分工贯穿整条接入链路。

| REST 端点 | 作用 |
|---|---|
| `/api/health` | 健康检查 → `{status, version, web_port}`；**接入第一件事就是轮询它** |
| `/api/capabilities` | 服务端能力自述（协议版本 + 收发帧名清单） |
| `/api/sessions`、`/api/sessions/{id}` | 历史会话列表 / 单会话详情（可重命名、删除） |
| `/api/models`、`/api/model/switch` | 模型清单与切换 |
| `/api/skills`、`/api/mcp`、`/api/tasks` | 技能、MCP 服务器、任务清单 |
| `/api/settings` | 读写 `settings.json`（GET 对 apiKey 脱敏） |
| `/api/workspaces`、`/api/workspaces/switch` | 工作区增删与切换（真正生效，无需重启） |
| `/api/fs/list?path=` | 目录列表，给前端目录选择器用 |

WebSocket 是帧式单行 JSON，每帧带 `type`。**协议当前 v7**，`/api/capabilities` 会返回 `protocol` 与 `ws_in` / `ws_out` 两份帧名清单。

**客户端 → 服务端：**

| type | 载荷 | 说明 |
|---|---|---|
| `chat` | `{message}` | 发起回合（一回合 = 一次完整 agent 循环） |
| `abort` / `cancel` | — | 中断当前回合（两者同义） |
| `switch_model` | `{model, ...}` | 切换模型，按会话级契约只对本回合生效 |
| `new_session` / `resume_session` | `{session_id}` | 新建 / 恢复历史会话 |
| `compact` | — | 压缩当前上下文 |
| `approval_response` | `{request_id, allow}` | 回执审批，`request_id` 原样回传 |

**服务端 → 客户端：**

| type | 载荷 | 说明 |
|---|---|---|
| `delta` | `{text}` | **流式文本增量**（`text` 是裸字符串字段，见下节坑 1） |
| `tool_start` / `tool_result` | `{name, args}` / `{name, content, is_error}` | 工具调用与结果，**认 `is_error`** 渲染错误态 |
| `done` | `{summary}` | 回合结束，`finish_reason` ∈ `stop` / `cancelled` / `error`；`session_id` 用来续接 |
| `approval_request` | `{request_id, tool, ...}` | 危险操作审批，**回合阻塞在这里**，超时按拒绝收场 |
| `error` | `{message, code}` | 结构化错误 |
| `tasks` | `{tasks:[...]}` | 任务清单（pending / doing / done） |
| `bg_task` | `{task_id, kind, state, ...}` | **v6** 起的后台任务状态，按 `task_id` upsert |
| `bg_slots` | `{bg_used, bg_max, agents_used, agents_max}` | **v7** 起的槽位快照；`agents_max = 0` 表示该入口不启用子代理，别画一个永远不动的假账 |

这里有个值得学的工程习惯：**协议是加法的**。v6 加 `bg_task`、v7 加 `bg_slots`，客户端规则只有一句——**不认识的 `type` 直接忽略**。所以旧宿主接新 cjh 不会崩，新宿主接旧 cjh 只是少几个面板。逐版演进记录就写在 `src/web/capabilities.cj` 顶部注释里。

---

## 六、前端读帧：四个必踩的坑

### 坑 1：帧解包必须先认 `p.type`

`delta` 帧自带 `text` **裸字段**，不是包在 `{data: ...}` 里的。先按包装体解会直接抛异常。顺序固定：

```js
function onFrame(raw) {
  const p = JSON.parse(raw);
  // ① 先认 type ② delta 的 text 是裸字段 ③ 再试 data ④ 最后才整体 parse
  if (p.type === "delta") return appendText(typeof p.text === "string" ? p.text : (p.data?.text ?? ""));
  if (p.type === "tool_start") return openToolCard(p.name, p.args);
  if (p.type === "tool_result") return closeToolCard(p.name, p.content, p.is_error === true);
  if (p.type === "approval_request") return openApprovalCard(p.request_id, p.tool);
  if (p.type === "done") { saveSessionId(p.summary?.session_id); return finishTurn(p.summary?.finish_reason); }
  // 不认识的 type：忽略（前向兼容的唯一正确做法）
}
```

cjnote 和 lingqu 踩的是同一个坑——这不是巧，是"看着像 REST 就用 REST 的思路解"的必然结果。

### 坑 2：审批卡不会自己冒出来

cjh **默认宽松模式**：`settings.json` 里没有 `capability` 段就等于所有工具放行。所以你会发现"审批 UI 写好了但从来不弹"。要开发/验证审批流，得临时设 `capability.enabled=true` + `approval:["*:*"]`，**验完必须恢复**——注意回写会重排 JSON 格式，改前先备份。

真正的接入建议反过来：**给第三方用户默认严格**。默认全放行适合你自己用，不适合别人的电脑。

### 坑 3：UI 状态只信连接态事件

自动连接 + 退避重连；`session_id` 接住之后发 `resume_session` 拉回历史。**不要用"发消息没报错"当连接判据**——断连时消息也能发出去，只是没人回。

### 坑 4：宿主后端代理，前端不要直连

前端直接 `fetch('http://127.0.0.1:8765/api/...')` 会撞 CORS，还会绕过宿主的能力白名单。正确姿势是宿主后端提供命令（lingqu 的 `t2h:cjh_models` 就是这样），前端走 IPC。**唯一例外是 WebSocket**：`ws://127.0.0.1:8765/ws` 页面可以直连（cjnote 就是这么做的），因为 WS 没有同源策略那道墙。

---

## 七、三个已经跑起来的真实案例

协议文档最怕"纸面正确"。下面这三个应用都是真机跑通的，其中两个的开源实现可以直接抄。

### 案例一：cjnote —— AI 原生 Markdown 笔记

[cjnote](https://atomgit.com/qq8864/cj-tauri) 是仓颉 + cj-tauri 写的桌面笔记应用，后端静态编译，前端就是系统 WebView。它把 cjh 当"随包分发的本地大脑"：

![cjnote 的 AI 助手面板](https://raw.gitcode.com/qq8864/images/raw/main/cjh/cjnote-ai-panel.png)

*三栏布局最右侧就是 AI 助手：流式逐字上屏、回复按 Markdown 渲染、工具调用单行展示、审批请求内联成卡片。*

它做了这些事，基本把内嵌该有的边界都覆盖了：

| 能力 | 实现方式 |
|---|---|
| AI 助手面板 | 页面经 WS 直连 `ws://127.0.0.1:8765/ws`，逐字落进对话区 |
| 状态胶囊 | 就绪 / 未连接 / 忙 / 出错，四种态如实反馈，不假装 |
| 引用当前笔记 | 勾上把整篇注入消息上下文 |
| 问笔记库 | 勾上先全库检索，再把命中片段喂给 agent |
| 选区动作 | 选中正文 → 重写 / 续写 / 翻译，结果先出 diff 确认条，接受才改文档 |
| 设置页 | 改 Base URL / API Key / 模型 / 协议 / 温度，由宿主写进 cjh 自己的 `~/.cjh`，保存后重启 cjh 生效 |
| 拉起与收尾 | 随包分发、自动拉起、退出收尾；端口上是别人的实例就如实说"需手动重启" |

最后一条尤其值得学：**"这个 cjh 是我拉起的还是别人的"** 这个判断直接决定了能不能杀它。cjnote 的选择是"不是我的就明说，让用户自己动手"，而不是悄悄重启。

### 案例二：ai-chat —— 同一个界面，两条管道

[ai-chat](https://atomgit.com/qq8864/cj-tauri/tree/main/examples/ai-chat) 是 cj-tauri 的 AI 客户端示例，它的设计很有参考价值：**聊天和 Agent 是两个模式，可以一键切**。

![ai-chat 的 Agent 模式](https://raw.gitcode.com/qq8864/images/raw/main/cjh/ai-chat-agent.png)

*Agent 模式：侧栏改成「cjh 客户端」并显示 `cjh: 已连接`，会话 / 技能 / MCP / 文件四个面板就位。*

- **聊天模式**：页面直接打 OpenAI 兼容的 `/chat/completions`，没有 agent，一条流；
- **Agent 模式**：接本机 cjh，聊天流走 WS 长连接，会话 / 技能 / MCP / 文件四个面板走 REST。

两种模式的差别被诚实地表达出来：会话列表**按模式分家**（上半是 cjh 的会话历史，下半是本地会话），各认各的，互不污染。

工程上最值钱的是这个文件：`src/cjh_host.cj`，**862 行仓颉代码**，把前面那六条生命周期语义完整实现了一遍。lingqu 的托管逻辑就是从这里移植的。想接 cjh 但不想从零摸协议，抄它的结构比读文档快。

它另外几处细节也挺讲究：

- **审批卡片**带 `expires_in_ms` 同步倒计时，"批准 / 拒绝"经同一条 WS 回 `approval_response`，超时按拒绝收场、回合继续——不假装能续期；
- **模型透传**：帧里带当前选中的 `model` / `base_url` / `api_key`，按会话级契约**只对本回合生效**、不落盘；
- **MCP 面板只读**：写回走 cjh 自己的 `settings.json`，绕开 GET 掩码 `***` / POST 整体替换那套容易把真密钥抹掉的坑。

### 案例三：lingqu 灵渠迁移台 —— agent 干活，人看面板

![cjh 作为桌面应用的 AI 大脑（lingqu 灵渠迁移台）](https://raw.gitcode.com/qq8864/images/raw/main/cjh/embed-brain.png)

*灵渠迁移台的右侧 AI 助手面板：agent 自动调工具（环境体检）、理解上下文并回复合成，全程运行在宿主本地。*

这个案例代表另一类形态：**宿主不是聊天应用，而是业务工具**。用户不关心"agent 在干什么"，只关心"体检结果给我"。cjh 在这里负责的是"会调工具的那部分"，界面仍然是业务自己的界面。

---

## 八、安全与分发：两条不能省

**其一，只绑回环 + 开着鉴权。** `cjh web` 默认绑 `0.0.0.0` 且默认无鉴权——这是给"我自己在局域网里用"留的默认值，宿主拉起时**必须**显式 `--bind 127.0.0.1`；要跨进程共享的话配 `--token`，配了之后 `/api/*` 一律要带。

**其二，随包二进制必须过 SHA256 校验。** 供应链防线很简单也很难被绕过：`vendor/cjh/<platform>/cjh` + `SHA256SUMS` 入库，拉起前逐文件校验，**验不过既不解包也不执行**。lingqu 的做法就是这样。

另外还有两层是 cjh 自己的：三域 capability 白名单（命令 / 工具 / 资源）+ 危险操作审批链；以及仓颉语言层的类型与内存安全。宿主集成给第三方用户时，**建议默认严格模式**，别把个人用的宽松默认直接发出去。

有个平台边界要提前知道：**鸿蒙端 cjh 没有 ws 能力位**，对话通道需要另设计，不能照搬桌面这套。

---

## 九、最小接入清单

照这六步做就能通：

1. 拉起 `cjh web --port 8765 --bind 127.0.0.1`（隐藏窗口），轮询 `/api/health` 到 200；
2. WS 连 `ws://127.0.0.1:8765/ws`，发 `{type:"chat", message:"..."}`；
3. 解帧（按 §6 坑 1 的顺序）：`delta` 节流累积 → `tool_start/tool_result` 出工具卡（认 `is_error`）→ `done` 认 `finish_reason` 并存 `session_id`；
4. `approval_request` 出审批卡，超时按拒绝回 `approval_response`；
5. 重连时先 `resume_session`；
6. 退出时只收自己拉起的实例（守护线程，多轮收尾）。

```bash
# 宿主侧的"拉起 + 等就绪"最小实现
cjh web --port 8765 --bind 127.0.0.1 &
for i in $(seq 1 100); do            # 100ms × 100 = 10s，超时不算成功
  if curl -fsS http://127.0.0.1:8765/api/health > /dev/null; then
    echo "cjh ready"; break
  fi
  sleep 0.1
done
```

---

## 十、为什么这件事值得单独写一篇

因为"把 agent 嵌进应用"正在变成一件普通需求：你的笔记应用想有 AI、你的迁移工具想会体检、你的客户端想能干活。而大多数方案要么让你绑死一个云服务，要么让你在自己的进程里养一个随时可能崩的 agent。

cjh 给的是第三条路：**一个 18 MB 的单文件，一条 `cjh web` 的命令，两个标准通道（REST + WebSocket），六条踩出来的生命周期语义**。宿主管好进程，agent 管好工具，界面归你自己。

它的"小巧"不是审美，是能嵌进去的前提——18 MB 才敢随包分发，零依赖才敢让用户直接开箱用，单文件才敢说"升级就是换个文件"。

**相关链接**

- cjh 仓库（含 `docs/集成指南.md`，协议权威定义在 `src/web/{rest_api,protocol}.cj`）：<https://atomgit.com/qq8864/cjh>
- cj-tauri 仓库（`examples/ai-chat` 的 862 行托管实现、cjnote）：<https://atomgit.com/qq8864/cj-tauri>
- 在线官网：<https://yangyongzhen.github.io/cjh/>
- 本文配图与图示源文件：<https://atomgit.com/qq8864/images/tree/main/cjh>

许可证 MIT，接入代码随便抄；协议帧要改，记得按 `capabilities.cj` 的加法规则来——**旧客户端不该因为新帧而崩**。
