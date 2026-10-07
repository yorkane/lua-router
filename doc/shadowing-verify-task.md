# 遮蔽语义真机验收任务书（21.k:8802）

**铁律：只操作 lua-router-8802。8801 是生产，全程只读、零写；不许重启它。不许碰 235.t。**

禁止重启/杀掉承载本会话的基础设施：codex-desktop-gateway、3737 网关及其依赖服务（含 systemctl restart / kill / systemctl stop 等一切形式）。

## 背景

刚实现「虚拟入口遮蔽同名实际模型」（用户裁定 2026-10-07 方案 A）。语义：入口名叫 X 时，
所有 `model=X` 的请求走该入口的 targets；真实模型 X 不再单独可达，只作为 targets 落点。
配置层要求「X 确实被引擎背书」才允许同名（registry 的 record_models ∩ models_are_verified）。

代码已提交（733b386 广告面 + dc3a370 config_store + 9811ea3 测试），本机全量门禁 22/22 全绿
（日志 /data/tmp/lr-gates/gates-20261007-170747.log）。你要部署到 8802 做真机验收。

## 21.k 现状（已知）

8 个真实 sglang 实例：8012(gpu0, qwen3.8-27b-w8a16) / 8021(gpu1, orca) / 8022-8027(gpu2-7, Q38-Flash-Next 等)。
8802 当前配置来自 8801 的迁移（2 个虚拟模型 q38fn-64k / qwen38fn-ab + 3 张模型卡）。
镜像标签形如 pub/lua-router:8802-YYYYMMDD-N（compose 在 /data1/app/lua-router-8802/）。

## 步骤

1. 等 root 把镜像构建好并告知 tag（root 正在构建 8802-20261007-1）。然后：
   - `docker tag` + `docker push` 到 ACR（wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/）
   - ssh 21.k 改 /data1/app/lua-router-8802/docker-compose.yml 的 image 行、pull、up -d
   - **改前备份 compose**（cp docker-compose.yml docker-compose.yml.bak-20261007-shadow）
2. 等健康周期（约 90s，重启后暂态 503 是已知行为不是失败），确认 /health OK、/workers 8/8 healthy、
   `metadata.gpu` 仍是 gpu0..gpu7（别被本轮改动破坏）。
3. **核心验收：同名遮蔽**。用 8802 上现成的真实模型名做实验（例如 Q38-Flash-Next）：
   a. 记录当前基线：`GET /v1/models` 的 id 列表、`GET /workers` 里跑 Q38-Flash-Next 的实例列表。
   b. 建一个**同名入口**：POST /_ui/config/virtual `{"model":"Q38-Flash-Next","targets":["q38fn"]}`
      （q38fn 是另一个真实模型，8024 在跑）。这一步验证「引擎背书的同名能建成」。
   c. 验广告：`GET /v1/models` 里 Q38-Flash-Next 恰好一行，owned_by 是入口口径（单成员 llm-router->q38fn），
      created 恒 0；真实 Q38-Flash-Next 不再单独出现。
   d. 验路由：POST /v1/chat/completions model=Q38-Flash-Next → 200，且 `GET /_ui/logs` 里
      **forwarded_model 是 q38fn**（证明落到 targets 指定的那个），worker 是 8024。
   e. 验「可以在虚拟服务中配置」：给同名入口 Q38-Flash-Next 配一张模型卡（如 ctx=65535、effort_map），
      确认 `GET /_ui/props?model=Q38-Flash-Next` 或转发行为体现卡片配置**真实生效**（不是死配置）。
   f. 验反例：建一个**未被引擎背书**的同名（把 targets 指到一个池里不存在的名字，如 target 与入口同名
      但该名字不在池里）→ 期望被**拒绝**（400 + 被钉文案家族里的措辞），证明判据不是无条件放行。
   g. **收尾必须**：把本轮所有测试配置（同名入口、卡片）清回原状，GET /_ui/config 确认回到迁移后的基线
      （2 个虚拟模型 q38fn-64k/qwen38fn-ab + 3 张卡），GET /v1/models 与 /workers 回到实验前。
4. 顺带回归：原有的两个虚拟模型 q38fn-64k / qwen38fn-ab 各发一个 chat，确认仍 200（别被同名遮蔽改动
   误伤——它们的 target 不撞真实名）。
5. 每项把命令与输出记进 /data/tmp/lr-shadow-8802-verify.md。

## 回报

先做完、验完，再一次性回报：每项命令+输出证据、同名遮蔽三条硬判据（请求落点/广告形状/卡片生效）是否成立、
未被背书时是否确实被拒、收尾确认（配置回到基线）、发现的任何问题。不要中途发进度。
发现问题如实上报，不要自己改代码。
