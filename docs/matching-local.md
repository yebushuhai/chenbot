# 在本机运行交友功能

在 Chenbot 仓库根目录打开终端。这个工作区已有 Flutter、PostgreSQL、Supabase Auth、PostgREST 和 Mailpit，可以直接启动。

```sh
python3 server/tests/local_otp_stack.py --serve
```

终端会显示本地 API 地址、测试邮箱网页、Flutter 配置文件路径和启动命令。保持这个终端打开。每次运行都新建独立的数据库、邮箱和签名密钥，所有服务只监听本机。按 Ctrl+C 会停止服务并删除本轮的账号、消息和匹配数据。

## 在手机上打开

1. 在仓库根目录打开第二个终端。连接 Pixel 并允许 USB 调试，或启动 Android 模拟器。
2. 复制第一个终端显示的 `adb reverse` 命令，让设备通过 USB 或模拟器连接 Mac 上的本地端口。如果有多个 Android 设备，在 `adb` 后加 `-s 设备序列号`。
3. 复制显示的 `flutter run --debug --dart-define-from-file=…` 完整命令，选择目标设备。也可以在命令末尾加 `-d 设备序列号`。使用 iOS 模拟器时可直接执行这一步。该配置使用回环地址，仅供调试构建。
4. 打开底部的 **发现**，用 `alice@example.test` 注册。在浏览器打开终端显示的测试邮箱网页，按收件人找到验证码，回到 App 输入。开启发现时需要确认已年满 18 岁。

一台设备也能测试两个人。在 **我的** 里退出，用另一个测试邮箱登录，例如 `bob@example.test`。切回 Alice 时用新邮件里的验证码。两台设备联调时使用同一次服务输出的配置文件，Android 设备分别做端口转发。

## 体验两条匹配流程

- **Blind Encounter**。两个账号都选静安、5 公里、任意氛围、明天上海时间 14:00 至 16:00。第一个提交后会等待，第二个提交后会出现提议。返回第一个账号点击刷新。两个账号均确认后才会出现具体时间和标注“开发测试”的虚构场所。请勿前往。见面完成操作按服务器时钟在时段结束后开放。
- **Secret Match**。Alice 生成随机口令，在提交前保存以便交给 Bob。两人分别同意并提交相同口令，进入匿名连接后可以实际收发文字。单个账号提交时保持等待，返回页面或点击刷新可查看状态。

这台 Mac 的测试邮箱网页能看到本轮所有测试账号收到的邮件，请使用测试地址。重启服务后，重新复制新一轮的命令启动 App。下列命令会启动独立的临时服务，验证收信、再次登录、匹配、聊天、退出配对，以及 SQL 和并发 HTTP 回归套件；全部完成后自动退出。

```sh
python3 server/tests/local_otp_stack.py
```

## 换一台开发机

需要 Python 3.9 或以上和 Flutter 项目原有移动工具链。后端脚本优先使用显式环境变量，然后查找 PATH，最后尝试本工作区的已有工具。已验证的组合为 PostgreSQL 17.12、Supabase Auth v2.198.0、PostgREST 16.6、Mailpit v1.34.0。准备好对应平台的可执行文件，按需设置以下路径后即可使用相同启动命令。

| 环境变量 | 应指向 |
| --- | --- |
| `PG_BIN` | 包含 `initdb`、`pg_ctl` 和 `psql` 的目录 |
| `AUTH_BIN` | Supabase Auth 的可执行文件 |
| `AUTH_MIGRATIONS` | 同版本 Supabase Auth 的 SQL 迁移目录，默认使用 Auth 可执行文件旁边的 `migrations` |
| `POSTGREST_BIN` | PostgREST 可执行文件 |
| `MAILPIT_BIN` | Mailpit 可执行文件 |

其他设备和公网用户的接入请按[阿里云部署说明](matching-deployment.md)配置 HTTPS 服务。
