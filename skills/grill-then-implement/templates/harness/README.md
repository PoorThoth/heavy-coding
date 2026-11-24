# harness/ —— 仓库自带的验收装置（convention）

> 出处：Hermes 工作流 v4.3（2026-10-08），吸收 2026「harness engineering」范式（Agent = Model + Harness）。
> 目的：把「每次现写验收器」变成**仓库资产**——任何人/任何代理接手都能一条命令复跑同一套判据。

## 约定

- 目录：仓库根 `harness/`，文件必须叫 `verify_*.py`
- 退出码：**0 = 全部通过**；非 0 = 有判据没过（`harness_kit.Checker` 默认返 2）
- 判据必须**独立于被测代码**：自己按 SPEC/README 口径复算，不许调用被测方的测试来当结论
- 日志：`wfctl harness <dir>` 会把每个验收器的输出落到 `harness/.logs/<name>.log`（该目录由 harness/.gitignore 自动忽略，不污染仓库根 .gitignore）

## 跑

```bash
wfctl harness <dir>              # 跑 harness/verify_*.py 全部，汇总 PASS/FAIL
wfctl harness <dir> --init       # 从模板生成 harness/verify_criteria.py
```

## 写

```python
from harness_kit import Checker, run_cli, parse_table, approx, insert_only_diff, fingerprint

c = Checker("<项目名> 验收")
c.check("CR1 基础费率", lambda: (approx(base_fee(1000), 1.0, 1e-9), "spot=1.0"))
# 也支持 CLI 对拍：
rows, total = parse_table(run_cli(["-m", "pkg.cli", "--from", "2026-09-01"], cwd=repo_root())[1])
c.check("CR10 TOTAL 与独立复算一致", lambda: (approx(total, 我的期望值), f"got={total}"))
c.finish()
```

常用工具（都在 `harness_kit.py`）：`run / run_cli / parse_table / approx / raises / insert_only_diff / fingerprint / file_sha / Checker / repo_root / read`。

## Windows 两个必踩的坑（实测）

1. **不要用 `npx` / `npm` 调子命令**：它们是 `.cmd`，Python `subprocess`（无 shell）找不到，报 `FileNotFoundError: [WinError 2]`；本机 `npm` 也不一定在 PATH。
   ✅ 正确写法：`run(["node", os.path.join("node_modules", "typescript", "bin", "tsc"), "--noEmit"], cwd=REPO)`；构建同理用 `node_modules/next/dist/bin/next build`。
2. **PYTHONPATH 用 `;` 分隔且路径要 Windows 形式**（`cygpath -w`）；用 POSIX 路径 + `:` 会直接 `ModuleNotFoundError`（`wfctl harness` 已代劳）。

## 三条纪律（血泪）

1. **别让验收器依赖被测方的测试**：被测方可以让自己的测试全绿而症状仍在（今天的 miniorder 夹具：现有 7 个测试全绿，实际 3/10）。
2. **先跑基线再改代码**：基线分（如 3/10）是后面一切"改好了"的参照；没基线就没有结论。
3. **验收器自己也会出错**：写完先拿一个**已知坏的**版本跑一遍，确认它真能 FAIL（拿现状跑 = 天然反例）。
   实战做法（2026-10-08，情侣网站 harness）：**每一条判据都植入一个对应回归到沙箱里**，逐条验证它 FAIL——
   例如把 `preload="metadata"` 改成 `"none"`、删掉未登录 `redirect('/login')`、在中间件 `catch` 里写 cookie、新增一个直连 db 且无动态标记的页面。
   **没做过反例测试的验收器，全 PASS 只是“没报错”，不是“没问题”。**

## 判据的假信号与假通过（实测，每条都配了反例）

假红与假通过的代价一样大：**假红**会让你去改本来没问题的代码，**假通过**会让你带着缺陷发版。两类都要用反例钉住。

### 三种假红

- **注释/文档串命中**：判 `error.message` 是否泄露时，一句“不回传 error.message”的**注释**会被当成泄露 ⇒ 先剥 `//` 与 `/* */` 再判。
  剥注释要**保持换行数**（块注释用等量换行替换），剥完 `文件:行` 才仍然准。
- **归一化只做在一半判据上**：剥注释/免判聚合这类“归一化”必须放进**同族判据共用的那个 helper**（如一份 `prod_go(repo)`），
  否则会出现“CR3 剥了、CR1/CR4 没剥”的不对称 —— 平时 0 命中看不出来，等真出现一句形如「这里**不能**写 CREATE INDEX」的注释就假红。
- **“聚合查询不需要 ORDER BY”不能只看首个函数名**：`SELECT COALESCE(MIN(open_time),0), COALESCE(MAX(open_time),0) FROM klines`
  按“SELECT 紧跟 SUM/COUNT/…”判定会漏（外面包了 COALESCE）。
  ✅ 现在的判据：**按顶层逗号把 select 列表切开（括号内逗号不算），每一项都含聚合函数才算聚合**；
  `SELECT symbol, COUNT(*)` 这种混合选择列按“返回行”处理（组内顺序同样不保证）。
  ⚠️ **取不到 select 列表时保守当“返回行查询”**——宁可假红（看得见、好修），绝不假绿（静默放过真问题）。
- **往前开窗口找关键字要用 `rfind`（最近的锚点）**：从 `FROM klines` 往前找 `SELECT` 时光用 `search` 会串到**上一条 SQL**，
  实测把 `COUNT(*) FROM klines` 判成“返回行查询” ⇒ 假红。同类“往前找上一句”的写法都要用 rfind。
- **“后面有没有 X”别卡死字符数**：拼串场景 X 常在几行之后才追加（实测：`query += " ORDER BY open_time DESC"` 在 9 行之后）
  ⇒ 按“**同一函数体内**”（`\n}\n` 定位函数结束，硬上限 1500 字符）取区间，否则漏判/误判。

### 三种假通过

- **零命中 ≠ 干净**：路径/过滤条件写错时判据扫到 0 个文件，会**静默 PASS**。加**扫描下限**（低于 N 个文件即 FAIL，
  并在证据里写“扫描面过小 ⇒ 判据不成立”；N 用环境变量可覆盖以适配小仓库）。CR1/CR3/CR4 这类“扫全仓找违规”的判据都适用。
- **判据自己崩掉 = 看起来没报错**：重构后某条分支调用签名变了，**只有在命中时才会走到那条路径** ⇒ 真发现违规时它抛异常而不是 FAIL。
  **每个分支都要有自己的反例**：不命中分支（现状跑一遍）、命中分支（注入违规）、跳过分支（聚合/非查询样例）。
  只测“现状不报错”的判据，等于从没执行过它发现问题的能力。
- **对拍样本本身不对**：只跑“现状”，从没跑过“已知坏”的版本 —— 见下面三条纪律第③条。

### 正反两面都要测（一条判据两个方向）

改完判据后固定跑两遍：**注入“形似但合法”的内容应仍 PASS**（注释里的关键字、聚合查询、白名单路径），
**注入“真违规”应 FAIL 且给准行号**。只跑其中一个方向：只跑违规版 ⇒ 假红照样发版；只跑合法版 ⇒ 判据可能被削成恒真。

## 给"没有 CI 的仓库"一个真判据（而不是 SKIP）

"CI 必须跑测试"这类判据在无 `.github/workflows` 的仓库里只能 SKIP ⇒ **判据形同没写**。
约定：仓库根放 **`harness/test-entry.txt`**（每行一条命令，`#` 注释）声明**可复跑的测试入口**；
判据改为二选一：CI 里有未被注释的测试命令 **或** 有 test-entry.txt（Go 仓库要求含 `go test`/`go vet`）；
两者都无 ⇒ **FAIL 并告诉该补哪一个**。重档再**逐条真跑** entry（原样报 rc）。
⇒ 换仓库时把"测试入口"锚到**该仓库真实的入口**（Makefile/脚本/npm script 皆可），别照抄别的仓库。

## 前端测试必须走"项目入口"：Node ≥25 会造局部假红

- **现象**：Node ≥25 在 `globalThis` 上注册**实验性原生 `localStorage`**（无 flag 时是返回 `undefined` 的访问器），
  占住全局键 ⇒ vitest 注入 happy-dom/jsdom 全局时装不上 `localStorage` ⇒ 依赖它的用例**成批假红**
  （实测某仓 node v26.7.0 裸跑 3 例假红 + `ExperimentalWarning: localStorage is not available…`，换 node v24.11.1 全绿）。
- **对策**：① 钉版本（`.nvmrc` + `engines` + CI 里显式 `node-version`，**别用 runner 默认值**——默认值会漂移）；
  ② 给一个 `scripts/run-vitest.mjs` 包装器：用 `process.execPath` 起 vitest，**argv 与子进程 `NODE_OPTIONS` 双带**
  `--no-experimental-webstorage`（vitest fork 的 worker **不继承父进程 execArgv**，只加 argv 不够）；
  `test` 脚本指向它 ⇒ 谁跑、用哪个 node、什么 shell，结果都一致。
- **验证纪律**：报"修好了"必须给**同代码换运行时的对照**（坏运行时→好运行时的用例数差异），并确认剩余红例**不是**本坑造成的
  （本次就捞出一条与 node 无关的陈旧断言：测试断言 `opacity-50`、组件写的是 `opacity-40`）。

## 换仓库/换项目时要重新锚定（照抄 ≠ 能用）

- **同步只跟“判据本体”，不跟文件**：多份仓库各挂一套同源 harness 时，用脚本顶部 `HARNESS_REV = "YYYY-MM-DD.N"`
  做机读比对，**只在判据本体变化时同步**；本地适配（测试入口、基线数字、README 措辞）**不强制拉平** ——
  强制拉平会把“锚定本仓库”这条纪律毁掉。

同一份 harness 换到另一个仓库跑，先把三条对齐后再交付：

1. **判据不适用时：能变真判据的就变，不能的就 SKIP 并写原因**（既不假红也不假装通过）。
   例：“CI 必须跑 go test”遇到没有 `.github/workflows` 的仓库——首选是**换成声明式入口**
   （`harness/test-entry.txt`）把它变成真判据；确实无法锚定才 SKIP，并顺手把该仓库真实的测试入口找出来
   （`scripts/*check*.sh` / Makefile / npm script / Taskfile）。
2. **逐条人工分类命中**：跑一遍新仓库，把每个 FAIL 分成「真问题」「判据不适应」「我的误报」三类，前两类都要改（改代码去委托，改判据在此处）。
   误报实例：把 `COALESCE(MIN(...))` 当返回行查询、把注释里的表名当 SQL —— 两类都已内建豁免。
3. **路径/保留名适配**：整仓复制做沙箱时跳过 Windows 保留名（`nul`/`con`/`prn`/`aux`/`com*`/`lpt*`）与 `node_modules`/`.git`/`*.exe`，
   否则 `copytree` 直接 `WinError 87`。

## 前端一致性："测试断言 class ≠ 实现 class"

一条自相矛盾的用例（断言 `opacity-50`、组件给 `opacity-40`）会在**两个运行时下都红**。修完一处必须**全仓扫同类**：
用脚本抽「真正断言 class」的写法（`classes()).toContain('x')` / `toHaveClass('x y')` / `classList.contains('x')` /
`attributes('class')).toContain('x')` / `className).toContain('x')`），回到**该测试 import 的组件**（含子组件、支持 `@/` 别名）里找，
找不到即报 —— 参考实现 `harness/sweep_vue_class_assert.py`（rc=1 可当门禁）。

- **别把 `toContain('文本')` 当 class 断言**：实测这样会把 `expect(x).toContain('available')` 算进去，在另一个仓扫出 **478 条假报**。
- **"实现"的范围必须只限该测试 import 的组件**：把同目录无关 `.vue` 也算进来，别人组件里恰好有该 class ⇒ **把不一致扫成“无问题”**（假绿）。

### 扫描式判据的四类通用假报（实测：同一工具在一个仓库报 43 条，修完口径后 **0 条**）

1. **方向反了**：`expect(el.classList.contains('w-full')).toBe(false)` / `.not.toContain('x')` 是断言"**没有**"该类 ⇒ 必须排除。
   凡扫"断言"的判据，一律先分辨断言极性（含 `toBe(false)`/`toBeFalsy`/`=== false`/`.not.`）。
2. **模块解析不全**：动态 `await import('@/views/Home.vue')`、扩展名省略、`@/` 别名、`index.vue` 都要能解析；
   漏一类就会把整个文件的类误报（本次 43 条里最大一桶）。
3. **路径规范化不一致**：解析结果与索引键必须走同一种 `normpath`，否则拼接键串对不上、**比对基准恒空 ⇒ 全量假报**。
   这是最隐蔽也最致命的一类（报出来的每一条都“看着像真的”）。
4. **词边界过严或过松**：过松 ⇒ `opacity-50` 被 `bg-opacity-50`/`disabled:opacity-50` 命中；
   过严 ⇒ 把 `.` 也当前置排除符，导致 CSS 选择器 `.cls {}` 命中不到、报成"全库没有"。

**流程纪律**：报“扫出 N 条问题”之前，先 **逐条找该类在库里的出处**（工具要输出证据行）；
找不到出处的才叫候选，找得到出处的先归到口径问题上——“43 条”可能一条真的都没有。

### 修之前先弄清“谁漂移了”（别把别人的 WIP 一起提交）

- 同一条不一致可能是**提交态本来就一致、而是在建工作区把它改坏了**。
  先 `git show <HEAD>:<file>` 对比提交态，再决定改哪边；改完用 `git show --stat` 逐文件确认**提交范围只含你自己的改动**。

## CI 接入前先查"是不是已经有别的 job 在跑同一件事"

接到"给 CI 加一步跑 X"的请求时，先搜一遍 `/.github/workflows/*.yml` 里是否**已有**该命令。
本次实际发现：前端套件早已由另一个 workflow（PR 触发、node 已钉）守着 ⇒ 再往新 job 里加同一条 = **重复信号 + 重复烧 CI 分钟**，
推荐保持**单一来源**而不是两边都跑。同理：报"某 job 的真实 rc"前先确认**提交态里到底有哪些文件**
（本次提交态只有 1 个前端测试文件，其余还在工作区 ⇒ CI 跑的套件 ≠ 本地跑的套件，“绿”也不能拿来当证据）。

## 其它固定坑与豁免（照抄即可）

- **裸 Node 无法 import Next 的 route**：`import { GET } from "./src/app/api/x/route.ts"` 会报 `ERR_MODULE_NOT_FOUND: 'next/server'`
  （Next 的子路径导出需 bundler；node 26 的 `--experimental-strip-types` 也只能剥类型）。
  行为级验证走另一条路：用仓库内 `typescript` 的 `transpileModule` 编译成 CJS，再在一个带**桩模块**（桩掉 `next/server`、`@vercel/postgres`）的 `.cjs` 里 `require` 并断言状态码/副作用 —— 参考 `.agents/tasks/setup-guard/guard.test.cjs` 的写法。
- **不能自动化的就写 SKIP**，别写成 PASS：工具限制（跑不起来、缺依赖）必须如实标注，“没测到”不等于“通过”。
