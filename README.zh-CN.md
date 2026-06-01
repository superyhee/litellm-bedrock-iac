# LiteLLM + Bedrock 生产部署模板

> 🌐 [English](README.md) · **简体中文**

通过 **LiteLLM Proxy + Amazon Bedrock** 让 [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) 接入 Bedrock 上的 Claude 4.x 系列模型，附带 Virtual Keys、Budget、Usage 追踪与 Web UI 管理。

**一键 SAM 部署** → CloudFront → 内网 ALB（VPC Origin）→ ECS Fargate → Bedrock + RDS PostgreSQL

> **区域设计**：网关（CloudFront / ALB / ECS / RDS / Redis）默认部署在 `ap-southeast-1`（新加坡），亚太用户访问延迟低。Bedrock 模型调用始终固定在 `us-west-2`（在 [`config.yaml`](config.yaml) 的 `aws_region_name` 中配置），与网关区域解耦。要改网关区域：`make deploy AWS_REGION=us-east-1`。

```mermaid
graph LR
    Dev[Claude Code / API Client] -->|HTTPS| CF[CloudFront]
    CF -->|VPC Origin<br/>私网 ENI| ALB[Internal ALB<br/>ap-southeast-1]
    ALB -->|:4000| ECS[ECS Fargate<br/>litellm-database]
    ECS -->|InvokeModel<br/>跨区域调用<br/>IAM Task Role| BR[Amazon Bedrock<br/>us-west-2]
    ECS -->|Virtual Keys<br/>Spend / Models| RDS[(RDS PostgreSQL<br/>db.t4g.small)]
    ECS -->|Prompt Cache<br/>跨 task 共享| Redis[(ElastiCache Redis<br/>cache.t4g.micro)]
    ECS -.->|Fallback| AN[Anthropic API]
    SM[(Secrets Manager<br/>自动生成密码)] -.-> ECS

    classDef aws fill:#FF9900,color:#fff
    class CF,ALB,ECS,BR,SM,RDS,Redis aws
```

## ✨ 特性

- **零输入部署**：`make deploy` 一行启动。Master Key + DB 密码都可由 CFN 自动生成并在输出里返回
- **零公网暴露**：ALB 是 internal 模式，仅 CloudFront VPC Origin 可达
- **一次性部署**：单个 `sam deploy` 命令完成全栈，无需多阶段或手动上传配置
- **Web 管理 UI**：登录 `/ui/` 可直接添加模型、签发 Virtual Key、查看用量
- **DB 持久化**：RDS PostgreSQL `db.t4g.small`（~170 连接）存储 Virtual Keys、Spend、Model 配置
- **跨实例 Prompt Cache**：ElastiCache Redis 共享缓存，scale-out 后仍能命中，实测节省 ~50% 成本
- **企业版兼容**：同一镜像，传入 `LITELLM_LICENSE` 即解锁 SSO / 审计 / 自定义品牌
- **Auto-scaling**：ECS 任务按 CPU 70% 自动扩缩 2-10 个
- **多模型**：Sonnet 4.6 / Opus 4.7 / Haiku 4.5 + Anthropic API fallback
- **全球加速**：CloudFront 默认 `PriceClass_All`，亚太 / 大洋洲 / 南美用户都走最近边缘节点
- **删除保护**：RDS `DeletionProtection: true`，防误删

---

## 📁 文件结构

| 文件                                       | 用途                                                                                                                  |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| [`template.yaml`](template.yaml)           | AWS SAM/CloudFormation 模板（含 VPC、ALB、ECS、RDS、Redis、CloudFront、Lambda CustomResource）                        |
| [`config.yaml`](config.yaml)               | LiteLLM 配置（模型路由、缓存、Fallback、预算）— **已内嵌到 template.yaml 中**，本地开发同时供 docker-compose 挂载使用 |
| [`docker-compose.yml`](docker-compose.yml) | 本地开发（含 PostgreSQL + Redis，与生产架构对齐）                                                                     |
| [`.env.example`](.env.example)             | 环境变量模板                                                                                                          |
| [`Makefile`](Makefile)                     | 一键部署 / 测试 / 查凭据 / 销毁脚本                                                                                   |

---

## 🛠️ Makefile 命令速查

所有日常操作都通过 `make` 完成。运行 `make help` 查看完整列表：

| 命令                  | 用途                                                                      |
| --------------------- | ------------------------------------------------------------------------- |
| `make deploy`         | 一键部署到 AWS（首次自动生成凭据，覆盖式安全更新）                        |
| `make creds`          | 表格显示 URL + 凭据（CloudFront URL / UI URL / Master Key / DB Password） |
| `make status`         | 完整栈状态 + 全部 Outputs                                                 |
| `make get-url`        | 仅输出 CloudFront URL                                                     |
| `make test`           | 远程发一次推理验证                                                        |
| `make logs`           | 实时跟踪 ECS 日志（最近 5 分钟）                                          |
| `make redeploy-tasks` | 强制重启 ECS 任务（拉新镜像/配置）                                        |
| `make scale COUNT=5`  | 手动扩容到 N 个 task                                                      |
| `make gen-keys`       | 生成预设 master key 到 `.env.deployed`（可选）                            |
| `make destroy`        | ⚠️ 完整销毁栈（自动先关 RDS DeletionProtection）                          |
| `make deploy-local`   | 本地 docker-compose 启动（含 PG + Redis）                                 |
| `make test-local`     | 本地推理验证                                                              |
| `make logs-local`     | 本地容器日志                                                              |
| `make clean-local`    | 清理本地容器和数据卷                                                      |

---

## 🚀 快速开始

### 1. 准备

```bash
brew install awscli aws-sam-cli jq    # 必需工具
aws configure                          # 配置 AWS 凭证
```

需要的 IAM 权限：Bedrock + ECS + RDS + ElastiCache + CloudFront + Lambda + Secrets Manager + IAM。

### 2. Bedrock 模型授权

[AWS Console → Bedrock → Model access](https://us-west-2.console.aws.amazon.com/bedrock/home?region=us-west-2#/modelaccess) 申请并启用以下 inference profile：

- `us.anthropic.claude-sonnet-4-6`
- `us.anthropic.claude-opus-4-7`
- `us.anthropic.claude-haiku-4-5-20251001-v1:0`

### 3. 一键部署

```bash
make deploy        # 部署（首次 ~15-20 分钟，CloudFront 慢在分布生成）
make creds         # 部署完成后查看凭据与 URL
```

网关默认部署在 **`ap-southeast-1`（新加坡）**。要换区域：

```bash
make deploy AWS_REGION=us-east-1
# 或写入 .env.deployed 持久化
echo 'AWS_REGION=us-east-1' >> .env.deployed && make deploy
```

Bedrock 模型区域跟网关区域是**解耦**的——无论网关在哪个 region，模型调用都通过 `us.anthropic.*` 跨区域 inference profile 走 `us-west-2`（在 [`config.yaml`](config.yaml) 中配置）。IAM Task Role 用 `arn:aws:bedrock:*:*:...` 通配符，跨区域调用开箱即用。

`make deploy` 会自动生成 master key 与 DB 密码，存入 Secrets Manager 并在 CFN Outputs 返回。
若已存在 `.env.deployed`（含 `LITELLM_MASTER_KEY` / `DB_PASSWORD` / `CLOUDFRONT_PRICE_CLASS` 等），会优先使用其中的值。

CloudFront 默认 `PriceClass_All`（含亚太、大洋洲、南美）。若仅服务北美/欧洲用户可设 `CLOUDFRONT_PRICE_CLASS=PriceClass_100` 降低成本。

`make creds` 输出示例：

```
╔═ LiteLLM Credentials ═════════════════════════════
+-------------------+--------------------------------------------+
|  CloudFrontURL    |  https://dXXXXXXXXXXXXX.cloudfront.net      |
|  UILoginURL       |  https://dXXXXXXXXXXXXX.cloudfront.net/ui/  |
|  LiteLLMMasterKey |  sk-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX       |
|  DBPassword       |  DbXXXXXXXXXXXXXXXXXXXXXXXX                |
+-------------------+--------------------------------------------+
```

#### 自定义凭据（可选）

```bash
make gen-keys      # 生成 sk- 前缀的随机 key 写入 .env.deployed
make deploy        # 用 .env.deployed 中的值部署
```

---

## 🔌 Claude Code 接入

`make creds` 查看凭据，然后导出环境变量：

```bash
export ANTHROPIC_BASE_URL=$(make -s get-url)
export ANTHROPIC_AUTH_TOKEN=<从 make creds 复制的 LiteLLMMasterKey>
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
claude --model claude-sonnet-4-6
```

生产推荐不要直接发 master key —— 请为每个用户/团队签发 Virtual Key（见下文）。

---

## 🎛️ 管理 UI

打开 `<CloudFrontURL>/ui/`：

| 字段     | 值                        |
| -------- | ------------------------- |
| Username | `admin`                   |
| Password | 你的 `LITELLM_MASTER_KEY` |

UI 能做：

- ✅ 添加/编辑/删除模型（无需改 config.yaml + 重启）
- ✅ 创建 Virtual Keys（独立 budget / RPM / 模型白名单 / 过期时间）
- ✅ 创建 Teams / Users（多租户隔离）
- ✅ 查看 Spend / Usage / 完整请求日志
- 🔒 SSO / 审计日志 / 品牌（需要 Enterprise License）

---

## 🔐 Virtual Keys（推荐用法）

不要让用户直接拿 master key —— 给每个团队/用户签发独立 key：

```bash
# 创建：限 sonnet，每月预算 $50，60 RPM
curl -X POST $ANTHROPIC_BASE_URL/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "models": ["claude-sonnet-4-6"],
    "max_budget": 50,
    "budget_duration": "30d",
    "rpm_limit": 60,
    "metadata": {"team": "engineering"}
  }'
```

⚠️ **注意**：LiteLLM 的预算检查是「先校验后扣费」**非事务性**模型，高并发下可能超支几个百分比。生产环境建议：

- 真实预算预留 20% buffer
- 用 `rpm_limit` / `tpm_limit` 兜底

---

## 🔧 修改 `config.yaml` 后如何更新

`config.yaml` 在部署时会被 **base64 内嵌到 ECS Task Definition** 中（见 [`template.yaml`](template.yaml) 里的 `CONFIG_YAML_BASE64`）。这避免了 S3 bootstrap 步骤，但代价是配置改动需要注册新的 TaskDef 版本才能生效。

### 什么时候改 `config.yaml`，什么时候用 UI

| 变更类型                                               | 操作位置    | 生效时机           |
| ------------------------------------------------------ | ----------- | ------------------ |
| 增删模型、调整模型参数                                 | 管理 UI     | 实时（写入数据库） |
| 创建 Virtual Keys、设置单 key budget / RPM             | 管理 UI     | 实时               |
| 路由策略、Fallback 链、重试次数、超时                  | config.yaml | redeploy 后        |
| 缓存后端（Redis / local）、TTL                         | config.yaml | redeploy 后        |
| 全局 budget、success / failure callback（Langfuse 等） | config.yaml | redeploy 后        |

经验法则：**动态状态走 UI；路由 / 缓存 / observability 策略走 `config.yaml`**。

### 如何让 `config.yaml` 改动生效

```bash
# 1. 本地修改 config.yaml
vim config.yaml

# 2. 重新部署 —— CFN 会 diff TaskDef、注册新版本、滚动更新 ECS Service
make deploy

# 3. 跟踪日志确认（看到两个新 task 都 RUNNING 后 Ctrl-C）
make logs
```

`make deploy` 是**幂等**的——如果只有 `config.yaml` 改了，只会更新 TaskDef 和 ECSService（~2-3 分钟，而不是首次部署的 ~15 分钟）。

### 滚动更新行为

ECSService 配置了 `MinimumHealthyPercent: 50` / `MaximumPercent: 200`，并启用了部署 circuit breaker。在默认 `DesiredCount: 2` 的情况下：

- ECS 用新 TaskDef 启动 2 个新 task
- 等新 task 通过 ALB 健康检查（`/health/liveliness`）
- 排空 2 个旧 task（target group 上有 30s deregistration delay）
- 若新 task 起不来，circuit breaker 会停止滚动（旧 task 继续承接流量——默认不自动回滚，需要查日志再 fix forward）

实际效果是**零停机滚动更新**——至少一个健康 task 始终在承接流量。

### 验证新配置已生效

```bash
# 确认 active TaskDef revision 已升版
aws ecs describe-services \
  --cluster litellm-claude-code-cluster \
  --services $(aws ecs list-services --cluster litellm-claude-code-cluster --query 'serviceArns[0]' --output text | xargs basename) \
  --query 'services[0].taskDefinition' --output text

# 通过 CloudFront 发推理验证
make test
```

### `make redeploy-tasks` 跟 `make deploy` 的区别

`make redeploy-tasks` 跑的是 `update-service --force-new-deployment`——**用同一个 TaskDef** 重启容器。适合拉新镜像（比如 `main-latest` 上游有更新），但**不会读到 `config.yaml` 的改动**，因为 base64 配置是烤进 TaskDef 本身的。改 config 一律用 `make deploy`。

### 回滚

CloudFormation 会保留历史 TaskDef revision。最快的回滚：

```bash
git revert HEAD          # 或 git checkout HEAD~1 config.yaml
make deploy
```

如果需要不走 git 的紧急回滚，可在 AWS 控制台手动把 ECSService 切回上一个 TaskDef revision——CFN 在下次 `make deploy` 时会重新收敛。

---

## 💰 成本估算（ap-southeast-1）

| 资源                                | 月费用         |
| ----------------------------------- | -------------- |
| ECS Fargate 2× (1 vCPU / 2GB, 24/7) | ~$80           |
| ALB (internal)                      | ~$18           |
| NAT Gateway (single AZ)             | ~$36           |
| CloudFront (低流量)                 | ~$1            |
| RDS db.t4g.small 20GB gp3           | ~$30           |
| ElastiCache Redis cache.t4g.micro   | ~$15           |
| Secrets Manager (≥3 secrets)        | ~$1.50         |
| CloudWatch Logs                     | ~$3            |
| **基础设施合计**                    | **~$185 / 月** |

加上 Bedrock 在 `us-west-2` 的调用（按 token 计费，与传统 Anthropic API 类似）。`ap-southeast-1` → `us-west-2` 的 Bedrock 调用会产生跨区域数据传输费，Claude Code 的典型 workload 一般每月几美元。

Redis 带来的共享缓存使多 task 场景下 prompt cache 命中率从 **~30% → ~85%**，实测可抵消其月费。

---

## 🏗️ 关键设计点

### 1. CloudFront VPC Origin

ALB 完全私有（`Scheme: internal`），CloudFront 通过 AWS 托管 SG `CloudFront-VPCOrigins-Service-SG` 直连。**无需把 ALB 暴露公网**。

### 2. Lambda 自动发现 SG

`CloudFront-VPCOrigins-Service-SG` 在第一个 VPC Origin 创建时由 AWS 自动生成。模板用 Lambda CustomResource 查找 SG ID 后，再添加 `SecurityGroupIngress`，解决"先有鸡还是先有蛋"。

### 3. config.yaml 内嵌 base64

配置文件 base64 编码后嵌入 TaskDef 的 `CONFIG_YAML_BASE64` 环境变量；启动脚本解码到 `/app/config.yaml`，避免 S3 bucket 依赖、消除 2-phase 部署。

### 4. 同步 Prisma 启动序列

容器入口先执行 `prisma db push`，**再** `exec litellm`。避免异步 prisma 与 uvicorn 抢 0.5 vCPU 资源导致 OOM (exit 137)。

### 5. IAM 通配符 Secrets ARN

ExecutionRole 的 `secretsmanager:GetSecretValue` 用 `arn:...:secret:${stack}/*` 而非 `!Ref` —— 避免 CFN 更新顺序与 Secret ARN 后缀错位的竞态。

### 6. 跨 task 共享 Prompt Cache

ElastiCache Redis 取代了默认的 `local` 缓存。`cache_params.type: redis` + Redis Endpoint 环境变量注入到容器。任意 task 重复调用同一 prompt 都能命中缓存，避免 scale-out 后命中率骤降。

---

## 🔄 升级到 LiteLLM Enterprise

申请 [LiteLLM Enterprise License](https://www.litellm.ai/) 后，把 license 加到 `.env.deployed`：

```bash
echo 'LITELLM_LICENSE_KEY=sk-litellm-license-xxxx' >> .env.deployed
make deploy
```

镜像不变，仅靠 `LITELLM_LICENSE` 环境变量解锁：SSO（Okta/Azure AD/Google）、审计日志、Prompt 管理 UI、自定义品牌、JWT 集成、Email 告警。

---

## 🧪 本地开发

`docker-compose.yml` 同时启动 LiteLLM + PostgreSQL + Redis，与生产架构完全对齐（同镜像、同启动脚本、同 DB / 缓存接口）。

```bash
cp .env.example .env             # 填入 LITELLM_MASTER_KEY 和 AWS 凭证
make deploy-local                # docker-compose up -d
make test-local                  # 测试推理
make logs-local                  # 跟日志
# UI: http://localhost:4000/ui/  (admin / $LITELLM_MASTER_KEY)
make clean-local                 # 清理
```

---

## 🗑️ 销毁

```bash
make destroy
```

`make destroy` 会自动先关闭 RDS DeletionProtection、再 `delete-stack` 并等待完成。

注意：RDS 默认带 `DeletionPolicy: Snapshot`，删除时会保留快照（要彻底清理需手动删除 snapshot）。

---

## 📚 参考

- [LiteLLM Docs](https://docs.litellm.ai)
- [CloudFront VPC Origins 介绍](https://aws.amazon.com/blogs/networking-and-content-delivery/introducing-cloudfront-virtual-private-cloud-vpc-origins-shield-your-web-applications-from-public-internet/)
- [Amazon Bedrock User Guide](https://docs.aws.amazon.com/bedrock/latest/userguide/)
- [Claude Code](https://docs.anthropic.com/claude/docs/claude-code)

---

## ⚠️ 已知限制 / TODO

### 生产升级剩余项（+~$50/月）

- [ ] **RDS Multi-AZ**（单 AZ 仍是 SPOF，交易型必加）
- [ ] **双 AZ NAT Gateway**（单 NAT 仍是 SPOF）
- [ ] **镜像 pin tag**（当前 `main-latest` 可能被上游静默变更）
- [ ] **关键告警**：ALB 5xx / Bedrock Throttle / RDS Connections + SNS

### 安全 / 合规

- [ ] CFN Outputs 明文返回凭据，多团队场景建议改为仅输出 Secret ARN
- [ ] 无 WAF（公网 LLM 网关建议加 AWS WAF 防滥用/DDoS）
- [ ] 无自定义域名 / TLS 证书（用 CloudFront 默认 `*.cloudfront.net`）

### 其他

- [ ] Redis 单节点，如需 HA 可改 `AWS::ElastiCache::ReplicationGroup` 加 replica

PRs welcome.
