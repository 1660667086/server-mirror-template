# 旧机 -> 新机迁移复制方案

目标：尽量少改配置，把旧服务器上的 Cloudreve / Nginx / aria2 结构迁到新服务器。

## 仓库直拉方案

如果你要的是“旧服务器把东西直接推到 Git 仓库里，新服务器再直接从仓库拉取”，请用这套流程。

适用场景：

- 备份体积不大，或者你接受 Git 仓库存放切片后的迁移包
- 你明确希望新服务器通过 `git clone` / `git pull` 获取备份

注意：

- 备份仓库必须是 private
- GitHub 单文件限制是 100MB，所以脚本会自动把迁移包切成多个 `part` 文件
- 如果 `uploads` 很大，这种方式会让仓库越来越重，不适合长期高频备份

### 旧服务器推送到备份仓库

```bash
export GITHUB_TOKEN='你的token'
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/publish-to-git-repo.sh) yourname/server-mirror-backup main
```

这一步会：

1. 调用 `export-old-server.sh` 导出迁移包
2. 自动按 90MB 分片
3. 把分片和清单直接 commit/push 到备份仓库

### 新服务器从备份仓库直接拉取并恢复

```bash
export GITHUB_TOKEN='你的token'
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/restore-from-git-repo.sh) yourname/server-mirror-backup main
```

这一步会：

1. `git clone` 备份仓库
2. 自动重组迁移包并校验 SHA256
3. 调用 `import-to-new-server.sh` 恢复目录、数据库和服务

## 纯 GitHub 中转方案

如果你不想让新服务器直连旧服务器，而是要让新服务器只从 GitHub 拉取，请用这套流程。

推荐做法：

1. 先创建一个单独的 private 备份仓库，例如 `yourname/server-mirror-backup`
2. 在旧服务器导出迁移包并上传到 GitHub Release
3. 在新服务器只从 GitHub Release 下载迁移包并恢复

为什么用 GitHub Release：

- 不需要新服务器 SSH 连接旧服务器
- 不会把大文件直接塞进 Git 历史
- 比直接 commit `tar.gz` 到仓库更稳

注意：

- 不要把迁移包上传到当前这个公开仓库
- 备份里包含数据库和配置，必须使用 private 仓库
- GitHub Release 仍然有单文件大小限制。如果迁移包明显超过 2GB，建议改用对象存储中转

### 旧服务器上传到 GitHub

先准备 `GITHUB_TOKEN`，需要对备份仓库有可读写权限。

```bash
export GITHUB_TOKEN='你的token'
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/publish-to-github-release.sh) yourname/server-mirror-backup server-mirror-latest
```

这一步会：

1. 调用 `export-old-server.sh` 导出迁移包
2. 自动创建或复用 `server-mirror-latest` 这个 Release
3. 把迁移包上传为 Release 资源

### 新服务器从 GitHub 拉取并恢复

```bash
export GITHUB_TOKEN='你的token'
bash <(curl -fsSL https://raw.githubusercontent.com/1660667086/server-mirror-template/main/migration-mirror/restore-from-github-release.sh) yourname/server-mirror-backup server-mirror-latest
```

这一步会：

1. 从 GitHub Release 下载迁移包
2. 调用 `import-to-new-server.sh` 自动恢复目录、数据库和服务

## 服务器直连迁移（旧流程）

如果你仍然允许新服务器直接连接旧服务器，可以继续使用原方案。

## 思路

不是重新按模板安装，而是：

1. 在旧服务器导出关键内容
2. 传到新服务器
3. 在新服务器恢复目录、数据库和服务
4. 最后只修少量差异项（域名、证书、IP、必要路径）

## 迁移内容

- Cloudreve 程序目录
- Cloudreve 配置
- Cloudreve uploads 目录
- aria2 配置
- Nginx 站点配置
- systemd 服务文件（Cloudreve）
- Cloudreve 数据库导出（如果数据库存在）

## 你当前线上探测到的关键路径

- Cloudreve：`/usr/local/lighthouse/softwares/cloudreve`
- aria2：`/usr/local/lighthouse/softwares/aria2`
- Cloudreve nginx vhost：`/www/server/panel/vhost/nginx/cloudreve.local.conf`
- Cloudreve nginx proxy：`/www/server/panel/vhost/nginx/proxy/cloudreve.local/e93050b29ab95e2d12d3a443f80456a8_cloudreve.local.conf`
- Cloudreve service：`/usr/lib/systemd/system/cloudreve.service`

## 使用顺序

### 旧服务器

```bash
bash export-old-server.sh
```

导出完成后，会在 `/root/server-mirror-export/` 下生成迁移包。

### 传输到新服务器

```bash
scp /root/server-mirror-export/server-mirror-export.tar.gz root@新服务器IP:/root/
scp import-to-new-server.sh root@新服务器IP:/root/
```

### 新服务器

```bash
bash import-to-new-server.sh /root/server-mirror-export.tar.gz
```

## 注意

- 如果新服务器原来就有 Nginx / MariaDB / Cloudreve，请先确认不会覆盖现有业务。
- 如果旧服务器数据库里没有 cloudreve 库，导入步骤会自动跳过 SQL 恢复。
- trojan 相关服务不在这次自动迁移范围里。
- HTTPS 证书、域名解析、外部面板逻辑需要你后续单独确认。
