# Alephant K8s 部署方案

## 目录

- [前置依赖](#前置依赖)
- [快速开始](#快速开始)
- [组件说明](#组件说明)
- [基础设施依赖](#基础设施依赖)
- [基础设施部署参考](#基础设施部署参考)
- [Secrets 管理](#secrets-管理)
- [License 激活](#license-激活)
- [Ingress 路由](#ingress-路由)
- [镜像更新](#镜像更新)
- [扩缩容](#扩缩容)
- [监控与日志](#监控与日志)
- [常见问题](#常见问题)

---

## 架构概览

```
                          ┌──────────────────────────┐
                          │    Ingress Controller     │
                          │  (haproxy / nginx / ALB   │
                          │   / traefik / 你的选择)    │
                          └────┬─────┬──────┬────┬───┘
                  ┌────────────┤     │      │    │
                  ▼            ▼     ▼      ▼    ▼
          ┌──────────┐  ┌────────┐ ┌──────┐ ┌──────┐
          │ SPA App   │  │ SaaS   │ │Policy│ │  AI  │
          │(Nginx+    │  │Service │ │Service│ │Gateway│
          │ 前端静态) │  │:8080   │ │:8090 │ │:8080 │
          └──────────┘  └────────┘ └──────┘ └──────┘
                                    ┌──────┐
                                    │Logs  │
                                    │Collect│
                                    │:8585 │
                                    └──────┘

基础设施 (集群外或 Operator 管理):
  ┌────────┐ ┌────────┐ ┌──────┐ ┌────────┐ ┌────────┐ ┌──────────┐
  │Postgres│ │ClickHse│ │Valkey│ │ Qdrant │ │TiKV+PD│ │  MinIO   │
  └────────┘ └────────┘ └──────┘ └────────┘ └────────┘ └──────────┘
```

## 前置依赖

### 集群需求

| 组件 | 说明 | 推荐版本 | 必要性 |
|---|---|---|---|
| **Kubernetes 集群** | 支持 v1.25+ | ≥ v1.25 | **必需** |
| **Helm** | 包管理工具 | ≥ v3.12 | 推荐 |
| **Ingress Controller** | 对外暴露 HTTP 服务 | — | **可选**，可按需选择： |
| ├─ HAProxy Ingress | 生产级，支持 path-rewrite | — | 当前生产环境使用 |
| ├─ Nginx Ingress | 社区主流，功能丰富 | — | 常见替代方案 |
| ├─ AWS ALB / GCP LB | 云厂商负载均衡 | — | 云环境首选 |
| └─ 其他 (traefik / istio) | — | — | 按团队技术栈选择 |
| **cert-manager** | TLS 证书自动管理 | ≥ v1.12 | **可选**（不使用 TLS 或手动管理证书时可跳过） |
| **ArgoCD** | GitOps 部署工具 | ≥ v2.8 | **可选**（Helm CLI 也可直接部署） |

### 基础设施中间件

这些组件**不在本 Chart 中管理**，需提前在集群中部署就绪：

| 中间件 | 部署方式示例 | 备注 |
|---|---|---|
| **PostgreSQL** | [CNPG Operator](https://cloudnative-pg.io/) | 使用内部 `cnpg-cluster` chart |
| **ClickHouse** | [Altinity Operator](https://github.com/Altinity/clickhouse-operator) | 使用内部 `clickhouse-cluster` chart |
| **Valkey / Redis** | 官方 Helm Chart (valkey/valkey) | |
| **Qdrant** | 官方 Helm Chart (qdrant/qdrant) | 当前 values 已按单节点配置 |
| **TiKV + PD** | StatefulSet 直 deploy | 参见 `k8s/middlewares/tikv-pd.yaml` |
| **MinIO** | 直接 K8s 资源 (pgsty/minio) | 参见 `k8s/middlewares/minio.values.yaml` |

### 单节点最小验证配置

当前 `k8s/middlewares/` 下的默认配置已按 k3s 单节点最小验证调整：

- StorageClass 使用 k3s 默认 `local-path`
- PostgreSQL、ClickHouse、ClickHouse Keeper、Qdrant、PD、TiKV、MinIO 均为单副本
- 中间件 PVC 申请量合计约 39Gi，80G 系统盘可用于部署流程验证
- 该配置不提供多副本高可用，不适合作为生产配置

### 集群部署配置

仓库同时保留一套集群部署配置，用于多节点 Kubernetes 环境：

| 场景 | 业务配置 | 中间件配置 |
|---|---|---|
| 单节点验证 | `k8s/values.yaml` | `k8s/middlewares/*.values.yaml`、`k8s/middlewares/minio.values.yaml`、`k8s/middlewares/tikv-pd.yaml` |
| 集群部署 | `k8s/values.cluster.yaml` | `k8s/middlewares/*.cluster.values.yaml`、`k8s/middlewares/minio.cluster.yaml`、`k8s/middlewares/tikv-pd.cluster.yaml` |

集群配置按 README 的 Ingress 路由模板启用 HAProxy Ingress，并把业务服务副本数调整为 2。中间件配置调整为 PostgreSQL 3 实例、ClickHouse 2 副本 + Keeper 3 副本、Qdrant 3 副本、Valkey 1 主 2 从、MinIO 4 副本、PD 3 副本、TiKV 3 副本。

部署集群配置前必须把所有 `REPLACE_WITH_CLUSTER_STORAGE_CLASS` 替换成实际集群 StorageClass。不要在多节点集群中使用 `local-path` 承载生产数据。

不要把集群配置直接叠加到已有单节点验证环境。部分资源的部署形态会变化，例如 MinIO 从 Deployment/PVC 切换为 StatefulSet/volumeClaimTemplates，PD/TiKV 从单副本切换为 3 副本。已有数据环境需要先制定迁移或重建方案；新集群建议使用全新 namespace 按集群配置部署。

### 网络连通性

各业务服务通过 **K8s Service DNS** 访问基础设施，例如：

- PostgreSQL: `alephant-postgres-rw.alephant-prod.svc.cluster.local:5432`
- ClickHouse: `clickhouse-ch.alephant-prod.svc.cluster.local:8123`
- Valkey: `alephant-valkey.alephant-prod.svc.cluster.local:6379`
- Qdrant: `alephant-prod-qdrant.alephant-prod.svc.cluster.local:6333`
- PD: `pd.alephant-prod.svc.cluster.local:2379`
- MinIO: `alephant-minio.alephant-prod.svc.cluster.local:9000`

---

## 快速开始

以下命令默认在项目根目录执行。

### 1. 准备命名空间和中间件凭据

部署中间件前先准备并记录同一组中间件凭据。中间件部署会通过 Secret 或 Helm `--set-string` 注入这些值，不要把真实密码/API Key 写入 `k8s/middlewares/*.yaml`。后续 `start-k8s.sh` 也会要求导出同一组环境变量：

```bash
export NAMESPACE=alephant-prod
export POSTGRES_PASSWORD="<replace-me>"
export CLICKHOUSE_PASSWORD="<replace-me>"
export VALKEY_PASSWORD="<replace-me>"
export QDRANT_API_KEY="<replace-me>"
export MINIO_ROOT_USER="minioadmin"
export MINIO_ROOT_PASSWORD="<replace-me>"
```

建议使用 `openssl rand -hex 16` 生成无引号、无空格的值，避免写入 YAML、shell 和连接串时转义出错。

### 2. 部署基础设施中间件

按 [基础设施部署参考](#基础设施部署参考) 部署 PostgreSQL、ClickHouse、Valkey、Qdrant、MinIO、PD 和 TiKV，并确认所有 Pod Running。

如果使用集群配置，部署前先替换 StorageClass 占位值：

```bash
export STORAGE_CLASS="<your-cluster-storage-class>"
grep -R "REPLACE_WITH_CLUSTER_STORAGE_CLASS" k8s/middlewares
```

确认 StorageClass 后，把集群配置文件中的 `REPLACE_WITH_CLUSTER_STORAGE_CLASS` 替换为实际值，再执行对应的集群部署命令。

### 3. 创建业务 Secret、ConfigMap 并初始化数据库

```bash
bash start-k8s.sh
```

详见 [Secrets 管理](#secrets-管理) 章节。

### 4. 部署业务 Helm Chart

```bash
helm repo add weconomy https://helm-charts.weconomy.network
helm upgrade --install alephant-prod weconomy/common \
  --version 0.1.16 \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f k8s/values.yaml
```

集群部署使用：

```bash
helm upgrade --install alephant-prod weconomy/common \
  --version 0.1.16 \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f k8s/values.cluster.yaml
```

部署前请按实际访问方式确认前端运行时环境变量。仅做 SSH tunnel / port-forward 验证时，可使用当前默认值：

```yaml
app:
  env:
    API_BASE_URL:
      value: "http://127.0.0.1:18080"
    GATEWAY_BASE_URL:
      value: "http://127.0.0.1:18081/v1"
    COLLECTOR_BASE_URL:
      value: "http://127.0.0.1:18082"
```

如果使用公网域名或 Ingress，需要替换为浏览器可访问的域名地址，例如 `https://your-domain.com`、`https://ai.your-domain.com/v1`、`https://analytics.your-domain.com`。这里不能填写集群内 Service DNS，因为前端代码运行在用户浏览器中。`k8s/values.cluster.yaml` 默认沿用 README 中的 `openmodels.link`、`ai.openmodels.link`、`analytics.openmodels.link` 路由模板，实际部署前请按现场域名调整。

### 5. （可选）启用 Ingress

单节点验证配置可编辑 `k8s/values.yaml`，将 `ingress.enabled` 设为 `true`，并填入你的 Ingress Controller `className` 和域名配置。集群配置 `k8s/values.cluster.yaml` 已默认启用 Ingress。

### 6. 验证部署

```bash
kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
```

---


## 基础设施依赖

业务服务依赖以下基础设施，其连接信息通过 Secret 注入到各服务的环境变量中：

| 依赖 | 用途 | 被哪些服务使用 |
|---|---|---|
| **PostgreSQL** | 主数据库 (SaaS 业务数据) | saasService |
| **ClickHouse** | 分析数据库 (日志、统计数据) | logsCollector, saasService |
| **Valkey / Redis** | 缓存、会话 | saasService, policyService |
| **Qdrant** | 向量数据库 (AI 检索) | aiGateway |
| **TiKV + PD** | 分布式 KV 存储 (AI 网关持久化) | aiGateway |
| **MinIO** | S3 兼容对象存储 (文件、模型数据) | aiGateway |

这些组件**不在 `common` chart 中管理**，需提前部署。下面是各中间件的部署参考。

---

## 基础设施部署参考

以下默认命令基于 k3s 单节点最小验证环境。各中间件的完整 values 配置保存在 `k8s/middlewares/` 目录下，使用 `-f` 引用即可。集群部署时，把命令中的单节点配置文件替换为对应的 `*.cluster.*` 文件。

### PostgreSQL (CNPG Operator)

使用内部 `cnpg-cluster` chart 部署高可用 PostgreSQL 集群。

当前 `sql/pgsql.sql` 由 PostgreSQL 18.3 导出，`k8s/middlewares/postgres.values.yaml` 必须保持 `ghcr.io/cloudnative-pg/postgresql:18.3` 或更高兼容版本。不要降级到 PostgreSQL 17.x，否则初始化可能出现 dump 语法兼容错误。

```bash
helm repo add weconomy https://helm-charts.weconomy.network

kubectl create secret generic alephant-postgres-app \
  --namespace alephant-prod \
  --from-literal=username=alephant \
  --from-literal=password="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install alephant-postgres weconomy/cnpg-cluster \
  --version 0.1.0 \
  --namespace alephant-prod \
  --create-namespace \
  -f k8s/middlewares/postgres.values.yaml
```

集群部署时使用 `k8s/middlewares/postgres.cluster.values.yaml`。

服务地址: `alephant-postgres-rw.alephant-prod.svc.cluster.local:5432`
数据库: `alephant`，用户: `alephant`

> **部署前请确认**: `POSTGRES_PASSWORD` 与 `alephant-postgres-app` Secret 中的 `password` 一致。

配置参考:
- 单节点验证: [`k8s/middlewares/postgres.values.yaml`](middlewares/postgres.values.yaml)
- 集群部署: [`k8s/middlewares/postgres.cluster.values.yaml`](middlewares/postgres.cluster.values.yaml)

---

### ClickHouse (Altinity Operator)

使用内部 `clickhouse-cluster` chart 部署 ClickHouse 集群（含 ClickHouse Keeper 仲裁）。

Altinity Operator 如果安装在 `clickhouse` namespace，默认可能只监听自身 namespace。部署业务 namespace 前先确认它监听 `alephant-prod`：

```bash
kubectl set env deployment/clickhouse-operator-altinity-clickhouse-operator \
  -n clickhouse WATCH_NAMESPACES=clickhouse,alephant-prod
kubectl rollout restart deployment/clickhouse-operator-altinity-clickhouse-operator -n clickhouse
kubectl rollout status deployment/clickhouse-operator-altinity-clickhouse-operator -n clickhouse --timeout=180s
```

Operator 0.27.x 默认在 Keeper 配置中启用 `use_xid_64`，要求 ClickHouse Keeper 25.3+。因此当前 values 固定为 `clickhouse-server:25.3` 和 `clickhouse-keeper:25.3-alpine`；不要改回 24.8，否则 Keeper 会因 `Unknown setting 'use_xid_64'` 启动失败。

```bash
helm repo add weconomy https://helm-charts.weconomy.network

helm upgrade --install alephant-clickhouse weconomy/clickhouse-cluster \
  --version 0.1.1 \
  --namespace alephant-prod \
  --create-namespace \
  -f k8s/middlewares/clickhouse.values.yaml \
  --set-string users.default/password="$CLICKHOUSE_PASSWORD"
```

集群部署时使用 `k8s/middlewares/clickhouse.cluster.values.yaml`。

> **注意**: 首次部署需先安装 [Altinity ClickHouse Operator](https://github.com/Altinity/clickhouse-operator)。
> **部署前请确认**: 已导出 `CLICKHOUSE_PASSWORD`。密码通过 Helm `--set-string` 注入，不要把真实密码写入 `k8s/middlewares/clickhouse.values.yaml`。单节点配置按 k3s 默认 Pod CIDR `10.42.0.0/16`、Service CIDR `10.43.0.0/16` 预置；集群配置部署前建议按实际 Pod CIDR 和 Service CIDR 收窄 `users.default/networks/ip`。

服务地址:
- HTTP: `clickhouse-ch.alephant-prod.svc.cluster.local:8123`
- 原生 TCP: `clickhouse-ch.alephant-prod.svc.cluster.local:9000`

配置参考:
- 单节点验证: [`k8s/middlewares/clickhouse.values.yaml`](middlewares/clickhouse.values.yaml)
- 集群部署: [`k8s/middlewares/clickhouse.cluster.values.yaml`](middlewares/clickhouse.cluster.values.yaml)

---

### Valkey / Redis

使用官方 Valkey Helm Chart 部署（兼容 Redis 协议）。

```bash
helm repo add valkey https://valkey.io/valkey-helm/

helm upgrade --install alephant-valkey valkey/valkey \
  --version 0.9.4 \
  --namespace alephant-prod \
  --create-namespace \
  -f k8s/middlewares/valkey.values.yaml \
  --set-string auth.aclUsers.default.password="$VALKEY_PASSWORD"
```

集群部署时使用 `k8s/middlewares/valkey.cluster.values.yaml`。

服务地址: `alephant-valkey.alephant-prod.svc.cluster.local:6379`

> **部署前请确认**: 已导出 `VALKEY_PASSWORD`。密码通过 Helm `--set-string` 注入，不要把真实密码写入 `k8s/middlewares/valkey.values.yaml`。

配置参考:
- 单节点验证: [`k8s/middlewares/valkey.values.yaml`](middlewares/valkey.values.yaml)
- 集群部署: [`k8s/middlewares/valkey.cluster.values.yaml`](middlewares/valkey.cluster.values.yaml)

---

### Qdrant (向量数据库)

使用官方 Helm Chart 部署。当前 values 已配置为单节点并关闭集群模式。

```bash
helm repo add qdrant https://qdrant.github.io/qdrant-helm/

helm upgrade --install alephant-prod-qdrant qdrant/qdrant \
  --version 1.17.1 \
  --namespace alephant-prod \
  --create-namespace \
  -f k8s/middlewares/qdrant.values.yaml \
  --set-string config.service.api_key="$QDRANT_API_KEY"
```

集群部署时使用 `k8s/middlewares/qdrant.cluster.values.yaml`。

服务地址:
- HTTP: `alephant-prod-qdrant.alephant-prod.svc.cluster.local:6333`
- gRPC: `alephant-prod-qdrant.alephant-prod.svc.cluster.local:6334`

> **部署前请确认**: 已导出 `QDRANT_API_KEY`。API Key 通过 Helm `--set-string` 注入，不要把真实值写入 `k8s/middlewares/qdrant.values.yaml`。

配置参考:
- 单节点验证: [`k8s/middlewares/qdrant.values.yaml`](middlewares/qdrant.values.yaml)
- 集群部署: [`k8s/middlewares/qdrant.cluster.values.yaml`](middlewares/qdrant.cluster.values.yaml)

---

### MinIO (S3 兼容对象存储)

与 Docker Compose 一致，使用 `pgsty/minio` 镜像直接部署。

```bash
kubectl create secret generic alephant-minio-secret \
  --from-literal=MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  --from-literal=MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -n alephant-prod \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/middlewares/minio.values.yaml
```

集群部署时使用：

```bash
kubectl apply -f k8s/middlewares/minio.cluster.yaml
```

> **部署前请确认**: 已导出 `MINIO_ROOT_USER` 和 `MINIO_ROOT_PASSWORD`。MinIO 账号密码通过 `alephant-minio-secret` 注入，不要把真实密码写入 `k8s/middlewares/minio.values.yaml`。
> **注意**: `pgsty/minio` 镜像需要保留镜像入口点，启动参数必须写在 `args` 中，不能用 `command` 覆盖 entrypoint。

服务地址:
- S3 API: `alephant-minio.alephant-prod.svc.cluster.local:9000`
- Console: `alephant-minio.alephant-prod.svc.cluster.local:9001`

配置参考:
- 单节点验证: [`k8s/middlewares/minio.values.yaml`](middlewares/minio.values.yaml)
- 集群部署: [`k8s/middlewares/minio.cluster.yaml`](middlewares/minio.cluster.yaml)

---

### TiKV + PD (分布式 KV 存储)

TiKV + PD 在 Docker Compose 中直接使用 PingCAP 官方镜像启动。K8s 中可通过 StatefulSet 部署。

```bash
kubectl apply -f k8s/middlewares/tikv-pd.yaml
```

集群部署时使用：

```bash
kubectl apply -f k8s/middlewares/tikv-pd.cluster.yaml
```

配置参考:
- 单节点验证: [`k8s/middlewares/tikv-pd.yaml`](middlewares/tikv-pd.yaml)
- 集群部署: [`k8s/middlewares/tikv-pd.cluster.yaml`](middlewares/tikv-pd.cluster.yaml)

服务地址:
- PD: `pd.alephant-prod.svc.cluster.local:2379`
- TiKV: `tikv.alephant-prod.svc.cluster.local:20160`

---


## Secrets 管理

业务服务的环境变量通过 K8s Secret 注入。`start-k8s.sh` 不再随机生成中间件密码，会使用当前 shell 中已经导出的中间件凭据。如果前面已经在当前 shell 中导出过这些变量，可以直接执行脚本；如果是新终端或重新登录服务器，请重新导出：

```bash
export POSTGRES_PASSWORD="<same-as-alephant-postgres-app>"
export CLICKHOUSE_PASSWORD="<same-as-clickhouse-helm-set>"
export VALKEY_PASSWORD="<same-as-valkey-helm-set>"
export QDRANT_API_KEY="<same-as-qdrant-helm-set>"
export MINIO_ROOT_USER="minioadmin"
export MINIO_ROOT_PASSWORD="<same-as-alephant-minio-secret>"
```

执行脚本前可以用以下命令检查变量是否已设置；该命令不会打印真实密码：

```bash
for v in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD VALKEY_PASSWORD QDRANT_API_KEY MINIO_ROOT_PASSWORD; do
  [ -n "${!v:-}" ] && echo "$v 已设置" || echo "$v 未设置"
done
```

启动脚本：

```bash
bash start-k8s.sh
```

脚本会校验以上变量，自动生成业务侧随机密钥，并创建以下 4 个 Secret：

| Secret 名称 | 对应服务 | 对应 docker-compose 文件 |
|---|---|---|
| `alephant-saas-service-secrets` | saasService | `saas-service.env` |
| `alephant-policy-service-secrets` | policyService | `policy-service.env` |
| `alephant-ai-gateway-secrets` | aiGateway | `ai-gateway.env` |
| `alephant-logs-collector-secrets` | logsCollector | `logs-collector.env` |

在 `values.yaml` 中通过 `envFrom` 引用这些 Secret：

```yaml
saasService:
  envFrom:
    - secretRef:
        name: alephant-saas-service-secrets
```

---

## License 激活

Alephant 私有化部署需要有效的 License 文件进行授权验证。License 通过 JWT 文件注入到 `saasService`。

### 准备工作

1. 联系 Alephant 团队获取 `license.jwt` 文件
2. 将文件放置到 `alephant-deploy/license/license.jwt`
3. 可选：提前导出工作空间拥有者邮箱，多个邮箱用英文逗号分隔。不导出也可以，`start-k8s.sh` 会提示输入。

   ```bash
   export PRIVATE_WORKSPACE_OWNER_EMAILS="admin@example.com"
   ```

首次部署时不需要手动创建 `alephant-license` ConfigMap。执行 `start-k8s.sh` 时，脚本会读取 `license/license.jwt`；如果未导出 `PRIVATE_WORKSPACE_OWNER_EMAILS`，脚本会提示输入邮箱，然后统一创建 License ConfigMap、业务 Secret 和 SQL ConfigMap。

### K8s 挂载配置

`values.yaml` 中 `saasService` 已预置 volume 挂载和环境变量：

```yaml
saasService:
  volumes:
    - name: license
      configMap:
        name: alephant-license
  volumeMounts:
    - name: license
      mountPath: /etc/alephant/license
      readOnly: true
  env:
    ALEPHANT_LICENSE_FILE:
      value: /etc/alephant/license/license.jwt
    PRIVATE_WORKSPACE_OWNER_EMAILS:
      valueFrom:
        configMapKeyRef:
          name: alephant-license
          key: PRIVATE_WORKSPACE_OWNER_EMAILS
```

### 更新 License

```bash
# 1. 更新 ConfigMap
kubectl create configmap alephant-license \
  --from-file=license.jwt=./license/license.jwt \
  --from-literal=PRIVATE_WORKSPACE_OWNER_EMAILS="admin@example.com" \
  -n alephant-prod -o yaml --dry-run=client | kubectl replace -f -

# 2. 滚动重启 saasService 使新 License 生效
kubectl rollout restart deployment/alephant-saas-service -n alephant-prod
```

### 验证 License

```bash
# 查看 saasService 日志确认 License 加载状态
kubectl logs -l app=alephant-saas-service -n alephant-prod --tail=50 | grep -i license

# 或通过 API 验证
kubectl port-forward svc/alephant-saas-service 8080:8080 -n alephant-prod &
curl http://localhost:8080/api/v1/health
```

---

## Ingress 路由

下面是当前生产环境的 Ingress 路由表，配置了 HAProxy Ingress + cert-manager 自动 TLS。作为参考模板，你可以按自己的 Ingress Controller 调整。

| 域名 | 路由路径 | 后端 Service | 说明 |
|---|---|---|---|
| **openmodels.link** | `/api/v1` | saas-service:8080 | SaaS API |
| | `/v1/policy` | policy-service:8090 | 策略服务 |
| | `/` | app:80 (SPA) | 前端页面 |
| **ai.openmodels.link** | `/v1` | ai-gateway:8080 | AI 网关 |
| **analytics.openmodels.link** | `/v1` | logs-collector:8585 | 日志分析 |
| **api.openmodels.link** | `/v1` → `/key_market/` (rewrite) | ai-gateway:8080 | API 市场 (带 path rewrite) |

## 扩缩容

通过 common chart 的 `replicas` 字段调整：

```yaml
saasService:
  replicas: 3   # 从 1 扩到 3
```

重新应用即可生效：

```bash
helm upgrade alephant-prod /path/to/charts/common -f k8s/values.yaml
```

或临时通过 kubectl 调整：

```bash
kubectl scale deployment alephant-saas-service --replicas=3 -n alephant-prod
```

> **注意**: 如果使用 GitOps（ArgoCD/Flux），`kubectl scale` 的更改会在下一次同步时被覆盖。持久更改应修改 values 文件。

---

## 常见问题

### ClickHouse / Keeper 没有创建 Pod

先确认 Altinity Operator 是否监听了业务 namespace：

```bash
kubectl logs -n clickhouse deploy/clickhouse-operator-altinity-clickhouse-operator --tail=100 | grep -A5 'watch.namespaces.include'
```

如果只看到 `clickhouse`，按 ClickHouse 部署章节设置 `WATCH_NAMESPACES=clickhouse,alephant-prod` 后重启 Operator。

### Keeper CrashLoopBackOff 且日志出现 `use_xid_64`

这是 Operator 0.27.x 与旧版 Keeper 镜像不兼容。保持 `clickhouse-keeper:25.3-alpine` 或更高兼容版本，然后重新 `helm upgrade` ClickHouse release。

### MinIO CrashLoopBackOff 且日志出现 `exec: "server": executable file not found`

说明 manifest 把 `server` 写到了 `command`，覆盖了镜像 entrypoint。使用当前 `k8s/middlewares/minio.values.yaml` 中的 `args` 写法后重新 apply 并重启 MinIO。

### PostgreSQL 初始化出现 `syntax error at or near "."`

通常是 SQL 里出现了 `CREATE INDEX public.index_name ...` 这种 PostgreSQL 不接受的 schema-qualified index name。当前 `sql/pgsql.sql` 已修正为不带 `public.` 的索引名。旧版本文档或旧 SQL 需要同步更新后再初始化全新数据库。

### 业务服务无法连接 ClickHouse

实际服务名是 `clickhouse-ch`，不是 `ch-clickhouse`。检查 `alephant-ai-gateway-secrets` 和 `alephant-logs-collector-secrets` 中的 `CLICKHOUSE_CREDS`，应指向 `http://clickhouse-ch:8123`。

### port-forward 报 `accept: Too many open files`

通常是重复启动了多个 SSH tunnel 或 `kubectl port-forward` 进程。先清理旧转发，再提高当前 shell 的文件句柄限制后重新启动：

```bash
pkill -f 'kubectl.*port-forward.*alephant' || true
ulimit -n 65535
```

建议用 `nohup kubectl port-forward ... &` 后台启动，并把日志写入 `/tmp/*-pf.log`，不要在多个终端反复启动同一组端口。
