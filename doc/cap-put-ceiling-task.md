# PUT /workers 容量上限越界值必须在入口就被拒（任务书）

仓库 /home/aigc/ChatGPT/lua-router，HEAD=e041d08。**纯实现任务，事实已全部查清，直接写、写完验完再回报。**

## 缺口（21.k:8802 真机实测，root 亲自复现）

`PUT /workers/{id}` 传 `{"max_concurrency": 77}`（文档上限是 32）：

1. HTTP **202 accepted**（更新异步入队）；
2. 池侧 `/workers` 回显 **max_concurrency = 77** —— 越界值被原样写进 worker 记录；
3. 只有镜像到声明层时才被拒，网关日志白纸黑字：
   `control.lua:96: mirror_worker_caps(): ... max_concurrency must be at most 32
    -- the ceiling is live now but will not survive a restart`

根因：`registry/discovery.lua:256 UPDATE_NUMBER_FIELDS`（含 `max_concurrency`/`min_concurrency`/
`max_gpu_util`，:267）到 :293 的循环**只做 `tonumber`**，不查范围；而声明层
（`config_store/upstreams.lua` 的 `validate_cap_patch`，e041d08 刚加）查范围。两侧口径不一致，
于是「上限活着但活不过重启」——这与 e041d08 要堵的「整份配置被打掉」是同一个洞的两面。

## 要实现的

**让 PUT /workers 的三个 cap 字段与声明层同口径：越界当场 400，不进池记录。**

1. 把「文档能承载的 cap 取值规则」收到**一份**实现里（registry 侧，因为 PUT 的执行方是 registry）。
   现状：registry/loads.lua 有 `cap_limit` / `util_limit` 两个归一器（`<=0 → nil` 语义），
   config_store/upstreams.lua 的 `validate_cap_patch` 是文档形状校验。**新增的这份要把三档的
   范围规则（min 1..31、max 1..32、util 0..100）表达清楚，并让 validate_cap_patch 与
   discovery 的 PUT 循环都调它**——一份判据两处用，不许出现第二套规则。
2. `registry/discovery.lua` 的 PUT 循环对该字段调用这份判据，越界时返回既有的 validation 形状
   （`nil, "字段名 must be ...", "validation"` —— 与该文件既有错误形状一致，不要新造）。
   合法值行为逐字节不变（现有 202 路径、并发/成本/labels 等其他字段都不许受影响）。
3. 幂等与镜像路径不受影响：POST /workers（control.lua:246 走 caps_in_body 镜像）与
   `apply_upstream_caps`（mutators.lua）的既有行为保持。

## 测试（你独占这些文件）

- `test/unit/test_caps_persist.lua`（已有 107 项，是这个主题的家）：新增一段钉住
  **池侧 PUT 越界被拒**：越界值不进 worker 记录、`/workers` 回显里没有该键、声明层与整份配置完好；
  合法边界值（31/32/100）放行；`min >= max` 的交叉规则在 PUT 侧同样生效（若你决定一并纳入）。
- `test/test_lua_router.sh`：在 workers 段加一条 HTTP 面断言——越界 PUT 得到 400 而不是 202，
  且 `GET /workers/{id}` 里该键缺席、既有配置仍可读。
- 用已有判别性反证手法证明新断言会咬：临时回退 discovery.lua 的那段校验，T1 必须红，然后恢复。

## 验证

- luajit -bl 你改的文件。
- 直跑：test_caps_persist、test_caps_routing、test_profiles、test_routing_dyn
  （命令：docker run --rm -v $PWD:/repo:ro -w /repo --entrypoint /usr/local/openresty/luajit/bin/luajit
  -e LUA_TEST_LIB=/repo/lualib authz:latest /repo/test/unit/<t>.lua）。
- 契约单段：`TEST_ONLY=caps bash test/test_lua_router.sh`。
- **不许跑 final_gates.sh 全量**（root 统一跑）。

## 纪律

- 你独占：registry/loads.lua、registry/discovery.lua、config_store/upstreams.lua、
  test/unit/test_caps_persist.lua、test/test_lua_router.sh。**其他文件一律不许碰。**
- 禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务
  （含 systemctl restart / kill / systemctl stop 等一切形式）。
- 不许启动或重启 lua-router 的 8800/8801/8802 实例（root 统一部署）。
- 不 git 提交（root 统一提）。

## 回报

先写完、验完，再一次性回报：改动函数清单、「一份判据两处用」怎么落地、越界 PUT 的 HTTP 结果、
单测与契约单段结果、判别性反证结果。不要中途发进度。偏离任务书停下报证据。
