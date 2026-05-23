# ==============================================================================
# LiteLLM + Bedrock 部署 Makefile
# ==============================================================================
# 使用前: cp .env.example .env && 编辑 .env 填入凭证
# ==============================================================================

STACK_NAME ?= litellm-claude-code
AWS_REGION ?= us-west-2
LITELLM_PORT ?= 4000

# 加载 .env 文件中的环境变量（如存在）
ifneq (,$(wildcard .env))
  include .env
  export
endif

# ===== 本地开发 =====

.PHONY: deploy-local
deploy-local: ## 本地 Docker 启动（litellm + postgres + redis）
	@echo "🚀 Starting LiteLLM stack locally..."
	docker-compose up -d
	@echo "⏳ Waiting for services to be healthy..."
	@sleep 8
	@echo "✅ LiteLLM running at http://localhost:$(LITELLM_PORT)"
	@echo "✅ UI:                 http://localhost:$(LITELLM_PORT)/ui/"
	@echo ""
	@echo "Login: admin / $$LITELLM_MASTER_KEY"
	@echo ""
	@echo "Claude Code config:"
	@echo "  export ANTHROPIC_BASE_URL=http://localhost:$(LITELLM_PORT)"
	@echo "  export ANTHROPIC_AUTH_TOKEN=$$LITELLM_MASTER_KEY"
	@echo "  export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1"
	@echo "  claude --model claude-sonnet-4-6"

.PHONY: test-local
test-local: ## 测试本地推理
	curl -s -X POST http://localhost:$(LITELLM_PORT)/v1/messages \
		-H "Authorization: Bearer $$LITELLM_MASTER_KEY" \
		-H "Content-Type: application/json" \
		-d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"Say hello"}]}' | jq .

.PHONY: logs-local
logs-local: ## 查看本地日志
	docker-compose logs -f litellm

.PHONY: clean-local
clean-local: ## 清理本地容器和数据
	docker-compose down -v

# ===== AWS 一次性部署 =====

.PHONY: gen-keys
gen-keys: ## (可选) 生成预设凭据到 .env.deployed。不调也能部署（CFN 会自动生成）
	@echo "🔑 Generating fresh credentials..."
	@printf "LITELLM_MASTER_KEY=sk-%s\nDB_PASSWORD=\n" \
		$$(openssl rand -hex 16) > .env.deployed
	@chmod 600 .env.deployed
	@echo "✅ Saved to .env.deployed (mode 600). DB_PASSWORD 留空、部署时 CFN 自动生成。"

.PHONY: deploy
deploy: ## 一键部署到 AWS（全部凭据可由 CFN 自动生成）
	@touch .env.deployed && . ./.env.deployed && \
	echo "🚀 Deploying $(STACK_NAME) to $(AWS_REGION)..." && \
	sam build --template template.yaml && \
	sam deploy \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides \
			"LiteLLMMasterKey=$${LITELLM_MASTER_KEY:-} DBPassword=$${DB_PASSWORD:-} AnthropicApiKey=$${ANTHROPIC_API_KEY:-} LiteLLMLicenseKey=$${LITELLM_LICENSE_KEY:-} CloudFrontPriceClass=$${CLOUDFRONT_PRICE_CLASS:-PriceClass_All}" \
		--resolve-s3 \
		--no-confirm-changeset \
		--no-fail-on-empty-changeset
	@echo ""
	@$(MAKE) creds

.PHONY: creds
creds: ## 显示部署输出的凭据 (Master Key + DB Password)
	@echo "╔═ LiteLLM Credentials ═════════════════════════════"
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL` || OutputKey==`UILoginURL` || OutputKey==`LiteLLMMasterKey` || OutputKey==`DBPassword`].[OutputKey,OutputValue]' \
		--output table
	@echo "╔════════════════════════════════════════════"

.PHONY: status
status: ## 查看栈状态和访问 URL
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(AWS_REGION) \
		--query 'Stacks[0].{Status:StackStatus,Outputs:Outputs[*].[OutputKey,OutputValue]}' \
		--output table

.PHONY: get-url
get-url: ## 仅输出 CloudFront URL
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' --output text

.PHONY: test
test: ## 测试已部署栈
	@URL=$$($(MAKE) -s get-url); \
	KEY=$$(aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(AWS_REGION) --query 'Stacks[0].Outputs[?OutputKey==`LiteLLMMasterKey`].OutputValue' --output text); \
	echo "Testing $$URL ..." && \
	echo "--- /health/liveliness ---" && \
	curl -s -o /dev/null -w "HTTP %{http_code}\n" $$URL/health/liveliness && \
	echo "--- /v1/messages (sonnet) ---" && \
	curl -s -X POST $$URL/v1/messages \
		-H "Authorization: Bearer $$KEY" \
		-H "Content-Type: application/json" \
		-d '{"model":"claude-sonnet-4-6","max_tokens":30,"messages":[{"role":"user","content":"reply ok"}]}' | jq .

# ===== 运维 =====

.PHONY: scale
scale: ## 手动扩容 (usage: make scale COUNT=5)
	aws ecs update-service \
		--cluster $(STACK_NAME)-cluster \
		--service $$(aws ecs list-services --cluster $(STACK_NAME)-cluster --region $(AWS_REGION) --query 'serviceArns[0]' --output text | xargs basename) \
		--desired-count $(COUNT) \
		--region $(AWS_REGION)

.PHONY: redeploy-tasks
redeploy-tasks: ## 强制重启 ECS 任务（拉新镜像/配置）
	aws ecs update-service \
		--cluster $(STACK_NAME)-cluster \
		--service $$(aws ecs list-services --cluster $(STACK_NAME)-cluster --region $(AWS_REGION) --query 'serviceArns[0]' --output text | xargs basename) \
		--force-new-deployment \
		--region $(AWS_REGION) > /dev/null
	@echo "✅ Service redeploy triggered"

.PHONY: logs
logs: ## 查看 ECS 容器日志（最近 5 分钟）
	@aws logs tail /ecs/$(STACK_NAME) --since 5m --follow --region $(AWS_REGION)

.PHONY: destroy
destroy: ## ⚠️ 完整销毁栈（先关 RDS DeletionProtection）
	@echo "⚠️  Disabling RDS deletion protection..."
	-aws rds modify-db-instance --db-instance-identifier $(STACK_NAME)-db \
		--no-deletion-protection --apply-immediately --region $(AWS_REGION) > /dev/null
	@echo "⚠️  Deleting stack $(STACK_NAME)..."
	aws cloudformation delete-stack --stack-name $(STACK_NAME) --region $(AWS_REGION)
	aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) --region $(AWS_REGION)
	@echo "✅ Stack deleted (RDS snapshot retained per DeletionPolicy)"

.PHONY: help
help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
