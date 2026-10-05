-- Mesh / HA state synchronization (smg-mesh 的最小 OpenResty 等价实现)。
--
-- 参考实现：
--   * gateway/src/routers/mesh/handlers.rs   /ha/* 的对外语义与错误体
--   * gateway/src/server.rs:1393-1404        路由表（12 条）
--   * smg-mesh-1.0.0/src/crdt.rs             LWWRegister / CRDTMap / PNCounter
--   * smg-mesh-1.0.0/src/stores.rs           五个 store 的字段名
--   * smg-mesh-1.0.0/src/partition.rs        分区检测 + should_serve
--   * smg-mesh-1.0.0/src/rate_limit_window.rs 限流窗口重置
--
-- 本模块刻意分成两层，方便在没有 nginx 的环境里做纯 Lua 单测：
--   1. 纯逻辑层（LWW map、PN counter、版本向量、成员表、分区、限流窗口、
--      协议编解码、handler 函数）—— 只依赖 cjson.safe 和注入的 now()；
--   2. cosocket 层（http_request / sync_tick / start 定时器）—— 只在真实
--      OpenResty 里跑，单测用注入的假 http 函数覆盖。
--
-- 设计上的两个硬约束：
--   * 状态表存在进程内存里（每个 nginx worker 一份），写入方是 router 的
--     接线代码（observe_* 系列），读取方是 /ha/* handler。这与 Rust 一致：
--     /ha/workers 返回的是 mesh store 的内容而不是本地 registry。
--   * 未启用（SMG_MESH_PEERS 为空）时所有 /ha/* 返回与现有契约测试逐字节
--     相同的 {"error":"mesh not enabled"}，接线前后行为不倒退。

local cjson = require "cjson.safe"

local _M = { _VERSION = "0.1.0" }

---协议版本：字段不兼容时 +1，接收方对不上的包直接 400。
_M.PROTOCOL = 1

-- NodeStatus 在 gossip.proto 里是 INIT/ALIVE/SUSPECTED/DOWN/LEAVING；这里用
-- 小写字符串，/ha/status 的 nodes[].status 直接透出，避免再引一张映射表。
_M.STATUS_INIT = "init"
_M.STATUS_ALIVE = "alive"
_M.STATUS_SUSPECT = "suspect"
_M.STATUS_DOWN = "down"
_M.STATUS_LEAVING = "leaving"

---Rust GLOBAL_RATE_LIMIT_KEY / GLOBAL_RATE_LIMIT_COUNTER_KEY。
_M.GLOBAL_RATE_LIMIT_KEY = "global_rate_limit"
_M.GLOBAL_RATE_LIMIT_COUNTER_KEY = "global"

local has_ngx = (type(ngx) == "table")

local json_encode = cjson.encode
local json_decode = cjson.decode

-- 门面（facade）：实现全部搬到 mesh/ 子模块，函数直接写在这张表上（下面每个
-- require 都往 _M 挂自己的导出），所以门面只保留协议常量 + 加载顺序。
-- 预登记让子模块在加载期 require 回来拿到同一张表（设计书 §2）。
package.loaded["resty.luarouter.mesh"] = _M

require "resty.luarouter.mesh.crdt"
require "resty.luarouter.mesh.wire"
require "resty.luarouter.mesh.rate"
require "resty.luarouter.mesh.handlers"
require "resty.luarouter.mesh.sync"

return _M
