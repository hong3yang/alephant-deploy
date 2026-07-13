#!/usr/bin/env bash
# =============================================================================
# generate-secrets.sh — Alephant K8s Secrets 生成脚本
# =============================================================================
# 自动生成随机密码/密钥并创建 K8s Secret 资源。
# 等效于 start.sh 的 generate_config()，但输出为 K8s Secret。
#
# 用法:
#   bash k8s/generate-secrets.sh
#
# 前置条件:
#   - kubectl 已配置到目标集群
#   - alephant-prod namespace 已存在
#   - 中间件（postgres / valkey / qdrant / minio / pd / clickhouse）已部署
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-alephant-prod}"

echo "生成随机密码和密钥..."

# ── 密码/密钥生成 ──
gen_pswd() { openssl rand -base64 32 | tr -d '/+=' | cut -c1-24; }
gen_jwt()  { openssl rand -base64 48 | tr -d '/+='; }
gen_key()  { openssl rand -base64 32; }
gen_token(){ openssl rand -base64 32; }

# ── 基础设施密码（与中间件部署保持一致） ──
# 如果中间件使用固定密码，在此修改
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(gen_pswd)}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-$(gen_pswd)}"
VALKEY_PASSWORD="${VALKEY_PASSWORD:-$(gen_pswd)}"
QDRANT_API_KEY="${QDRANT_API_KEY:-$(gen_token)}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(gen_pswd)}"

# ── 共享密钥 ──
JWT_SECRET=$(gen_jwt)
MASTER_KEY=$(gen_jwt)
ENCRYPTION_KEY=$(gen_key)
MASTER_KEY_ENCRYPTION_KEY=$(gen_key)
NOTIFICATION_ENCRYPTION_KEY=$(gen_key)
LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN=$(gen_token)
PAYMENT_SERVICE_KEY=$(gen_token)
OUTBOUND_PAYMENT_HMAC_SECRET=$(gen_jwt)
REVENUE_WITHDRAW_HMAC_SECRET=$(gen_jwt)
S3_ACCESS_KEY=${MINIO_ROOT_USER}
S3_SECRET_KEY=${MINIO_ROOT_PASSWORD}

echo ""
echo "═══════════════════════════════════════════"
echo "  生成的密码 (请保存)"
echo "═══════════════════════════════════════════"
echo "  PostgreSQL:    ${POSTGRES_PASSWORD}"
echo "  Valkey:        ${VALKEY_PASSWORD}"
echo "  JWT Secret:    ${JWT_SECRET}"
echo "═══"

# ============================================================================
# 1. saas-service-secrets
# ============================================================================
echo "创建 alephant-saas-service-secrets..."
kubectl create secret generic alephant-saas-service-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=POSTGRES_DATABASE_URL="postgresql://alephant:${POSTGRES_PASSWORD}@alephant-postgres-rw:5432/alephant" \
  --from-literal=REDIS_URL="redis://default:${VALKEY_PASSWORD}@alephant-valkey:6379/0" \
  --from-literal=APP_BASE_URL="http://localhost" \
  --from-literal=MASTER_KEY="${MASTER_KEY}" \
  --from-literal=MASTER_KEY_ENCRYPTION_KEY="${MASTER_KEY_ENCRYPTION_KEY}" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=ENABLE_SWAGGER_UI="true" \
  --from-literal=JWT_ACCESS_TTL="900" \
  --from-literal=JWT_REFRESH_TTL="604800" \
  --from-literal=CSRF_TOKEN_TTL="86400" \
  --from-literal=REDIS_KEY_PREFIX="alephant:" \
  --from-literal=REDIS_LOCK_DEFAULT_TTL_SECONDS="30" \
  --from-literal=REDIS_LOCK_RENEW_INTERVAL_SECONDS="10" \
  --from-literal=REDIS_STRONG_COORDINATION="true" \
  --from-literal=IDEMPOTENCY_TTL_SECONDS="86400" \
  --from-literal=LAST_USED_DEBOUNCE_SECONDS="5" \
  --from-literal=ENV="development" \
  --from-literal=REFRESH_COOKIE_NAME="refresh_token" \
  --from-literal=REFRESH_COOKIE_HTTP_ONLY="true" \
  --from-literal=REFRESH_COOKIE_SAME_SITE="lax" \
  --from-literal=REFRESH_COOKIE_SECURE="false" \
  --from-literal=ENFORCE_TRIAL_ONCE_PER_USER="false" \
  --from-literal=AUTH_RATE_LIMIT_PER_MIN="60" \
  --from-literal=SALES_LEAD_EMAIL="admin@example.com" \
  --from-literal=OAUTH_GITHUB_CLIENT_ID="" \
  --from-literal=OAUTH_GITHUB_CLIENT_SECRET="" \
  --from-literal=OAUTH_GITHUB_ALLOWED_REDIRECT_URIS="http://localhost:8080/auth/github/callback" \
  --from-literal=OAUTH_GOOGLE_CLIENT_ID="" \
  --from-literal=OAUTH_GOOGLE_CLIENT_SECRET="" \
  --from-literal=MAIL_HOST="" \
  --from-literal=MAIL_PORT="587" \
  --from-literal=MAIL_USERNAME="" \
  --from-literal=MAIL_PASSWORD="" \
  --from-literal=MAIL_FROM_ADDRESS="noreply@example.com" \
  --from-literal=MAIL_FROM_NAME="Alephant" \
  --from-literal=PAYMENT_SERVICE_BASE_URL="http://ledge-service:8080" \
  --from-literal=PAYMENT_SERVICE_KEY="${PAYMENT_SERVICE_KEY}" \
  --from-literal=PAYMENT_LEDGER_GRPC_ADDR="ledge-service:9090" \
  --from-literal=PAYMENT_LEDGER_INTERNAL_TOKEN="" \
  --from-literal=NOTIFICATION_ENCRYPTION_KEY="${NOTIFICATION_ENCRYPTION_KEY}" \
  --from-literal=OUTBOUND_PAYMENT_HMAC_SECRET="${OUTBOUND_PAYMENT_HMAC_SECRET}" \
  --from-literal=REVENUE_WITHDRAW_HMAC_SECRET="${REVENUE_WITHDRAW_HMAC_SECRET}" \
  --from-literal=COLLECTOR_ANALYTICS_BASE_URL="http://alephant-logs-collector:8585" \
  --from-literal=LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN="${LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
# 2. policy-service-secrets
# ============================================================================
echo "创建 alephant-policy-service-secrets..."
kubectl create secret generic alephant-policy-service-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=POSTGRES_DATABASE_URL="postgresql://alephant:${POSTGRES_PASSWORD}@alephant-postgres-rw:5432/alephant" \
  --from-literal=REDIS_URL="redis://default:${VALKEY_PASSWORD}@alephant-valkey:6379/0" \
  --from-literal=POLICY_CONFIG_STREAM="alephant-policy" \
  --from-literal=POLICY_NOTIFY_CHANNEL="alephant-notify" \
  --from-literal=POLICY_USE_STREAM="true" \
  --from-literal=POLICY_STREAM_BATCH_SIZE="100" \
  --from-literal=POLICY_STREAM_BLOCK_MS="1000" \
  --from-literal=POLICY_STREAM_CONSUMER_GROUP="policy-consumer" \
  --from-literal=POLICY_STREAM_CONSUMER_NAME="policy-node-0" \
  --from-literal=POLICY_BOOTSTRAP_REFRESH="true" \
  --from-literal=POLICY_BOOTSTRAP_REFRESH_CONCURRENCY="10" \
  --from-literal=POLICY_BOOTSTRAP_REFRESH_TIMEOUT_SEC="30" \
  --from-literal=ENDPOINT_POLICY_CONFIG_STREAM="alephant-policy" \
  --from-literal=WATCHER_ENABLED="true" \
  --from-literal=NOTIFICATION_ENCRYPTION_KEY="${NOTIFICATION_ENCRYPTION_KEY}" \
  --from-literal=NOTIFICATION_OUTBOX_NOTIFY_CHANNEL="alephant-notification" \
  --from-literal=LOG_LEVEL="info" \
  --from-literal=MAIL_HOST="" \
  --from-literal=MAIL_PORT="587" \
  --from-literal=MAIL_USERNAME="" \
  --from-literal=MAIL_PASSWORD="" \
  --from-literal=MAIL_FROM_ADDRESS="noreply@example.com" \
  --from-literal=MAIL_FROM_NAME="Alephant" \
  --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
# 3. ai-gateway-secrets
# ============================================================================
echo "创建 alephant-ai-gateway-secrets..."
kubectl create secret generic alephant-ai-gateway-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=POSTGRES_DATABASE_URL="postgresql://alephant:${POSTGRES_PASSWORD}@alephant-postgres-rw:5432/alephant" \
  --from-literal=REDIS_URL="redis://default:${VALKEY_PASSWORD}@alephant-valkey:6379/0" \
  --from-literal=CLICKHOUSE_CREDS="default:${CLICKHOUSE_PASSWORD}" \
  --from-literal=AI_GATEWAY__SEMANTIC_CACHE__QDRANT__URL="http://alephant-prod-qdrant:6333" \
  --from-literal=AI_GATEWAY__SEMANTIC_CACHE__QDRANT__API_KEY="${QDRANT_API_KEY}" \
  --from-literal=AI_GATEWAY__TIKV_KV__PD_ENDPOINTS='["pd:2379"]' \
  --from-literal=AI_GATEWAY__TIKV_KV__CA_CERT_PATH="" \
  --from-literal=AI_GATEWAY__POLICY__GRPC_ENDPOINT="alephant-policy-service:9090" \
  --from-literal=AI_GATEWAY__X402__PAYMENT_GRPC_ENDPOINT="" \
  --from-literal=AI_GATEWAY__X402__UPSTREAM_AUTH_KEY="" \
  --from-literal=AI_GATEWAY__ALEPHANT__LOG_COLLECTOR_URL="http://alephant-logs-collector:8585" \
  --from-literal=AI_GATEWAY__REQUEST_LOG__TRANSPORT="http" \
  --from-literal=S3_ENDPOINT="http://alephant-minio:9000" \
  --from-literal=S3_REGION="us-east-1" \
  --from-literal=S3_BUCKET_NAME="alephant" \
  --from-literal=S3_ACCESS_KEY="${S3_ACCESS_KEY}" \
  --from-literal=S3_SECRET_KEY="${S3_SECRET_KEY}" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=MASTER_KEY_ENCRYPTION_KEY="${MASTER_KEY_ENCRYPTION_KEY}" \
  --from-literal=PAYMENT_SERVICE_KEY="${PAYMENT_SERVICE_KEY}" \
  --from-literal=LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN="${LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN}" \
  --from-literal=KEY_MARKET_API_KEY_HASH_SECRET="${MASTER_KEY_ENCRYPTION_KEY}" \
  --from-literal=ANALYTICS_RMT_MAX_RANGE_HOURS="72" \
  --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
# 4. logs-collector-secrets
# ============================================================================
echo "创建 alephant-logs-collector-secrets..."
kubectl create secret generic alephant-logs-collector-secrets \
  --namespace "${NAMESPACE}" \
  --from-literal=POSTGRES_DATABASE_URL="postgresql://alephant:${POSTGRES_PASSWORD}@alephant-postgres-rw:5432/alephant" \
  --from-literal=REDIS_URL="redis://default:${VALKEY_PASSWORD}@alephant-valkey:6379/0" \
  --from-literal=CLICKHOUSE_CREDS="default:${CLICKHOUSE_PASSWORD}" \
  --from-literal=S3_ENDPOINT="http://alephant-minio:9000" \
  --from-literal=S3_REGION="us-east-1" \
  --from-literal=S3_BUCKET_NAME="alephant" \
  --from-literal=S3_ACCESS_KEY="${S3_ACCESS_KEY}" \
  --from-literal=S3_SECRET_KEY="${S3_SECRET_KEY}" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN="${LOGS_COLLECTOR_X402_HTTP_AUTH_TOKEN}" \
  --from-literal=ANALYTICS_RMT_MAX_RANGE_HOURS="72" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅ Secrets 创建完成"
echo ""
echo "  如需查看生成的密码:"
echo "    kubectl get secret alephant-saas-service-secrets -n ${NAMESPACE} -o jsonpath='{.data.POSTGRES_DATABASE_URL}' | base64 -d"
