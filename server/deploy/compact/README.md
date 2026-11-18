# 单机小容量部署

本目录将原有 PostgreSQL 迁移、Supabase Auth 和 PostgREST 部署在独立的 Docker Compose 项目 `chenbot-matching`。边缘网关使用 Caddy，默认仅向宿主机 `127.0.0.1:18080` 提供 API。由现有 Nginx 终止公网 HTTPS。四个容器的内存上限合计 848 MiB，实际峰值、吞吐和磁盘占用需在目标实例上验证。

在服务器上保留仓库中的 `server/migrations` 和 `server/deploy` 目录结构。需要 Python 3.6+、Docker Engine 与支持 `up --wait` 的 Compose v2。在仓库根目录执行下列命令。

```sh
umask 077
python3 server/deploy/compact/manage.py init
python3 server/deploy/compact/manage.py up
python3 server/deploy/compact/manage.py status
```

首次初始化产生本机独有的数据库、服务角色和签名材料。妥善备份 `server/deploy/compact/.env` 和 Docker 数据卷。迁移脚本按校验和记录五个基线版本，重复运行会核对历史。默认配置禁止注册、禁用邮箱认证；可以先验证数据库、匹配 RPC 和回环 API。虚构地点只供本机试验，此部署不导入演示夹具。

## 发信和外部接入

为自己的 HTTPS 域名配置 DNS、有效证书和反向代理，参照[部署手册](../../../docs/matching-deployment.md)中的 Nginx 配置。公网防火墙仅开放对外 API 所需的端口。真实发信域名、邮箱凭据留在服务器。编辑受保护的 `.env` 文件，设置 `BASE_URL=https://匹配服务域名`、`ENABLE_EMAIL=true`、`DISABLE_SIGNUP=false`、`SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS`、`SMTP_ADMIN_EMAIL`，按供应商要求完成发信域名验证。带特殊字符的 SMTP 凭据使用 Compose 单引号转义规则。设置后重新运行 `manage.py up`。

`python3 server/deploy/compact/manage.py client-config` 只输出 Flutter 需要的服务 URL 和客户端公开 key，其他密钥仅保存在服务端。这两项应来自新部署，使用 Flutter 的 `--dart-define-from-file` 传入。先用专用测试邮箱验证注册、重新登录及两个真实会话的匿名匹配，再开放给普通用户。经过独立安全审核的真实地点由运营者维护。

为该部署安装独立的小时级定时任务，执行 `python3 /实际部署路径/server/deploy/compact/manage.py maintain`，并监控任务退出状态。删除或恢复前应核对操作目标和备份；目录内没有自动销毁卷或重置账户的命令。

## 镜像来源

Compose 固定了 PostgreSQL 17.12、Supabase Auth 2.198.0、PostgREST 16.6 和 Caddy 2.10.2 的上游多架构清单 SHA-256。默认从上游仓库拉取。若大陆网络无法稳定拉取，可在能访问上游的节点将上述已核验镜像同步到自己获授权的阿里云 ACR，设置 `PG_IMAGE`、`AUTH_IMAGE`、`REST_IMAGE`、`CADDY_IMAGE` 为可信仓库中的清单摘要，并在拉取前核对清单和目标架构。也可以在有网络的可信节点获取上述清单对应架构的原始镜像，通过受信通道传输 Docker 归档后在服务器执行 `docker load -i 镜像归档`，然后执行 `python3 server/deploy/compact/manage.py up --offline`。这个命令逐一核对上游镜像配置的 SHA-256、操作系统和架构（配置内含每层文件系统摘要），为已验证内容添加本机标签，并禁止 Compose 重新拉取。支持 Linux amd64 和 arm64。已有阿里云镜像加速器只覆盖其支持的镜像。[阿里云 ACR 镜像拉取说明](https://www.alibabacloud.com/help/en/acr/user-guide/use-a-container-registry-personal-edition-instance-to-push-and-pull-images)
