# 旧机 → 新机迁移复刻方案

目标：尽量少改配置，把旧服务器上的 Cloudreve / Nginx / aria2 结构迁到新服务器。

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
