# policies 实现说明（cache_aware / tree / bucket / extract_text）

对端参考实现：`gateway/src/policies/{tree,cache_aware,bucket,utils,mod}.rs` 与
`openai-protocol-1.0.0` 的 `ChatCompletionRequest::extract_text_for_routing` /
`CompletionRequest::extract_text_for_routing`。逐分支对齐，偏差全部列在文末。

> **状态**：仍有效。**日期**：写作 2026-09-29，状态复核 2026-09-30（UTC）。
> **证据强度**：A（单测计数本轮复跑确认）。
>
> 事实校正：文末「当前结果 tree 62 / policies 116」已过时，现为
> **tree 67 passed / policies 118 passed（均 0 failed）**，`resty`(apisix:3.11.0-debian) 与
> `luajit`(authz:latest) 两个口径 2026-09-30 复跑一致。
> 偏差 1（per-process 树 → 多 worker 亲和衰减）仍然成立，出厂入口脚本已在
> `SMG_POLICY=cache_aware` 且未显式指定 worker 数时收成 1；量化数据见
> [parity-routing.md](parity-routing.md) #6（4 进程 1.000→0.625）。
> 本文 §「快照如何接到 lr_policy」描述的接线已在 `policy.lua` 落地（快照键带 worker id、
> 3 MiB 上限跳过、淘汰后回写）。

## 算法 → 文件映射

| 内容 | Rust | Lua |
| --- | --- | --- |
| 多租户基数树（insert / 前缀分裂 / prefix_match_with_counts / remove_tenant / evict_tenant_by_size / 快照） | `policies/tree.rs` | `lualib/resty/luarouter/policies/tree.lua` |
| cache_aware 选择流程（失衡逃逸、缓存命中、脏租户清理、树播种、淘汰） | `policies/cache_aware.rs` | `lualib/resty/luarouter/policies/cache_aware.lua` |
| 字符长度分桶（边界构造、二分、滑动窗口衰减、边界重算） | `policies/bucket.rs` | `lualib/resty/luarouter/policies/bucket.lua` |
| 路由文本抽取、UTF-8 码点计数、健康过滤、并列随机、worker 字段访问 | `policies/{utils.rs,mod.rs}` + `openai-protocol` | `lualib/resty/luarouter/policies/utils.lua` |
| 单测 | `#[cfg(test)]` 内联 | `test/unit/test_tree.lua`、`test/unit/test_policies.lua` |

## framework 需要知道的接口

策略实例由 config/policy 框架持有，**每个 nginx worker 进程各自一份**（per-process 表）。

```lua
local cache_aware = require "resty.luarouter.policies.cache_aware"
local policy = cache_aware.new({
    cache_threshold = 0.5,
    balance_abs_threshold = 32,
    balance_rel_threshold = 1.1,
    eviction_interval_secs = 30,
    max_tree_size = 10000,
})
```

worker 对象支持两种形态（`{url=..., load=..., healthy=..., models={"m"}}` 字段表，
或 `w:url() / w:load() / w:is_healthy()` 方法表），字段读取集中在
`policies/utils.lua` 的 `worker_url` / `worker_load` / `worker_healthy` /
`worker_can_execute` / `worker_model_id` / `worker_pool`。

- `policy:init_workers(workers)` / `policy:add_worker(w)`：向 `pool::model` 树 `insert("", url)`。
- `policy:remove_worker(w)`（按 pool/model 定位单树）/ `policy:remove_worker_by_url(url)`（扫全部树）。
- `policy:select_worker(workers, { request_text = text_or_nil })` → 1-based 下标或 `nil`（无健康 worker）。
- `policy:evict_all()`：给 `init_worker` 定时器调用（`eviction_interval_secs`），等价 Rust 的 Eviction 线程。
- `policy:encode_snapshot(max_bytes)` / `policy:decode_snapshot(json_text)`：`lr_policy` 快照落盘/回读，
  JSON 文本形态，超限时 `encode_snapshot` 返回 `nil` 让调用方跳过本轮写盘。

bucket 同形态：`bucket.new({balance_abs_threshold=32, balance_rel_threshold=1.0001,
bucket_adjust_interval_secs=5})`，外加 `init_worker_urls / add_worker / remove_worker /
select_worker / adjust_all`，另有 `set_clock(fn)` 注入时钟供测试。

`extract_text_for_routing` 走 `policies/utils.lua`：

- chat（有 `messages`）：按顺序取 system / user / tool / developer 的 `content`，
  assistant 的 `content` + `reasoning_content`，function 的 `content`；`content` 为数组时
  只拼 `{type="text"}.text`；片段之间用**单个空格**连接。
- completions（有 `prompt`）：字符串直接用，数组按单空格 join。
- 无文本 → **返回 `nil`**（不是空串），对齐 `build_chat_request_text` 的 `Option::None`。
- cjson 的 `null` 会被解成 `cjson.null` 光值，代码里按 nil 处理。

### 快照如何接到 lr_policy（框架侧的接线契约）

策略层不碰 shared dict，只给 JSON 文本；落盘/回读由 policy.lua 的 init_worker + timer 负责：

```lua
-- init_worker（每 worker 各起一份，先播种 worker 再覆盖快照，顺序不能反）
policy:init_workers(workers)
local snap = lr_policy:get("snapshot:" .. instance_id)   -- lr_policy = ngx.shared.lr_policy
if snap then policy:decode_snapshot(snap) end

-- ngx.timer.every(eviction_interval_secs)
policy:evict_all()                                        -- 先淘汰，树变小后才写得出快照
local text = policy:encode_snapshot(SNAPSHOT_MAX_BYTES)   -- 建议 ~3 MB 上限
if text then
    local ok, err = lr_policy:set("snapshot:" .. instance_id, text)
    if not ok then ngx.log(ngx.WARN, "lr_policy snapshot set failed: ", err) end
end
```

`encode_snapshot` 在超限时返回 `nil`，本轮跳过写盘（shared dict 满时也不会挤掉别人的 key）；
`decode_snapshot` 对 `nil` / 非法 JSON 返回 `false`，框架可据此回落到「只播种 worker」的冷启动路径。

## 与 Rust 的偏差（已确认取舍）

1. **per-process 树，不跨进程共享**（ARCHITECTURE 已批准）。Rust 用 DashMap + RwLock 做全进程共享树；
   这里每个 nginx worker 各持一棵树，`select_worker` 只看本进程的请求历史。
   后果：`worker_processes > 1` 时亲和度是 N 份近似树的平均，命中率低于 Rust。
   建议 `worker_processes 1`，或接受亲和衰减（负载分支不受影响）。
2. **淘汰不跑后台线程**，改由 `init_worker` 定时器调 `evict_all()`；`select_worker` 不触发淘汰。
   若框架不注册定时器，树会无界增长。
3. **epoch 的 1/8 采样回写保留**（`epoch % 8 == 0` 时刷新匹配节点时间戳）。LuaJIT 单线程不存在
   Rust 要降低的 DashMap 写争用，保留它只为让 LRU 排序与 Rust 行为一致，代价是每 8 次匹配才刷新一次，
   实测不影响淘汰顺序（单测里有对应用例）。
4. **`evict_tenant_by_size` 的限额是「每租户」字符数**，不是整棵树节点数——Rust 注释里把它写成
   "Maximum nodes per tree"，但实现按 `tenant_char_count[tenant] > max_size` 判定，这里跟实现走。
5. **无 mesh 同步**：`set_mesh_sync` / `apply_remote_tree_operation` / `restore_tree_state_from_mesh` 不实现，
   跨机一致性交给快照（下一条）。
6. **快照走 JSON 而不是操作日志**：Rust mesh 记录 insert/remove 操作流；这里 `tree:serialize()` 导出
   「叶子全文 + epoch」列表，恢复时按 epoch 升序回放 insert，可复原同样的拓扑与 LRU 相对顺序。
   代价：单条叶子文本最长可达整个对话，快照体积随流量增长，因此 `encode_snapshot` 支持 `max_bytes` 上限，
   超限就跳过本轮落盘（等下次淘汰后变小再写）。
7. **字符计数**：Rust 用 `chars().count()`，Lua 侧手写 UTF-8 码点计数（`utils.utf8_len` 等），
   因为 Lua 的 `#s` 是字节数。非法字节按 1 字符前进，保证不会死循环。
8. **`usize::MAX` → `2^53-1`**：bucket 末桶上界用 `utils.INF_BOUND`，LuaJIT 双精度能精确表示，
   比较行为与 Rust 一致。
9. **并列随机的可复现性**：Rust 用 `rand::seq::IteratorRandom::choose`；这里 rng 可注入
   （`cache_aware.new(cfg, rng)`），bucket 失衡分支的 chars 最小者并列时按 URL 字典序取最小，
   以便单测断言稳定（Rust 的 `min_by_key` 也是同序语义）。
10. **worker 健康过滤多了 circuit_breaker 一维**（`utils.worker_can_execute`），对齐 Rust
    `is_healthy() && circuit_breaker().can_execute()`；框架没有该字段时默认放行。

### 随机源

并列 tie-break 走 `math.random`，LuaJIT 不 seed 时每个 worker 序列相同（Lua 状态按固定种子初始化），
多 worker 会同步选同一个并列项。框架需在 `init_worker` 里做一次 `math.randomseed`
（`ngx.worker.id() ~ 启动时间` 之类）。策略实例也接受注入 rng：`cache_aware.new(cfg, function(n) ... end)`，
集成测试靠它得到确定性选择。

## 单元自测怎么跑

宿主机没有 luajit / perl，用镜像里的解释器。纯 Lua 逻辑（树、文本抽取、选择分支、分桶）
不依赖 ngx，所以 `luajit` 和 `resty` 都能跑。两个镜像都验证通过：

```bash
cd /path/to/lua-router
# resty（真实 ngx 环境，含 cjson / ngx.now 毫秒精度）
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_tree.lua")'
docker run --rm -v "$PWD:/repo:ro" -w /repo \
  --entrypoint /usr/bin/resty apache/apisix:3.11.0-debian \
  -e 'package.path="/repo/lualib/?.lua;"..package.path
      dofile("/repo/test/unit/test_policies.lua")'
# authz 镜像的 luajit（无 perl，resty CLI 不可用）也跑通
#   --entrypoint /usr/local/openresty/luajit/bin/luajit authz:latest ...（同上 -e 脚本）
```

当前结果：`tree: 67 passed, 0 failed` / `policies: 118 passed, 0 failed`（两个镜像均 exit 0，
2026-09-30 复跑；初版写作时是 62 / 116，多出的 5 + 2 个用例来自后续 agent 追加，
不是断言被放宽）。
覆盖点：UTF-8 码点计数与分叉、公共前缀分裂、部分匹配分母、epoch 采样回写、
`remove_tenant` 与空节点回收、每租户 LRU 淘汰、快照 serialize/restore、
cache_aware 的失衡双阈值（abs 成立/rel 成立/仅 abs 成立/仅 rel 成立四种组合）、
失衡分支也写树、脏租户清理、树未播种退化随机、(pool, model) 树隔离、
bucket 边界均分与末桶 inf、二分探针全覆盖、滑动窗口时间衰减（注入时钟）、
失衡改选 chars 最小、`add_worker`/`remove_worker` 重建边界、`adjust_boundary` 的 2x 迟滞。
