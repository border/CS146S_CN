# 上游同步脚本

把原仓库 <https://github.com/Lucaswang81/CS146S_CN.git>（远端名 `upstream`）合并到本地 `main`。不会推送到 `origin`。

## 每天 09:30 自动同步（macOS）

```bash
scripts/install-daily-check.sh              # 安装定时任务
scripts/install-daily-check.sh --uninstall  # 移除
launchctl kickstart gui/$(id -u)/com.cs146s-cn.sync-upstream   # 立即试跑一次
```

| 情况 | 行为 | 通知 |
|------|------|------|
| 上游没有新提交 | 什么都不做 | 无 |
| 有新提交，能干净合并 | 自动合并（能快进就快进，否则生成 merge commit） | 已合并 N 个提交 |
| 有冲突 | 撤销本次合并，仓库保持原样 | 提示手动处理 |
| 工作区有未提交改动 / 不在 `main` | 跳过 | 说明原因 |
| fetch 失败等错误 | 跳过 | 同步失败 |

Mac 在 09:30 处于睡眠时，唤醒后会补跑。日志：`~/Library/Logs/cs146s-sync.log`。

## 手动同步

```bash
scripts/sync-upstream.sh            # 合并 upstream/main 到 main；有冲突会停在冲突状态
scripts/sync-upstream.sh --help
```

退出码：0 已是最新或已合并，1 出错，2 跳过，3 冲突。

## 测试

```bash
/bin/bash scripts/tests/test-sync-upstream.sh
```
