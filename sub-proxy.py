import http.server, socketserver, ssl, re, base64, json, sqlite3

# ============================================================
#  每台服务器部署时，只需修改下面几个变量
# ============================================================
REAL_IP      = '43.165.175.139'                          # 服务器公网 IP
DOMAIN       = 'asgo.click'                              # 绑定域名（用于 VLESS 的 SNI/Host 伪装）
HY2_PASSWORD = 'ALKEjDYr5kjzDNoujdFuGw=='                 # hysteria2 密码，需与 hysteria/config.yaml 一致
HY2_PORT     = 8443                                      # hysteria2 监听端口（UDP）
HY2_SNI      = 'www.microsoft.com'                       # hysteria2 伪装 SNI
HY2_REMARK   = 'Tokyo-Hysteria2'                         # hysteria2 节点备注
SUB_PORT     = 2095                                      # 本订阅服务监听端口
# ============================================================

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

server = ThreadingHTTPServer(('0.0.0.0', SUB_PORT), Proxy)
server.serve_forever()
