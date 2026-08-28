#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  VPN 一键部署脚本
#  前置：已安装 3X-UI（并配好 VLESS 入站）、已安装 Hysteria2（见 README）
#  用法：编辑下方「变量区」，然后  sudo bash install.sh
# ============================================================

# ---------- 变量区（每台服务器需修改） ----------
SERVER_IP='43.165.175.139'
DOMAIN='asgo.click'
HY2_PASSWORD='ALKEjDYr5kjzDNoujdFuGw=='
VLESS_UUID='108282e9-439d-47ae-8fac-24bb88b5f5b2'   # 需与 x-ui 面板里 VLESS 客户端 UUID 一致
SUB_ID='3w4kmlma3ddx1fkx'                            # 需与 x-ui 面板里客户端「订阅 ID」一致
VLESS_PORT=8443
HY2_PORT=8443
SUB_PORT=2095
HY2_SNI='www.microsoft.com'
HY2_REMARK='Tokyo-Hysteria2'
CERT_DIR="/root/cert/$DOMAIN"
# ------------------------------------------------

echo "==> 检查 root"
[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行"; exit 1; }

echo "==> 检查 x-ui 已安装"
[ -x /usr/local/x-ui/x-ui ] || { echo "请先安装 3X-UI：bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"; exit 1; }

echo "==> [1/5] 安装依赖"
apt-get update -y
apt-get install -y curl wget python3 socat openssl

echo "==> [2/5] 安装 acme.sh 并签发域名证书"
curl -s https://get.acme.sh | sh
mkdir -p "$CERT_DIR"
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --key-file "$CERT_DIR/privkey.pem" \
  --reloadcmd 'systemctl restart x-ui hysteria-server'

echo "==> [3/5] 部署订阅服务 sub-proxy.py"
cat > /usr/local/bin/sub-proxy.py <<PYEOF
import http.server, socketserver, ssl, re, base64, json, sqlite3

REAL_IP      = '$SERVER_IP'
DOMAIN       = '$DOMAIN'
HY2_PASSWORD = '$HY2_PASSWORD'
HY2_PORT     = $HY2_PORT
HY2_SNI      = '$HY2_SNI'
HY2_REMARK   = '$HY2_REMARK'

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class Proxy(http.server.BaseHTTPRequestHandler):
    def build_subscription(self, sub_id):
        db = sqlite3.connect('/etc/x-ui/x-ui.db')
        cur = db.cursor()
        cur.execute('SELECT id FROM clients WHERE sub_id=? AND enable=1', (sub_id,))
        row = cur.fetchone()
        if not row: db.close(); return None, 'Not found'
        cid = row[0]
        cur.execute('SELECT i.port, i.protocol, i.settings, i.stream_settings, i.remark FROM inbounds i JOIN client_inbounds ci ON ci.inbound_id=i.id WHERE ci.client_id=? AND i.enable=1', (cid,))
        inbounds = cur.fetchall()
        db.close()
        urls = []
        for port, proto, settings_json, stream_json, remark in inbounds:
            s = json.loads(settings_json)
            st = json.loads(stream_json)
            uid = s['clients'][0]['id']
            net = st.get('network','tcp')
            if net == 'ws':
                path = st.get('wsSettings',{}).get('path','/')
                urls.append(f'vless://{uid}@{REAL_IP}:{port}?encryption=none&security=tls&sni={DOMAIN}&fp=chrome&type=ws&path={path}&host={DOMAIN}#{remark}')
        urls.append(f'hysteria2://{HY2_PASSWORD}@{REAL_IP}:{HY2_PORT}?insecure=1&sni={HY2_SNI}&alpn=h3#{HY2_REMARK}')
        return '\n'.join(urls)+'\n', None

    def do_GET(self):
        try:
            parts = self.path.rstrip('/').split('/')
            sub_id = parts[-1] if parts else ''
            if not sub_id or sub_id == 'Japan':
                self.send_response(400); self.end_headers(); return
            data, err = self.build_subscription(sub_id)
            if err:
                self.send_response(404); self.end_headers(); self.wfile.write(err.encode()); return
            encoded = base64.b64encode(data.encode()).decode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(encoded)))
            self.send_header('Subscription-Userinfo', '')
            self.end_headers()
            self.wfile.write(encoded.encode())
        except Exception as e:
            self.send_response(502); self.end_headers(); self.wfile.write(str(e).encode())
    def log_message(self, f, *a): pass

server = ThreadingHTTPServer(('0.0.0.0', $SUB_PORT), Proxy)
server.serve_forever()
PYEOF

echo "==> [4/5] 部署 hysteria 配置 + systemd 服务"
mkdir -p /etc/hysteria
cat > /etc/hysteria/config.yaml <<YAMLEOF
listen: :$HY2_PORT

tls:
  cert: $CERT_DIR/fullchain.pem
  key: $CERT_DIR/privkey.pem

auth:
  type: password
  password: $HY2_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$HY2_SNI
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s
  keepAlivePeriod: 5s
  disablePathMTUDiscovery: false

bandwidth:
  up: 200 mbps
  down: 200 mbps

ignoreClientBandwidth: false
speedTest: true

sniff:
  enable: true
  timeout: 2s

udpIdleTimeout: 60s

resolver:
  type: udp
  tcp:
    addr: 8.8.8.8:53
    timeout: 4s
  udp:
    addr: 8.8.8.8:53
    timeout: 4s
YAMLEOF

cp "$(dirname "$0")/systemd/sub-proxy.service" /etc/systemd/system/
cp "$(dirname "$0")/systemd/hysteria-server.service" /etc/systemd/system/
systemctl daemon-reload

echo "==> [5/5] 启动服务 + 防火墙"
systemctl enable --now sub-proxy hysteria-server
systemctl restart x-ui

if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow "$VLESS_PORT"/tcp
  ufw allow "$HY2_PORT"/udp
  ufw allow "$SUB_PORT"/tcp
fi

echo ""
echo "================ 部署完成 ================"
echo "订阅地址:  http://$SERVER_IP:$SUB_PORT/$SUB_ID"
echo "VLESS:     $VLESS_PORT/tcp   Hysteria2: $HY2_PORT/udp"
echo "请在 v2rayN 中添加订阅并更新测试。"
