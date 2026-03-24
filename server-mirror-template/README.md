# Server mirror template (现网复刻版)

这份模板用于在新服务器上**尽量贴近当前线上结构**复刻一套 Cloudreve + Nginx 环境。

## 当前线上结构摘要

基于现网探测到的结构：

- 系统：CentOS 7
- Cloudreve 程序目录：`/usr/local/lighthouse/softwares/cloudreve`
- Cloudreve 监听：`127.0.0.1:5212`
- Cloudreve 由 systemd 托管
- Nginx 配置风格接近宝塔/灯塔目录结构
- Nginx 对外监听 `80`
- Nginx 反代到 `127.0.0.1:5212`
- aria2 运行在：`/usr/local/lighthouse/softwares/aria2`
- aria2 RPC 端口：`6800`

## 这份模板做什么

- 安装系统依赖
- 安装/部署 Cloudreve
- 创建 MariaDB 数据库与账号
- 安装 aria2（可选启用，默认开启）
- 写入更接近现网的 systemd 服务
- 写入 Nginx 反向代理配置
- 开放基础防火墙端口

## 不包含的内容

这份模板**不包含**：

- 代理/规避/穿透功能
- 现网证书私钥
- 现网数据库真实数据导入
- 现网上传文件目录同步

也就是说：

> 这是“现网结构复刻模板”，不是“整机全量镜像”。

## 推荐安装方式

```bash
git clone https://github.com/1660667086/server-mirror-template.git && cd server-mirror-template/server-mirror-template && cp env.example .env && nano .env && bash install.sh
```

## 关键变量

- `DOMAIN`：Cloudreve 对外域名
- `CLOUDREVE_VERSION`：Cloudreve 版本
- `CLOUDREVE_PORT`：Cloudreve 内部监听端口，默认 `5212`
- `CLOUDREVE_DB_NAME`：数据库名
- `CLOUDREVE_DB_USER`：数据库用户
- `CLOUDREVE_DB_PASS`：数据库密码
- `CLOUDREVE_INSTALL_DIR`：默认 `/usr/local/lighthouse/softwares/cloudreve`
- `ARIA2_INSTALL_DIR`：默认 `/usr/local/lighthouse/softwares/aria2`
- `ARIA2_RPC_PORT`：默认 `6800`
- `ARIA2_RPC_SECRET`：aria2 RPC 密钥
- `NGINX_CONF_DIR`：默认 `/etc/nginx/conf.d`

## 适用场景

- 新 Linux 服务器上快速复刻现网结构
- 不要求完全 1:1 还原旧机器所有数据
- 接受“服务结构尽量一致，内容数据另外迁移”

## 后续建议

如果你还想进一步接近现网，后面还需要单独处理：

- Cloudreve 数据库导出/导入
- uploads 目录迁移
- 域名解析
- HTTPS 证书
- aria2 下载目录挂载
