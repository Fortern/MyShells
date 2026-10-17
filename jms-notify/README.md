# 某神秘服务的流量监控脚本

脚本由 crontab 每分钟执行。运行时自动创建 SQLite 数据库和锁文件，用于计算短时用量、去重和避免重叠运行。

## 使用

适用于 Linux（Bash 4+、GNU date）。Debian / Ubuntu 安装依赖：

```bash
sudo apt-get install curl jq sqlite3 util-linux coreutils tzdata cron
```

把文件放到 `~/jms-monitor`。工作目录为脚本所在目录。在该目录执行：

```bash
cp config.example config
chmod 600 config
vim config
bash jms-monitor.sh
```

填写服务 ID、UUID 和三个通知参数：

| 参数 | 说明 |
| --- | --- |
| NOTIFY_BASE_URL | 通知 API 的 baseurl，末尾没有 `/` |
| NOTIFY_TOKEN | Bearer Token，只填 Token，不含 `Bearer ` 前缀 |
| NOTIFY_USER_ID | 接收者 ID，用引号括起来 |

通知直接由脚本发送：`POST {baseurl}/send_group_msg`，请求头为 `Authorization: Bearer {token}` 和 `Content-Type: application/json`，请求体为：

```json
{"user_id":"123456789","message":[{"type":"text","data":{"text":"实际提醒内容"}}]}
```

JSON 由 jq 生成，自动处理内容转义。以 HTTP 2xx 为发送成功依据。

执行 `crontab -e`，添加：

```cron
* * * * * /bin/bash "$HOME/jms-monitor/jms-monitor.sh"
```

确保系统 cron 正在运行。

默认读取脚本同目录的 `config`；也可以指定配置路径：

```text
~/jms-monitor/
├── jms-monitor.sh
├── config
├── 123456.sqlite3
└── 123456.lock
```

其中 `123456` 是 SERVICE_ID。SQLite 运行时也可能在同目录生成 `-wal`、`-shm` 文件。运行用户需要对该目录有写权限。

## 告警规则

- **周期比例**：用量达到某些挡位时，通知一次；一次跨过多档合并通知。首次运行已超标也会提醒。
- **短时用量**：默认最近 900 秒使用达到 3,000,000,000 字节（5 GB），冷却 1800 秒。基准样本最多允许比窗口起点早 120 秒，通知中写明实际跨度；没有合适历史样本时跳过。
- **状态保存**：重启不丢失去重记录。通知失败不会标记成功，后续运行仍满足条件时重试。只保留最近 7 天采样，窗口应大于 120 秒且小于 7 天减 120 秒。
- **接口失败**：输出错误并退出。网络请求最长等待 30 秒。

周期采用 `America/Los_Angeles` 时区，自动处理夏令时。累计值下降或周期变化时重建短时基线。周期日期已变化但尚未观察到累计值下降时，会暂缓比例告警，避免对尚未清零的上周期用量重复提醒。

如果长时间停机漏过了清零，恢复后的累计值又超过了旧值，脚本可能一直等待重置。确认服务商已经重置后，可解除等待（在脚本目录执行，替换服务 ID）：

```bash
flock ./123456.lock sqlite3 ./123456.sqlite3 "DELETE FROM flags WHERE name='await_reset';"
```

API 仅提供重置日，不提供精确清零时刻；重置日为 29～31 时，短月份的处理需要与服务商规则确认。轮询检测也受接口计数刷新频率影响。
