> **重要：这只是背景资料，不是本包的依赖。**
> `org-quote-link` 只依赖 Org（`org`/`org-element`/`org-id`/`ol`），不会
> require、加载或调用 org-transclusion / org-transclusion-blocks。本文只是
> 为了考证 Org 链接与 block 格式的行为、并记录可选互操作（`#+HEADER:
> :transclude [[...]]` 恰好也能被 org-transclusion-blocks 识别）而整理的
> 源码笔记；文中引用的那些包的行号/函数名不代表运行时依赖。
>
# org-quote-link 参考：org-store-link 范围 / org-link-open / org-transclusion-blocks

> 目的：为 `org-quote-link` 判断“哪些链接可以转换”、生成 `#+HEADER: :transclude [[...]]` + quote
> block，以及保证之后能用 `org-transclusion-blocks-add` 刷新，提供源码级依据。
>
> 取证：`/home/riko/emacsd.git` HEAD 的 ELPA 快照本地副本 `/tmp/oql-ref/`；行号以此处 `.el` 为准。
> `org-transclusion` 1.4.0（emacs 27.1/org 9.4，OT:26）、`org-transclusion-blocks` 0.4.0
> （emacs 29.1/org 9.7，OTB:10）、Org 10.0pre0.20261018.945；系统 Emacs 27.1/Org 9.3 用于实测
> （脚本 `/tmp/oql-ref/{fetch,e2e,pos,refresh,kw,num,fuzzy2,search2,search3,storeq,idparse}.el`）。
> 用户扩展 `/home/riko/emacsd.git/org-transclusion-blocks-heading.el`（裸库未跟踪文件，445 行）。
>
> 缩写：OT=`org-transclusion.el`、OTB=`org-transclusion-blocks.el`、OBT=`org-transclusion-blocks-types.el`、
> OL10=`ol-10.0pre.el`、OL93=`ol-9.3.el`、OE10=`org-element-10.0pre.el`、OSRC10=`org-src-10.0pre.el`、
> OID10=`org-id-10.0pre.el`、OID93=`org-id-9.3.el`、DEN=`denote.el`、CFG=`config.org`、HE=用户 heading 扩展。
## 0. 结论摘要

1. 运行时“org-store-link 可产生”的判定：`(or (member type '("file" "id")) (org-link-get-parameter type :store))`；
   `file`/`id` 是核心逻辑直接产生、没有 `:store` 参数。仅当链接**当前解析出的 type** 满足此式才转换。
2. 注意“注册了 `:store` 的类型”≠“存出来的链接仍是该 type”：eww/w3m 的 store 把 `:link` 写成裸 URL，
   bibtex/irc(log)/image/dired 写成 `file:` 链接——实际落盘链接会按 `https:`/`file:` 解析。
3. `file:...::行文本` 在 `org-link-search-must-match-exact-headline` 为 t 时报错、为默认
   `query-to-create` 时会弹 “create heading?”；只有绑成 nil 才是纯文本匹配（9.3 实测，见 §2）。
   blocks-add 内部固定绑 t，所以文本搜索目标必须改写为 `::行号`（或 `:transclude-lines`）才能刷新。
4. fuzzy `[[标题]]`、`[[#custom-id]]`、裸 `https:` 等 org-store-link 不产生的类型默认不转换；用
   `org-quote-link-link-handlers`（TYPE→handler）扩展，默认内置 denote handler（§6）。
5. 同文件 fuzzy 标题链接进入 blocks 后，用户 heading 扩展默认按 `:only-contents` 取内容、丢标题行
   （HE:83-93、293-304）；要“标题行+子树”，header 里必须存规范化后的 `file:<abs>::*标题`（§5）。
## 1. org-store-link 产生的链接类型
### 1.1 机制

- `org-store-link-functions` 遍历 `org-link-parameters`，对每个 type 取
  `(org-link-get-parameter type :store)`，非 nil 则收进 store 函数列表（OL10:1656-1685；OL93:888-916；
  `org-link-get-parameter` OL10:1325-1330、OL93:684-689）。`org-store-link` 先跑这些外部函数
  （OL10:2680-2699；OL93:1401-1430），无命中再走内置分支；store 函数经 `org-link-store-props
  :type/:link/:description` 交付结果，最终存的是 `:link` 原文（不存在“自动加 type 前缀”），故 §0-2
  的落盘 type 漂移成立。
- 内置分支只处理 file/id/calendar/help/w3/image/dired/coderef 等（§1.2/1.3），**不覆盖**模糊链接与
  `[[#cid]]`：前者只是 fallback 解析类型，后者由 `org-store-link` 以 `file:...::#cid` 形式产生
  （OL93:1608-1613；OL10:2818-2828）。
### 1.2 Org 9.3（Emacs 27.1 bundled）

| 来源 | 关键位置 | 存储的链接字符串 |
|---|---|---|
| Org buffer：标题 | OL93:1556-1586 | `file:<abs>::*Heading`（`org-link-heading-search-string`，OL93:1194-1212） |
| Org buffer：`#+NAME:` 元素 | OL93:1561-1578 | `file:<abs>::name` |
| Org buffer：`<<target>>` | OL93:1529-1535 | `file:<abs>::target`（不带 `<<>>`） |
| 交互调用额外存 custom-id | OL93:1608-1613 | `file:<abs>::#cid` |
| 区域文本 | OL93:1560-1586 | `file:<abs>::文字`（空白压成单空格） |
| 非 Org 文件 buffer | OL93:1587-1598 | `file:<abs>` 或 `file:<abs>::当前行文本` |
| dired / image-mode | OL93:1501-1518 | `file:<abs>`；image 设 `:type image`，dired 不设 type |
| src 编辑 buffer 的 coderef | OL93:1431-1462 | `file:<src>::(label)`；无源文件时 `(label)` |
| `org-create-file-search-functions` | OL93:1519-1523 | `file:<abs>::<search>` |
| `(featurep 'org-id)` 且 `org-id-link-to-org-use-id` 命中 | OL93:1536-1554；OID93:661-675 | `id:UUID`（**无** `::search`） |
| calendar-mode | OL93:1476-1484 | 时间戳文本 `[[<...>]]`（`:type` calendar，落盘是 fuzzy） |
| help-mode | OL93:1486-1492 | `help:SYMBOL`（9.3 的 help 只有 `:follow`，OL93:1270） |
| w3-mode | OL93:1493-1500 | 裸 URL → 落盘为 `https:`/`http:` 链接 |
| 注册了 `:store` 的模块 | 见下 | 多为自己拼好的 typed link |

9.3 的外部 `:store` 注册（type + 文件:行）：bbdb=ol-bbdb-9.3.el:218、bibtex=ol-bibtex-9.3.el:482、
docview=ol-docview-9.3.el:53、eshell=ol-eshell-9.3.el:32、eww=ol-eww-9.3.el:59、gnus=ol-gnus-9.3.el:81、
info=ol-info-9.3.el:43、irc=ol-irc-9.3.el:76、mhe=ol-mhe-9.3.el:77、rmail=ol-rmail-9.3.el:46、
w3m=ol-w3m-9.3.el:49。链接形式：gnus=`gnus:group#id`、mhe=`mhe:folder#id`、rmail=`rmail:file#id`、
bbdb=`bbdb:name`、info=`info:file#node`、docview=`docview:file::page`、eshell=`eshell:...`；
bibtex 存 `file:...#key`、eww/w3m 存裸 URL、irc 在 `org-irc-link-to-logs` 时存 `file:...::行`。
9.3 的 `id` 只有 `:follow`（OID93:704），`org-store-link` 直接在内置分支调 `org-id-store-link`
（OL93:1536-1554）。外部包 denote（ELPA）在两版都可注册 `:store`（§1.3、§6.3）。
### 1.3 Org 10.0pre（vendored）

- `file:`：核心经 `org-link--file-link-to-here`（OL10:1084-1094）+
  `org-link-precise-link-target`（OL10:2049-2116）产生。search 串优先级：
  区域文本 → `<<target>>` → `#+NAME:` → before-first-heading 的当前行文本 → 标题的 `#cid` 或
  `*Heading`（`org-link-heading-search-string`，OL10:2014-2034）；非 Org buffer 用当前行文本。
  归一化 `org-link--normalize-string`（OL10:982-1008：压空白、去统计 cookie、去 `#`/括号等
  search 语法）。内置分支：coderef OL10:2705-2741、agenda 2743-2749、calendar 2751-2761、
  image 2763-2767、dired 2769-2777、file-search 2779-2788、Org 2790-2796、非 Org 2798-2804。
- `id:`：org-id 注册 `:store #'org-id-store-link-maybe`（OID10:947-951）；`org-id-store-link`
  在 `org-link-context-for-files` 与 `org-id-link-use-context`（默认均 t，OL10:504、OID10:159）
  同时为真时追加 `::SEARCH`（OID10:794-843），于是产生 `id:UUID::*Heading` / `::#cid` / `::行文本`。
  `org-id-open` 自己按 `::` 拆开、narrow 到子树后调 `org-link-search option nil ...`（OID10:865-915，
  显式传 must-match=nil）。
- `help:`：注册 `:store #'org-link--store-help`（OL10:2490-2507）；`shortdoc:`（Emacs≥28）：
  OL10:2528-2553。9.3 的 help 是内置分支，10.0pre 改为注册类型；calendar 仍为内置分支
  （OL10:2751-2761），9.3 核心的 w3-mode 分支在 10.0pre 被删除。
- 外部模块注册与 9.3 相同，另加 `man`（ol-man-10.el:35-39，store 84-94）；`doi` 无 `:store`。
- 外部包 denote：`denote-link-ol-store`（DEN:7198-7245）产出 `denote:ID`、`denote:ID::#CUSTOM_ID`、
  `denote:ID::*Heading`（`denote-org-store-link-to-heading` 为 `local` 时是裸 `[[*Heading]]`）；
  `:store` 经 `eval-after-load 'org` 注册（DEN:7282-7297），与 Org 版本无关。
- `id` 注册 `:store` 只在 Org 10；Org 9.3 的 org-id 只有 `:follow`（§1.2）。
### 1.4 search 串对照

| store 写法 | org-link-search 分支（OL10 / OL93） | 需要 `must-match` |
|---|---|---|
| `::*Heading` | headline 搜索 OL10:1945-1950 / OL93:1125-1148 | t、nil 都可 |
| `::#custom-id` | custom-id OL10:1888-1897 / OL93:1066-1077 | 都可 |
| `::name` | `#+NAME` OL10:1931-1944 / OL93:1110-1124 | 都可 |
| `::target` | target OL10:1918-1930 / OL93:1097-1109 | 都可 |
| `::(label)` | coderef OL10:1898-1917 / OL93:1078-1096 | 都可 |
| `::N`（数字） | 交给 `org-open-file` 的 line 参数（OL10:2128-2138） | 都可 |
| `::行文本`/区域文本 | 字面文本搜索 OL10:1985-2008 / OL93:1165-1187 | **必须 nil** |
| `::/regexp/` | `org-occur`，不移动 point（OL10:1883-1887） | 不可用 |
## 2. org-link-open 如何消费这些 search 串

- 文件链接经 `org-link-open` → `org-link-open-as-file`（OL10:1746-1799、2118-2138）→
  `org-open-file`，search 交给 `org-link-search`（Org 10 org.el:8617；9.3 org.el:8580）。
- `org-link-search` 分支顺序决定了文本搜索的陷阱：headline/target/name 等分支在前，默认
  `org-link-search-must-match-exact-headline` = `query-to-create`（OL10:418）——普通正文文本即使存在，
  也会先进入 query 分支弹 `yes-or-no-p`（OL10:1956-1978），拒绝后报 “No match”；值为 t 则直接报错
  （OL10:1979-1984）。9.3 实测：`Body line two` + t → ERROR；+ nil → 命中第 11 行；
  默认 query-to-create → `yes-or-no-p` 被调用后 ERROR。
- 结论：package 自己打开链接做“文本/区域”搜索时应绑 nil；带 `*`/`#`/NAME/target/数字/coderef 时可绑 t
  （org-transclusion 的 fetcher 固定绑 t，见 §3）。
- `id:UUID::*Heading` 的 `::search` 在 **Org 9.3 的 `:path` 里**（9.3 实测 id type 的 :path
  =`UUID::*Head`，:search-option=nil；9.3 也不支持后续搜索，OID93:677-703）；Org 10 解析同样把
  `::` 留在 `:path`（OE10:4016-4038 只对 `file*` 拆 search-option），由 `org-id-open` 拆分处理。
  因此 handler 里若要拿 search，必须自己按 `::` 切分 `:path`，不能依赖 `:search-option`。
## 3. org-transclusion / org-transclusion-blocks 兼容
### 3.1 fetcher 分发（实测 hook 顺序，Org 9.3 加载后）

`(org-transclusion-add-src-lines org-transclusion-add-org-id org-transclusion-add-org-file
org-transclusion-add-other-file)`；默认值见 OT:220-225，src-lines 扩展加载时 prepend
（org-transclusion-src-lines.el:51）。

| 链接 | 命中 fetcher | 取到的文本 |
|---|---|---|
| `file:...::*H` / `::#cid` / `::name` / `::target` | `add-org-file`（OT:1188-1221） | 定位元素（标题元素=标题行+子树），interpret 后返回 |
| `file:...::行文本` | `add-org-file` → 打开失败 | 报错（§2；org-transclusion 绑 t，OT:1127） |
| `file:...::N` | `add-org-file` | 第 N 行所在元素 |
| `file:<abs>`（无 search） | `add-org-file` | 整个 buffer；首段由 `org-transclusion-include-first-section` 控制（OT:91-95；CFG:5135 为 t） |
| `file:<非 org>` | `add-other-file`（OT:1223-1240）或 src-lines | 整个 `buffer-string`，原样、不 escape；`:lines` 走 src-lines |
| `id:UUID[::search]` | `add-org-id`（OT:1170-1186） | before-first-heading 整段；否则标题元素 |
| fuzzy `[[*H]]` | heading 扩展（优先）或 `add-org-file` | 扩展：默认 only-contents；否则整个当前 buffer |
| `denote:` 等其它 typed link | `add-other-file`（无 type 判断，类型检查被注释掉） | 整个打开的 buffer 纯文本 |

`add-other-file` 没有 type 守卫（OT:1223-1240），所以任何前面 fetcher 不认的链接都会“整 buffer 当
纯文本”；没有 fetcher 的 typed link 用 blocks-add 刷新会得到错误内容，**这是 handler 扩展必须处理的**。
### 3.2 内容规则（fetcher 内部生效 vs 被跳过）

标题元素取整棵子树、**包含标题行**；`org-transclusion-exclude-elements` 默认 `(property-drawer)`
（OT:85-89）删属性抽屉，`:exclude-elements` 只能追加（OT:1460-1510）。末尾空行保留
（`:post-blank`；OTB:652-671 只补换行不 trim）。`:only-contents` 删解析树中**所有** headline 行
（OT:1522-1534）。`:expand-links`/`:exclude-elements`/`:only-contents`/first-section 在 fetcher 内生效；
`:level`/`:no-first-heading` 只在 content-format（OT:263、1331-1393）处理，blocks 的 `--fetch-content`
直接取 `:src-content`（OTB:1281-1301）→ blocks 路径**不生效**。
### 3.3 blocks 最小格式、刷新位置、元数据

```org
#+HEADER: :transclude [[file:/abs/x.org::*Head]]
#+begin_quote
,* Head
body
#+end_quote
```

- `--supported-block-p` 接受任何非 inline `*-block`（OTB:611-623）。头行解析：
  `--parse-headers-direct` 正则 `^:\([^ \t]+\)\(?:[ \t]+\(.+\)\)?$`（OTB:733-756），`:transclude` 值以
  `[[` 开头原样保留，否则 `org-link-make-string`（OBT:400-410），再拼 `#+transclude:` 临时解析
  （OT:898-908、OBT:432-504）。多条 HEADER 必须紧贴 begin：空一行会让 header 变孤立 keyword、块失去
  `:header`（9.3 实测）。正文可先有文字，add 整体替换（OTB:674-699）。
- 内容边界（非 src-block）：`:begin` 起跳过连续 HEADER 行，下一行须是 `#+begin_`，再下一行=起点；
  向后找第一个 `^[ \t]*#+end_`（任意块类型）行首=终点（OTB:625-650）——未转义的 `#+end_xxx` 会截断。
- **位置要求**：只在 `#+HEADER:`/`#+begin_`/`#+end_` 行可用（at-point 返回块元素）；正文段落上报
  “Not on a supported block (point on: paragraph)”（9.3 实测）。add 末尾重解析并校验边界，失败即
  `error` 且**不在 `atomic-change-group` 内**，可能留下半写入正文（fuzzy 场景实测）。
- 元数据：正文区 text property `org-transclusion-blocks-fetched`（OTB:1506-1518）；整个块（含 header）
  写 `org-transclusion-blocks-keyword/-link/-max-line`、`org-transclusion-type/-id/-pair`
  （OTB:1397-1464），并建源/块 overlay（OTB:1356-1395）。blocks **不**设 `read-only`；同 buffer 若开
  `org-transclusion-mode`，保存钩子按 `org-transclusion-id` 尝试 remove-all（OT:847-855）但因缺
  `org-transclusion-orig-keyword` 而失败——别开。
### 3.4 escape

用 `org-escape-code-in-region`（OTB:1264-1279；OSRC10:836-844，9.3 相同）：只给行首（允许前导空白与
已有逗号）以 `*` 或 `#+` 开头的行加逗号；列表/表格/drawer 不转义（实测 `,* Head`、`,#+begin_quote`、
`- item` 保持）。`--should-escape-p`（OTB:582-609）：`:transclude-escape-org` header 显式覆盖
（nil/no/false/0 为否）；否则当 `org-transclusion-blocks-escape-org-sources`（默认 t，OTB:175-197）且
`--source-is-org-p`（OTB:556-580，启发式：`[[file:...org`、`[[id:`、`[[#`、`::`+空格+`*`）为真时
escape。非 Org 源默认不 escape；若 package 决定 escape，必须在 header 加 `:transclude-escape-org t`，
否则 blocks-add 刷新不 escape、前后不一致。未 escape 的非 Org 文本中 `*`/`#+end_quote` 行会破坏块。
## 4. 用户 heading 扩展的实际影响

- 只接管 fuzzy/无 type 的纯标题链接且仅在 blocks block 内（HE:143-152、353-357），先于其它 fetcher
  （HE:402-415）。默认 `include-headline=nil` → 追加 `:only-contents`（HE:83-93、293-304）→ 结果
  **不含任何标题行**；设 t 才保留。按当前 buffer 查标题（含自引用/多重匹配/行范围，HE:306-371），并
  advice `--source-is-org-p`/`--get-source-line-count`（HE:373-400）。
- 若 header 保留 `[[*标题]]`，blocks-add 刷新必走该扩展→默认丢标题行；若扩展未装，则落到
  `add-org-file`→把整个当前 buffer 塞进来，实测报 “Invalid block boundaries…” 并留下半写入正文。
  故 header 必须存 `file:<abs>::*标题`。
## 5. 推荐的 header 语法（保证 blocks-add 可刷新）

原则：header 里放**规范化、可复现同一内容**的链接；只接受 §0-1 判定通过的 type（或 handler 改写后的）。

| 原链接 | 写进 `:transclude` 的形式 |
|---|---|
| `[[*标题]]`、`[[标题]]`（同文件 fuzzy，经 handler 或包内特判） | `[[file:<当前文件绝对路径>::*标题]]` |
| `[[#custom-id]]`（手工类型，org-store-link 不产生） | `[[file:<当前文件绝对路径>::#custom-id]]` |
| `file:...::*Heading` / `::#cid` / `::name` / `::target` | 原样（建议补绝对路径） |
| `file:...::行文本`（store-link 的区域/行文本） | 改写 `[[file:<abs>::<命中行号>]]`（实测可刷新）或 `:transclude-lines A-B` |
| `file:<abs>`、`file:<非 org>` | 原样；非 Org 若要 escape 加 `:transclude-escape-org t` |
| `id:UUID` / `id:UUID::search` | 原样；须先 `(require 'org-id)`，否则退化为 fuzzy→整 buffer |
| 有 `:store` 的其它 typed link（且 handler 未改写） | 原样；但 blocks-add 无 fetcher，刷新结果可能是整 buffer（§3.1） |

可选第二 header（均须紧贴 begin）：`#+HEADER: :transclude-keywords ":only-contents :expand-links"`、
`#+HEADER: :transclude-lines 10-20`、`#+HEADER: :transclude-escape-org t`。
不要用 src-block：其 header 走 Babel，需要 CFG:5142-5152 的 `org-babel-read` advice。

hard constraints：①`#+HEADER:` 必须紧接 `#+begin_<type>`，行内不能折行；②形式
`[缩进]#+HEADER:<空格>:transclude<空格>[[单行链接]]`，描述不能含 `]]`；③刷新只认第一个 `:transclude`
（OBT:400-410 `assoc-default`）；④自包含目标（标题子树含本 block）会在刷新时自我嵌套，生成/刷新
都要先做自引用检查；⑤要与 blocks-add 结果完全一致，需照 §3.2/§3.4 的 drawer/末尾空行/escape 规则。
## 6. handler 扩展接口契约
### 6.1 运行时资格判定

```elisp
(defun org-quote-link-store-link-type-p (type)
  "Non-nil when TYPE is produced by `org-store-link'."
  (or (member type '("file" "id"))          ; 核心输出，无 :store 参数
      (and (fboundp 'org-link-get-parameter)
           (org-link-get-parameter type :store))))
```

`id` 需先 `(require 'org-id)`（否则 `[[id:...]]` 在 Org 9.3 被解析为 fuzzy；10.0pre 也依赖 org-id 已
加载，OID10:947）。不满足此式且不在 handler alist 中的 type（fuzzy、custom-id、https、mailto、
elisp/shell 等）默认拒绝。
### 6.2 契约

```elisp
(defcustom org-quote-link-link-handlers
  '(("denote" . org-quote-link--denote-handler))
  "TYPE -> handler: (LINK PLIST) -> nil 或不处理；或以下 plist：
:link 改写后的链接字符串（随后走通用 open+quote）；:content 直接文本；
:org-p 文本是否 Org（决定 escape）；:kind heading|element|file；:desc 可选描述。"
  :type '(alist :key-type string :value-type function))
```

流程：读链接 → type 命中 handler？→ 返回 `:link` 则按新链接重跑“打开 + 取标题/元素/整个文件 +
escape”；返回 `:content` 则直接转义/规范化后写入；返回 nil 时仅 §6.1 判定通过的 type 走通用流程，
否则 `user-error`。
### 6.3 denote handler（改写为 file: 链接，可刷新）

```elisp
(defun org-quote-link--denote-handler (link _plist)
  (let* ((path (org-element-property :path link))     ; "ID" 或 "ID::SEARCH"
         (id   (car (split-string path "::")))
         (file (denote-get-path-by-id id)))
    (unless (and (stringp file) (file-exists-p file))
      (user-error "Denote target not found: %s" path))
    (list :link (org-link-make-string
                 (concat "file:" (expand-file-name file)
                         (when (string-match "::\\(.*\\)\\'" path)
                           (concat "::" (match-string 1 path))))))))
```

denote store 形式有 `denote:ID`、`denote:ID::#CUSTOM_ID`、`denote:ID::*Heading`（DEN:7198-7245；`:store`
在 `eval-after-load 'org` 时注册，DEN:7282-7297）；`denote-link-ol-follow` 把 search 交给
`org-link-open-as-file`（DEN:7139-7153），所以改写为 file: 后 blocks-add 能正常刷新。注意 denote 的
`::search` 留在 `:path`（非 file type 不拆 `:search-option`，§2）；`denote-org-store-link-to-heading` 为
`local` 时 store 可能产出裸 `[[*Heading]]`（DEN:7211-7221），属 fuzzy，默认超范围。
### 6.4 直接给内容的自定义 type（不依赖 fetcher）

```elisp
(defun myapp-quote-handler (link _plist)
  (let ((buf (myapp--text-buffer (org-element-property :path link))))
    (unless (org-quote-link--text-buffer-p buf) (user-error "Not a text buffer"))
    (with-current-buffer buf
      (list :content (buffer-substring-no-properties (point-min) (point-max))
            :org-p (derived-mode-p 'org-mode) :kind 'file))))
```

用于 `:follow` 只返回不可引用 buffer（或需专门 API）的类型。**代价**：该 block 无法用
`org-transclusion-blocks-add` 刷新——只能用 package 自己的刷新命令（同样走 handler）；要 blocks-add
兼容需为该 type 注册 `org-transclusion-add-functions` fetcher 或改写成 `file:` 链接。
### 6.5 通用 open+quote 的注意事项

- 用 `org-link-open`（:follow 语义）打开：`save-window-excursion` + `save-excursion`，检查得到的是文本
  buffer；不保证切 buffer（browse-url 类）时应 `user-error`。`eww`/`w3m` 的 store 落盘是 URL
  （type=https，无 `:store`）→ 默认拒绝，符合“只转换 store-link 产物”。
- gnus/rmail/mhe/bbdb/irc 等打开邮件/会话 buffer：文本可取，但“标题/元素”语义不适用，按整个 buffer
  引用；`:org-p nil` → 默认不 escape（§3.4 风险照旧）。alist 顺序优先，handler 返回 nil 继续。
- **非 `file:` 类型的 `::search` 都在 `:path` 里**（id/denote/orgit…，§2）；handler 要自己按 `::` 切分，
  不能读 `:search-option`。Org 9.3 的 `id` 根本不支持 search（OID93:677-703）。
## 7. Org 元素解析：`#+HEADER:` 在 9.3 与 10.0pre

- 两版都把 `HEADER` 列入 affiliated keywords（OE10:353-358）且在 multiple keywords 中
  （OE10:368-371），`:header` 是字符串列表。9.3 用 cons（顺序相反），10 用 nconc；
  `--parse-headers-direct` push+nreverse 两版都能还原（OTB:733-756）。
- 块解析器以第一个 header 行为 `:begin`、以 `#+begin_` 行为 `:post-affiliated`（OE10:2175-2223，
  9.3 同）；`org-element-at-point` 在 header 行返回块元素（9.3 实测 `begin=1`）。正则
  `[ \t]*#\+...`（OE10:408-423）允许缩进，list 内缩进块实测可解析；header 与 begin 之间空行 →
  header 独立 keyword、块无 `:header`（实测）。
- `org-element-interpret-data` 会重输出 affiliated 关键字（OE10:5623、5633-5688），名字 downcase 为
  `#+header:`，大小写不敏感匹配仍可识别。
- `org-element-at-point` 在块正文段落上返回 paragraph（OE10:8536-8627 只在 element 是 section 时上溯）
  ——这是 §3.3 位置限制的根因。
## 8. 工程陷阱

- `org-link-open` 有副作用（开 buffer/移动 point）；org-transclusion 用 `display-buffer-no-window` +
  `save-excursion` 规避（OT:1117-1140）。`org-transclusion-blocks--get-source-line-count` 直接
  `org-link-open` 且未绑 must-match（OTB:1486-1504）；目标标题被删时会因默认 `query-to-create` 弹
  `yes-or-no-p`，批量环境会卡住。
- 目标不存在/无权限：fetcher 抛 `user-error`（OT:1136-1140），blocks-add 不吞错误；生成阶段先校验
  `file-exists-p` / `org-id-find` / denote id。
- `::N`、`:transclude-lines` 都是快照，源文件编辑后行号漂移；`org-element` cache 在程序写入后可能过期
  （blocks 的做法是回到 `:begin` 重新 at-point，OTB:1681-1690）。非 Org 源不 escape 时行首
  `*`/`#+end_quote` 会破坏块；quote 内容中 `#+HEADER:` 会被当 affiliated keyword（解释为 `#+header:`）。
