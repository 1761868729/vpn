# 自建梯子 服务器部署项目

服务器配置：**VLESS + WS + TLS（域名伪装）** 与 **Hysteria2** 双节点，附带订阅服务，方便在 v2rayN 等客户端一键导入。

## 组件架构

| 组件 | 说明 | 端口 |
|------|------|------|
| [3X-UI](https://github.com/MHSanaei/3x-ui) | 面板，管理 VLESS 入站 | 面板端口（安装时自定） |
| Xray | VLESS + WS + TLS 节点 | 8443/TCP |
| Hysteria2 | QUIC/UDP 协议节点 | 8443/UDP |
| sub-proxy.py | 订阅生成服务（供客户端导入） | 2095 |
| acme.sh | 自动签发/续期 Let's Encrypt 域名证书 | - |

## 前置要求

- 一台境外服务器（如腾讯云、阿里云），Ubuntu 20.04+ / Debian
- 一个已把 A 记录解析到服务器 IP 的**域名**（裸 IP 会被 GFW 直接拦截，必须用域名）
- **安全组放行端口**：`80`（签发证书用）、`443`、`8443`（TCP+UDP）、`2095`，以及 x-ui 面板端口

## 部署步骤

### 第 1 步：安装 3X-UI 面板并配置 VLESS 入站

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```

安装时按提示设置管理员账号/密码/面板端口。装完浏览器打开 `http://<服务器IP>:<面板端口>` 登录，**添加入站**，按下面填：

| 字段 | 值 |
|------|-----|
| 备注 | Tokyo-VLESS-WS-TLS |
| 协议 | vless |
| 端口 | 8443 |
| 传输 | ws |
| 安全 | tls |
| 路径 | /vless-ws |
| 证书 | 选「手动指定」→ 填 `/root/cert/<域名>/fullchain.pem` 和 `/root/cert/<域名>/privkey.pem` |
| 客户端 | 新建一个，记下 UUID，并填一个自定义「订阅 ID」（对应 install.sh 的 `SUB_ID`） |

### 第 2 步：安装 Hysteria2

```bash
bash <(curl -fsSL https://get.hy2.sh/)
```

### 第 3 步：运行一键脚本

先编辑 `install.sh` 顶部变量区（IP、域名、密码、UUID、订阅 ID），然后：

```bash
sudo bash install.sh
```

脚本会自动：装依赖 → 签发域名证书 → 部署 `sub-proxy.py` / `hysteria` 配置 / systemd 服务 → 放行防火墙 → 启动服务。

### 第 4 步：客户端导入订阅

v2rayN（Windows）→「订阅分组」→ 添加订阅：

```
http://<服务器IP>:2095/<订阅ID>
```

## 变量说明（每台服务器需修改）

| 变量 | 出现位置 | 说明 |
|------|---------|------|
| `SERVER_IP` / `REAL_IP` | install.sh、sub-proxy.py | 服务器公网 IP |
| `DOMAIN` | install.sh、sub-proxy.py、config.yaml | 绑定的域名（用于 SNI/Host 伪装） |
| `HY2_PASSWORD` | install.sh、sub-proxy.py、config.yaml | hysteria2 密码，两处需一致 |
| `VLESS_UUID` | install.sh、x-ui 面板 | VLESS 客户端 UUID，需与面板一致 |
| `SUB_ID` | install.sh、x-ui 面板 | 订阅 ID，需与面板一致 |

> 密码建议每台服务器重新生成：`openssl rand -base64 16`

## 常见问题

- **签发证书失败**：确认安全组已放行 80 端口（acme.sh standalone 走 80）。
- **VLESS 连不上（-1ms）**：确认节点 SNI/Host 是**域名**而非裸 IP。裸 IP 是导致被墙的直接原因。
- **证书续期**：acme.sh 已配置 90 天自动续期，续期后自动重启 x-ui 和 hysteria-server。
- **面板端口被墙**：面板只在部署时用，日常可不开安全组放行。

## 安全提示

- hysteria 密码、VLESS UUID、订阅 ID 均属敏感信息，请勿公开分享。
- 每台服务器建议使用独立密码和 UUID。
