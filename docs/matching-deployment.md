# 在阿里云 Linux 实例部署 Chenbot 匹配服务

公网接入完成后，Flutter 通过 HTTPS 访问匹配服务。Auth 验证邮箱并签发会话，PostgREST 调用 PostgreSQL 中的匹配事务。上海场所目录和匹配记录只供服务器访问。交友功能可以独立于 DeepSeek 运行。

仓库提供部署配置、数据库迁移与定时清理入口。域名、ECS 实例、发信配置及已核实地点由运营者提供。开发数据与生产数据使用独立的实例、密钥、邮箱服务和域名。

## 上海轻量实例的实际部署

2026 年 11 月 18 日，`Docker-qrun` 已部署[四容器方案](../server/deploy/compact/README.md)。安装目录为 `/srv/chenbot-matching`，Docker Compose 项目名为 `chenbot-matching`。Caddy 直接将受允许的请求转发给 Auth 和 PostgREST，匹配数据库使用持久卷。宿主机仅在 `127.0.0.1:18080` 提供该 API。

云端验收通过了入口鉴权、五项迁移的 SHA-256 校验、生产场所模式检查。验收脚本在独立临时库中重放迁移并验证了重复提交、真实等待以及两名测试用户用同一口令获得同一个匿名连接。小时清理定时器已启用，首次执行成功。核对运行状态可在该服务器执行：

```sh
cd /srv/chenbot-matching
python3 server/deploy/compact/manage.py status
python3 server/deploy/compact/smoke.py
systemctl list-timers chenbot-matching-maintain.timer
```

本次部署保留了回环入口并关闭邮箱注册。手机切换前，还需配置 API 域名的 HTTPS 入口与真实 SMTP，分别验证首次注册和老用户重新登录。开放线下见面前还需核实并录入上海场所。以下第 1 至 3 节记录基于官方完整 Compose 的另一种安装方式，维护当前实例请使用上方四容器方案。

## 1. 准备 ECS、域名和数据库

2026 年 11 月 18 日在阿里云控制台核对，上海轻量应用服务器为 **2 vCPU、2 GiB 内存、40 GiB 磁盘**，之前为 Chenbot 配置过 Nginx。Supabase 给完整自托管栈的最低参考是 2 核、4 GB 内存和 40 GB SSD，推荐 4 核以上、8 GB 以上内存和 80 GB 以上 SSD。这台机器的内存低于完整栈最低参考值。已部署的四容器方案通过了功能验收，生产并发容量仍待实测。正式承载用户前应测量并发登录与匹配的内存、延迟、数据库增长和备份余量，据此决定扩容。[Supabase 自托管系统要求](https://supabase.com/docs/guides/self-hosting/docker#system-requirements)

准备 Linux 轻量应用服务器或 ECS、Docker Engine、Docker Compose v2.24.4 或以上、Git、Python 3、持久化磁盘，以及指向该 ECS 的 API 域名。安全组与主机防火墙只向公网开放 TCP 80/443；SSH 仅向运维网络或堡垒机开放。若设置 AAAA 记录，确保 IPv6 入站也可达。为 SMTP、软件镜像与 TLS 证书签发保留必要出站连接。为数据库卷、备份和密钥配置磁盘加密与最小访问权限。

以下以新环境为例，假设应用仓库位于 `/srv/chenbot`。部署目录和含服务器密钥的文件由受信运维账号持有。备份现有环境后再升级。自托管版本固定在官方 `self-hosted/v0.8.4`，其默认网关服务名是 `api-gw`。更换版本需要重新比对 Compose、认证配置和网关路由。[Supabase 自托管安装指南](https://supabase.com/docs/guides/self-hosting/docker) · [固定版本的官方 Compose](https://github.com/supabase/supabase/blob/self-hosted/v0.8.4/docker/docker-compose.yml)

```sh
umask 077
git clone --depth 1 --branch self-hosted/v0.8.4 https://github.com/supabase/supabase.git /srv/chenbot-supabase-source
mkdir -p /srv/chenbot-supabase
cp -a /srv/chenbot-supabase-source/docker/. /srv/chenbot-supabase/
cd /srv/chenbot-supabase
cp -a /srv/chenbot/server/deploy ./chenbot-deploy
cp .env.example .env
printf 'ref=self-hosted/v0.8.4\n' > .supabase-version
chmod 600 .env
sh utils/generate-keys.sh
sh utils/add-new-auth-keys.sh
```

仅在**首次配置**时运行生成脚本，按官方脚本提示保存生成的值。升级时保留已有数据库密码、JWT 和服务端签名密钥。在受信终端运行这些脚本，关闭 shell 跟踪与终端录屏。按官方版本指南完成签名方式配置；本覆盖文件将生成的 `JWT_KEYS` 交给 Auth，官方 REST 服务从 `JWT_JWKS` 读取配套验签材料。移动端用生成的 **publishable key** 或标准 anon key，所有管理密钥和私钥只在服务器保管。

在 `/srv/chenbot-supabase/.env` 中设置下列值。示例域名须换成自己的域名。

| 配置 | 设置 |
| --- | --- |
| `MATCHING_DOMAIN` | API 主机名，例如 `api.example.com`，不含协议和路径 |
| `SUPABASE_PUBLIC_URL` | `https://api.example.com` |
| `API_EXTERNAL_URL` | `https://api.example.com/auth/v1` |
| `SITE_URL` | 本部署的可信 HTTPS 地址；邮箱验证码流程在 App 内完成 |
| `ADDITIONAL_REDIRECT_URLS` | 第一版留空 |
| `DISABLE_SIGNUP` / `ENABLE_EMAIL_SIGNUP` / `ENABLE_EMAIL_AUTOCONFIRM` | 分别为 `false` / `true` / `false` |
| `ENABLE_ANONYMOUS_USERS` / `ENABLE_PHONE_SIGNUP` | 均为 `false` |
| `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS` | 已授权的事务邮件 SMTP 服务、提供方支持的 TLS 端口与独立发信凭据；从部署网络验证实际加密投递 |
| `SMTP_ADMIN_EMAIL` / `SMTP_SENDER_NAME` | 已完成域名验证的发信地址 / `Chenbot` |
| `MATCHING_OTP_HOURLY_LIMIT` | 默认全服务每小时 30 次发信预算，按真实邮件容量设置，共享额度耗尽会影响所有用户 |

发信域名完成提供方要求的 SPF、DKIM 等验证。覆盖文件给首次注册确认和老用户登录使用相同的数字验证码模板，10 分钟有效，同一邮箱重发至少等 60 秒。Auth 从内网读取 `otp.html`；验证码只发往用户输入的邮箱。服务提供商及收信人邮箱会接触验证码；关闭邮件正文留存、点击追踪和测试转发，设置发信失败率与配额告警。上线前分别验证新邮箱、老邮箱、过期码、错误码、重发、退出后重登与会话刷新。[邮箱 OTP](https://supabase.com/docs/guides/auth/auth-email-passwordless) · [自托管邮件模板](https://supabase.com/docs/guides/self-hosting/custom-email-templates)

## 2. 选择独立 TLS 入口或复用现有 Nginx

项目此前的运维记录提到 `chenbot.cn` 曾配置过 Nginx。上线前先在 ECS 查看实际的监听端口和现有虚拟主机。新匹配服务先使用独立预发布域名（例如自己管理的 `match-staging.chenbot.cn`），独立数据库和 SMTP 配置，验证通过再发布。现有服务占用 80/443 时使用下方的复用方式，保留其证书和流量。

**全新、独占端口的 ECS** 使用默认覆盖文件，由 Caddy 终止 TLS。**已有宿主机 Nginx 的 ECS** 再叠加 `compose.existing-proxy.yml`。后者让 Caddy 仅对宿主机回环开放 `127.0.0.1:18080`，保留相同的请求白名单与内网邮件模板。设置 `MATCHING_TRUSTED_PROXY` 为实测的宿主机来源地址 CIDR（Docker 网桥网关的单个 IPv4 /32 或 IPv6 /128），从外网到 Nginx 的防火墙仅开放所需端口。该现有 Nginx 配置方式要求 Compose v2.24.4+。

在现有 Nginx 为**新域名**单独建 HTTPS 虚拟主机，使用其已有的证书签发与续期流程；在新域名的 `location /` 中配置以下内容，保留现有站点的独立配置。使用 `nginx -t` 验证后再进行受控重载。

```nginx
access_log off;
error_log /dev/null crit;
proxy_pass http://127.0.0.1:18080;
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header X-Forwarded-For $remote_addr;
```

## 3. 启动、迁移与校验

在 `/srv/chenbot-supabase` 执行。命令只启动所需服务和上游声明的依赖。Caddy 先供 Auth 读取模板。Auth 创建身份表后执行应用迁移，最后启动 API 网关。DB、网关、控制台与连接池均不发布宿主端口。证书和数据库保存在持久卷中。[Supabase HTTPS 反向代理](https://supabase.com/docs/guides/self-hosting/self-hosted-proxy-https)

```sh
cd /srv/chenbot-supabase
dc() { docker compose -f docker-compose.yml -f chenbot-deploy/compose.matching.yml "$@"; }
# 已有宿主机 Nginx 时用下面这一行替换上一行 dc() 定义
# dc() { docker compose -f docker-compose.yml -f chenbot-deploy/compose.matching.yml -f chenbot-deploy/compose.existing-proxy.yml "$@"; }
dc config --quiet
dc up -d --wait db matching-edge
dc up -d --wait auth rest
python3 /srv/chenbot/server/deploy/matching_db.py migrate --compose-dir /srv/chenbot-supabase
dc up -d --wait api-gw
dc ps
```

迁移脚本按编号读取仓库中的 SQL，在同一数据库事务内加锁、核验 SHA-256、应用新版本并登记。相同版本重复执行是安全的；哈希不符或数据库含未知版本会中止并回滚。已由其他方式迁移且没有版本账本的数据库应先在恢复副本中逐项核验并制定基线，避免直接在生产重跑。升级时先做加密备份并在独立实例验证恢复，再部署同一 Git 修订的客户端和新增迁移。历史 SQL 保持不可变。

从外部网络确认 `https://<域名>/auth/v1/settings` 能经 TLS 到达网关（按网关要求附客户端公开 key），`/`、`/auth/v1/admin/users` 和非白名单的 RPC 返回 404。核实公网仅开放指定端口。私有的 `matching` 与 `chenbot_deploy` schema 不加入 `PGRST_DB_SCHEMAS`。服务会用钱包、报名、连接和验证码等不同权限，移动端一律使用公开 key + 登录会话。用两个隔离测试邮箱在预发布环境完整跑一次报名、发码、匿名匹配和取消。

Flutter 现有配置名为 `SUPABASE_ANON_KEY`；该项也接受本部署公开的 publishable key。把下列地址和公开 key 换成经过验证的值。用同样的两个参数配置其他平台的 Flutter 构建。

```sh
flutter run --dart-define=SUPABASE_URL=https://api.example.com --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_KEY
```

## 4. 核实上海场所后开放线下见面

生产迁移仅预置区与参考点，等待队列在没有合格地点或对象时显示真实等待状态。受限场所运营账号在核实公共属性、可达性、现场情况、当地开放日/时间段与复核截止日之后，将记录写入 `matching.blind_venues`，并为实际核实的区参考点写入 `matching.blind_reach` 的向上取整公里数。距离是**区参考点到场所**的运营估值；结果页和隐私说明不应暗示从用户家门精确测距。日期按上海时区，星期一为 1，星期日为 7。第一版只处理同一天内的固定营业时段；遇到临时停业或无法表达的节假日安排，立即暂停该场所并复核。

生产策略 `demo_enabled=false` 且生产地点 `demo=false`。修改、撤销场所或缩短可达范围会使尚未结束的相关提议重新检查或取消。受信运维可用下列只读检查核查模式与合格地点数量。

```sql
select demo_enabled from matching.blind_venue_policy;
select count(*) as currently_eligible from matching.blind_eligible_venues;
```

仅在独立的本机开发数据库，用受信 DBA 设置 `PGOPTIONS='-c matching.environment=development'` 并执行 `server/fixtures/blind_shanghai_dev.sql`。演示地点属于虚构数据，所有显示都带有开发场所标识。生产服务器不得运行 `server/tests/auth_fixture.sql`、任何 `server/tests/*` 或测试地点脚本。真实 Auth、PostgREST 与邮件投递的测试工具见 `server/tests/local_otp_stack.py`，测试只绑定回环地址并使用本地邮件收集器。

## 5. 清理、运行监控和故障恢复

每小时运行一次受信清理任务。下面是持有部署目录和容器权限的运维账号的 crontab 条目；将路径按实际安装位置调整。脚本失败时给运维系统发**状态告警**，保留成功时间、耗时和退出码即可。

```cron
17 * * * * PATH=/usr/local/bin:/usr/bin:/bin /usr/bin/python3 /srv/chenbot/server/deploy/matching_db.py maintain --compose-dir /srv/chenbot-supabase >/dev/null
```

清理调用 `matching.maintain()`，处理过期的报名、连接、消息、举报和关联上下文；实时查询同样检查访问资格。发送密钥、数据库快照、备份、邮件和第三方日志各有独立生命周期。为加密备份规定过期和销毁期限，在恢复后、放开流量前执行清理，并按删除请求记录处理快照回滚造成的数据恢复。

为 Caddy、Envoy、Auth、PostgREST 与 PostgreSQL 关闭 Docker 请求日志采集。禁用 SQL 语句、慢查询/采样、绑定参数、出错语句、pgAudit 参数及自动执行计划日志；不要启用代理请求详情、SLS 正文采集、SQL 查询回放、APM 参数采集或带对象值的 Flutter 崩溃上报。监控可采集进程健康、调用总数、延时和失败率，不附邮箱、IP、请求 ID 与账户的映射、完整 URL、Authorization、OTP、共享令牌、会面地点、消息或举报文本。配置不移除数据库及 Auth 的业务与审计表，数据库管理员、SMTP 和密钥持有者仍属于信任边界。限制其访问、保留期和备份恢复权限。

上线检查应实际检查数据库与目标角色的有效设置（包括 `pg_db_role_setting` 中更具体的覆盖）、PG 扩展、自托管镜像的文件型日志、网关与云端采集器。用专用合成标记在预发布走成功与错误流程，在可访问的日志、追踪和告警中搜索该标记；移除任何正文采集后再上线。关闭数据日志会减少故障诊断线索，在本地隔离环境重现问题。

系统重启后检查证书续签、外部发信、DB 卷和清理任务。上线前需要有人值守举报队列，有撤下不安全地点、处理失联和阻断滥用的责任人。商业环境还需独立核验年龄保障、适用合规要求、区域可用性和邮件送达。单节点部署没有高可用保证。
