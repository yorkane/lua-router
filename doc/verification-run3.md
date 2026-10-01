# lua-router 第 3 波全量回归复测（2026-09-29 23:00–23:10 UTC）

结论：**全绿，无回归**。基线 266/0/3、43/0、67/118/791+、四组路由行为指标全部真实复现。
本轮未修改任何实现代码。

> **状态**：复测记录有效，**其基线（契约 266）已过两代：fix-majors 到 322，核心第二波到 474**。
> **日期**：复测 2026-09-29 23:00–23:10 UTC，状态复核 2026-09-30（UTC，最后一次 04:5x 刷新）。
> **证据强度**：B（本文数据）+ A（2026-09-30 02:00–02:20 重跑：契约 322/0/3、
> tree 67 / policies 118 / hash 795 / integration 66、e2e_stateful 43/0 全部复现）。
>
> 本文写的是 **M1–M6 落地前的基线**（契约 266、hash 791、e2e 43）。现值见
> [README](../README.md) 的「当前基线」表；本文末尾
> 「文档陈旧计数待刷新」那一条已在本轮完成（impl-policies / impl-hash / impl-tests 已改）。
> 本文的「四组路由行为指标复现」与「无回归」结论仍然有效 —— 单测计数（67/118/795/66）
> 与 e2e_stateful 43/0 到核心第二波都没变，路由行为指标未在这之后重跑。
>
> **本文提到的两个 e2e 失败已修**：`e2e_policies` 与 `e2e_ui_bridge` 的那两条红同因
> `set_top_field` 整数分支 bug，核心第二波把指数组改成可选后同时转绿（现在 65/0 与 19/0），
> 并补了「替换已存在整数成员不产生重复键」的契约断言。原始记录见 feature-gap.md §5.1。
> 另需知道：`probes.py` 当前是 25 checks / 1 failed，原因是断言还钉着旧的缺省策略
> `round_robin`（实现已按 Rust 对齐成 `cache_aware`），见 feature-gap.md §5.6。

## 1. 语法门（openresty -t，authz:latest）

| conf | 结果 |
| --- | --- |
| `test/conf/nginx-lua-router.conf` | syntax is ok / test is successful（exit 0） |
| `conf/lua-router.conf` | syntax is ok / test is successful（exit 0） |
| `conf/ui.conf` 被 include（临时 conf 注入 server{}） | syntax ok / exit 0 |

命令：`docker run --rm -v $PWD:/repo:ro --entrypoint openresty authz:latest -t -p /usr/local/openresty/nginx/ -c /repo/<conf>`。

## 2. 单元测试（两个镜像各跑一遍，全部 exit 0）

| 套件 | resty (apisix:3.11.0) | luajit (authz:latest) | 文档旧值 |
| --- | --- | --- | --- |
| tree | 67 passed, 0 failed | 67 passed, 0 failed | impl-policies.md 写 62（陈旧） |
| policies | 118 passed, 0 failed | 118 passed, 0 failed | impl-policies.md 写 116（陈旧） |
| hash | 795 passed, 0 failed | 795 passed, 0 failed | impl-hash.md 写 791（陈旧） |

复现命令在 impl-policies.md / impl-hash.md 末尾，与文档一致。
附带跑了 `test/unit/test_integration.lua`（三套之外新增）：66 passed, 0 failed。
三个数字都比文档大且 0 failed，是后续 agent 追加用例所致（/data/tmp/lr/int/unit_hash.out
留档同为 795），不是断言被放宽；建议有空时把文档数字刷新一遍。

## 3. 契约套件（严格模式，连跑 3 遍）

`bash test/test_lua_router.sh`：

| 遍次 | 结果 | 退出码 |
| --- | --- | --- |
| 1 | All 266 passed (3 documented notes) | 0 |
| 2 | All 266 passed (3 documented notes) | 0 |
| 3 | All 266 passed (3 documented notes) | 0 |

3 条 NOTE 内容与基线逐字一致（404 body 偏差、405→404 待收敛、/v1/loads 形状），
均为已文档化的契约偏差说明，非失败。无环境干扰、无实现回归。

## 4. 策略路由行为复测（parity，新建池 + 新建实例）

旧环境已被上一波清理（pl-*/pr-* 容器与 mock 池均不存在），本轮从
`setup_pools.sh` → `start_rust.sh` → `start_lua.sh`（另补 pl-ch，脚本本身不含）→
`register_all_run3.sh` 全量重建。注意 chA 对齐 harness 用 47740（旧 register_all.sh 的
47724 与 harness.py 不一致，已在 run3 脚本中修正）。

| # | 指标 | Lua（本轮） | Rust（本轮） | 基线 | 判定 |
| --- | --- | --- | --- | --- | --- |
| t1 | round_robin 30 req / 3 w | 10/10/10，max/min 1.0，χ² 0.0 | 10/10/10，1.0，0.0 | 10/10/10 | 复现 |
| t2 | consistent_hashing 粘滞 | 20/20 | 20/20 | 20/20 | 复现 |
| t2 | 摘 chD 后 | moved 4，全部来自被摘 worker，collateral 0，unchanged 0.80 | 同 | 0.80 | 复现 |
| t2 | 两侧逐 key 落点 | 20/20 相同 | — | 全同 | 复现 |
| t3 | manual 粘滞 | 12/12 | 12/12 | 12/12 | 复现 |
| t3 | 摘 maC→恢复后回切 | 12/12 | 12/12 | 修复后 12/12 | 复现（修复保持） |
| t4 | cache_aware 8×6 亲和率 | 1.000（0 切换） | 1.000（0 切换） | 1.000 | 复现 |

四个测试两侧合计 ~600 次请求，脚本记录的 errors 全为 0。结果 JSON 已覆盖到
`/data/tmp/parity/routing/t{1,2,3,4}_*.json`。

## 5. e2e_stateful（集成）

`docker build -t lua-router:integration -f Dockerfile .` exit 0（层缓存复用，
已按 md5 核对镜像内 policy.lua / cache_aware.lua 与仓库当前文件一致），并单独对新镜像
补跑了构建期同款 gate：`docker run --rm --entrypoint /docker-entrypoint.sh
lua-router:integration openresty -t -p /usr/local/openresty/nginx` → test is successful。

`python3 test/integration/e2e_stateful.py` → **43 checks, 0 failed**（exit 0），
覆盖 bucket / prefix_hash / manual / manual failback / snapshot / snapshot max_bytes /
multi-process / add worker 共 8 段，与基线一致。

## 修复的回归

无。本轮未发现任何实现回归，未改动 lualib/ 与 test/ 下任何文件。

## 遗留

- 本轮为复测新起的 pl-*/pr-* 容器在测试完成后被另一 agent 的清理命令删除（数据已全部落盘）；
  mock 池 16 个进程由本轮验证结束后按 pools.pids 精确 kill。
- 文档陈旧计数（tree 62→67、policies 116→118、hash 791→795）**已于 2026-09-30 刷新完毕**
  （impl-policies.md / impl-hash.md / impl-tests.md）。
