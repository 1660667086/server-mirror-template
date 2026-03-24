# Server mirror template

用于在新服务器上快速拉起一套**正常网站/云盘骨架**：

- 基础依赖
- Nginx
- MariaDB
- Cloudreve
- systemd 服务
- 基础防火墙规则

## 这份模板做什么

它基于你当前服务器的可见结构整理，但只保留**正常网站/云盘部署骨架**，不包含任何代理、规避、穿透相关内容。

当前骨架默认采用：

- Cloudreve 监听 `127.0.0.1:5212`
- Nginx 对外监听 `80`
- Nginx 反代到 Cloudreve
- systemd 托管 Cloudreve

## 快速使用

```bash
curl -fsSL <RAW_BASE_URL>/install.sh | bash
```

如果你是手动上传目录：

```bash
cp env.example .env
nano .env
bash init-server.sh
bash deploy-cloudreve.sh
bash deploy-nginx.sh
```

## 推荐目录

建议仓库结构：

- `install.sh`
- `init-server.sh`
- `deploy-cloudreve.sh`
- `deploy-nginx.sh`
- `env.example`

## .env 变量说明

- `DOMAIN`：站点域名
- `CLOUDREVE_VERSION`：Cloudreve 版本
- `CLOUDREVE_PORT`：Cloudreve 内部监听端口
- `CLOUDREVE_DB_NAME`：数据库名
- `CLOUDREVE_DB_USER`：数据库用户
- `CLOUDREVE_DB_PASS`：数据库密码
- `CLOUDREVE_INSTALL_DIR`：Cloudreve 安装目录
- `WEB_ROOT`：Nginx 站点根目录

## 注意

- 这份模板不会配置 HTTPS 证书，你可以在部署完成后自行接入。
- 防火墙只开放 `22/tcp`、`80/tcp`、`443/tcp`。
- 如果你使用宝塔或其他面板，需要按你自己的环境调整 Nginx 配置目录。
