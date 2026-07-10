# Alephant 一键部署

```bash
cd alephant-docker/
bash start.sh
```

自动完成：
1. 生成随机密码和密钥
2. 填充所有环境变量文件
3. 从 S3 下载业务镜像
4. 拉取中间件（postgres、clickhouse、valkey、qdrant、pd、tikv、minio）
5. 启动全部 12 个服务

## 前置依赖

| 依赖 | 版本要求 | 说明 |
|---|---|---|
| **Docker** | ≥ 24.x | 容器运行时，需包含 **Compose plugin**（`docker compose` 命令） |
| **openssl** | 任意版本 | 用于生成随机密码和密钥 |
| **curl** 或 **wget** | 任意版本 | 用于从 S3 下载业务镜像 |
| **bash** | ≥ 4.x | 运行部署脚本（macOS 需 `brew install bash` 升级） |

### 系统要求

- **操作系统**：Linux（推荐 Ubuntu 22.04+ / Debian 12+）或 macOS
- **CPU**：≥ 4 核
- **内存**：≥ 12 GB（12 个服务合计）
- **磁盘**：≥ 50 GB 可用空间（含业务镜像 ~2 GB + 各中间件数据卷）
- **网络**：需能够访问以下地址：
  - `https://image-exports.alephant.io/alephant` — 下载业务镜像
  - Docker Hub（`docker.io`）— 拉取中间件镜像

### 安装检查

```bash
# 检查 Docker
docker info && docker compose version

# 检查 openssl
openssl version

# 检查下载工具
curl --version || wget --version
```

## 服务

| 服务 | 说明 | 端口 |
|---|---|---|
| **saas-app** | SaaS 前端 | **80** |
| **saas-service** | SaaS 后端 API | 8081 |
| **policy-service** | 策略后端 | 8090 |
| **ai-gateway** | AI 网关 | 8080 |
| **logs-collector** | 日志收集 | 8585 |
| **postgres** | 数据库 | 5432 |
| **clickhouse** | OLAP 分析 | 8123 / 9000 |
| **valkey** | 缓存 | 6379 |
| **pd** | TiKV 集群管理 (Placement Driver) | 2379 |
| **tikv** | 分布式 KV 存储 | 20160 |
| **minio** | S3 兼容对象存储（S3 API/Console） | 9000 / 9001 |
| **qdrant** | 向量数据库 | 6333 / 6334 |

## 常用命令

```bash
docker compose ps                    # 查看状态
docker compose logs -f <service>     # 查看日志
docker compose restart <service>     # 重启服务
docker compose down                  # 停止
bash start.sh                        # 重新部署
```

## .env 文件说明

脚本生成的密码记录在终端输出中，也可直接查看文件：

```bash
cat infra.env          # 基础设施密码
cat saas-service.env   # SaaS 后端配置
```
