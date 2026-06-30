# CC Notify — 新手部署使用指南

本指南面向零基础用户，手把手教你配置 Claude Code 的企业微信通知功能。

---

## 这是什么？

CC Notify 是一个 Claude Code 技能。安装后，当 Claude Code 完成任务、需要你授权、或者等待你输入时，你的企业微信会收到一条私信通知。

**效果示例：**

```
[Claude Code] Task Done
Project: my-project
Reason: Task completed successfully
```

---

## 你需要准备什么

| 东西 | 说明 | 获取方式 |
|------|------|----------|
| 企业微信管理员账号 | 需要创建应用、设置权限 | [work.weixin.qq.com](https://work.weixin.qq.com) 注册 |
| 一台有公网 IP 的服务器 | 需要安装 Nginx | 腾讯云/阿里云轻量服务器即可，月费约 30 元 |
| 域名 | 用于 SSL 证书 | GoDaddy/Namesilo 等平台购买，约 10 元/年 |
| SSL 证书 | HTTPS 加密 | Let's Encrypt 免费或域名商提供 |

---

## 第一步：安装

**推荐方式：通过 marketplace 安装**（自动注册 hook，无需手动配置）：

```bash
# 在 Claude Code 中
/plugin marketplace add https://github.com/sk1227071686/cc-notify
/plugin install cc-notify@cc-notify
```

**手动安装**：

```bash
git clone https://github.com/sk1227071686/cc-notify.git
cd cc-notify
```

---

## 第二步：获取企业微信凭据

### 2.1 获取企业 ID（corpid）

1. 打开 [企业微信管理后台](https://work.weixin.qq.com)，管理员扫码登录
2. 点击左侧 **「我的企业」**
3. 滚动到底部，找到 **企业ID**，复制它（格式类似 `ww2907b2ede4535847`）

### 2.2 创建自建应用（获取 corpsecret 和 agentid）

1. 点击左侧 **「应用管理」**
2. 点击 **「创建应用」**
3. 填写应用名称（例如 `CC Notify`），上传一个 logo
4. 创建成功后，进入应用详情页
5. 找到 **AgentId**（类似 `1000002` 的数字）→ 复制
6. 找到 **Secret**，点击 **「查看」**（可能需要管理员扫码）→ 复制

### 2.3 获取目标用户的 UserID

1. 点击左侧 **「通讯录」**
2. 搜索目标用户，点击进入详情页
3. 找到 **UserID**（类似 `ShiKang` 的字符串）→ 复制

> ⚠️ 确保目标用户在应用的「可见范围」内（应用详情页→可见范围→添加用户）

---

## 第三步：配置公网服务器

> 你的公网服务器需要一个域名指向它，并且有 SSL 证书。下文假设域名为 `your-domain.com`。

### 3.1 安装依赖

```bash
# Nginx（通常已安装）
sudo apt-get install -y nginx

# Python 加密库（回调验证用）
pip3 install pycryptodome
```

### 3.2 创建回调验证服务

```bash
sudo mkdir -p /opt/wecom-callback
sudo vi /opt/wecom-callback/server.py
```

粘贴以下内容，**替换 TOKEN 和 ENCODING_AES_KEY**（先随便填，后面会改）：

```python
#!/usr/bin/env python3
import os, base64, struct
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from Crypto.Cipher import AES

TOKEN = "your_custom_token_here"
ENCODING_AES_KEY = "your_43_char_aes_key_here_________"
LISTEN_PORT = 8444

class WeComHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        params = parse_qs(urlparse(self.path).query)
        echostr = params.get("echostr", [""])[0]
        if not echostr:
            self.send_error(400)
            return
        try:
            aes_key = base64.b64decode(ENCODING_AES_KEY + "=")
            cipher = AES.new(aes_key, AES.MODE_CBC, aes_key[:16])
            decrypted = cipher.decrypt(base64.b64decode(echostr))
            pad = decrypted[-1]
            decrypted = decrypted[:-pad]
            msg_len = struct.unpack(">I", decrypted[16:20])[0]
            msg = decrypted[20:20 + msg_len].decode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))
        except Exception:
            self.send_error(500)

    def do_POST(self):
        cl = int(self.headers.get("Content-Length", 0))
        self.rfile.read(cl)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"success")

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), WeComHandler)
    print(f"[*] listening on :{LISTEN_PORT}")
    server.serve_forever()
```

### 3.3 启动回调服务

```bash
cd /opt/wecom-callback
python3 server.py &
```

检查是否在运行：

```bash
netstat -anp | grep 8444
# 应该看到 LISTEN 状态
```

### 3.4 配置 Nginx 反向代理

编辑 Nginx 配置：

```bash
sudo vi /etc/nginx/nginx.conf
```

在 `http {` 块内，添加以下 server 块（与其他 server 块同级）：

```nginx
server {
    listen 8443 ssl;
    server_name your-domain.com;

    ssl_certificate     /path/to/fullchain.cer;
    ssl_certificate_key /path/to/private.key;

    location /callback/ {
        proxy_pass http://127.0.0.1:8444;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        proxy_pass https://qyapi.weixin.qq.com;
        proxy_ssl_server_name on;
        proxy_set_header Host qyapi.weixin.qq.com;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

> ⚠️ 替换 `your-domain.com`、SSL 证书路径为你的实际值

测试并重载：

```bash
sudo nginx -t && sudo nginx -s reload
```

### 3.5 开放防火墙端口

```bash
sudo ufw allow 8443/tcp
sudo ufw allow 8444/tcp
```

如果是云服务器，还需要在**云控制台的安全组**中放行 8443 端口。

### 3.6 验证代理是否正常

从你的**本机**运行：

```bash
curl -sk https://your-domain.com:8443/cgi-bin/gettoken?corpid=你的corpid&corpsecret=你的corpsecret
```

如果返回 `{"errcode":0,"errmsg":"ok","access_token":"..."}`，说明代理正常 ✅

---

## 第四步：配置企业微信管理后台

### 4.1 设置 API 接收（解锁可信 IP 功能）

1. 打开 [企业微信管理后台](https://work.weixin.qq.com)
2. 进入 **「应用管理」** → 你的 CC Notify 应用
3. 找到 **「接收消息」** → 点击 **「设置 API 接收」**
4. 填写：
   - **URL**: `https://your-domain.com:8443/callback/你的agentid`
   - **Token**: 和 `server.py` 里的 TOKEN 一致
   - **EncodingAESKey**: 和 `server.py` 里的 ENCODING_AES_KEY 一致（点「随机生成」也可以，然后复制到 server.py）
   - **加解密方式**: 选 **「明文模式」**
5. 点击保存 — 如果弹出「openapi回调地址请求不通过」，检查：
   - 回调服务是否在运行（`netstat -anp | grep 8444`）
   - Nginx 是否正确配置并重载
   - 防火墙是否放行 8443
   - 域名是否正确解析到服务器 IP

### 4.2 设置企业可信 IP

1. 保存 API 接收成功后，回到应用详情页
2. 找到 **「企业可信IP」** 设置
3. 添加你的**公网服务器 IP**
4. 保存

---

## 第五步：运行安装向导

回到你的**本机**（运行 Claude Code 的那台机器）：

```bash
# 如果通过 marketplace 安装：
bash ~/.claude/plugins/cc-notify/skills/cc-notify/scripts/setup.sh

# 如果手动安装：
bash skills/cc-notify/scripts/setup.sh
```

按提示输入：

1. corpid → 第二步获取的
2. corpsecret → 第二步获取的
3. agentid → 第二步获取的
4. proxy URL → `https://your-domain.com:8443`
5. target userid → 第二步获取的

向导会自动测试连接并发一条测试消息。如果企业微信收到测试消息，说明配置成功！

---

## 第六步：配置 Claude Code 钩子

> **marketplace 用户可跳过此步。** 通过插件安装时，hook 已自动注册，无需手动配置。

仅在你**手动安装**（git clone）时才需要以下步骤：

### 6.1 复制钩子脚本

```bash
mkdir -p ~/.claude/hooks
cp hooks/notify.sh ~/.claude/hooks/notify.sh
chmod +x ~/.claude/hooks/notify.sh
```

### 6.2 编辑 settings.json

```bash
vi ~/.claude/settings.json
```

添加以下内容（与已有配置合并，不要覆盖）：

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify.sh"
          }
        ]
      }
    ]
  }
}
```

---

## 验证一切正常

在 Claude Code 中做任何操作（比如让它执行一个简单任务），完成后你的企业微信应该会收到通知。

如果没收到，检查：

| 问题 | 排查方法 |
|------|----------|
| 完全没通知 | 确认 `~/.claude/cc-notify/config.json` 存在且有效 |
| 收到 stderr 错误 | 在终端运行 `echo '{"hook_event_name":"Stop","message":"test","cwd":"/tmp"}' \| bash ~/.claude/hooks/notify.sh` |
| token 获取失败 | 检查代理 URL 是否可访问：`curl -sk https://your-domain.com:8443/` |
| IP 不允许 | 确认公网服务器 IP 已加入企业可信 IP |
| 消息发送成功但收不到 | 确认目标用户在应用可见范围内 |

---

## 常见问题

### Q: 我的 IP 是动态的怎么办？
A: 这就是为什么需要公网服务器做代理。你的本机→公网服务器→企业微信，只有公网服务器需要固定 IP。

### Q: 可以通知多个人吗？
A: 可以。修改 `config.json` 中的 `userid` 为多个，用 `|` 分隔，如 `"ZhangSan|LiSi"`。

### Q: 公网服务器重启后怎么办？
A: 需要重新启动回调服务和 Nginx。建议设置 systemd 服务或 crontab 自动启动：
```bash
# crontab -e 添加：
@reboot python3 /opt/wecom-callback/server.py &
```

### Q: 证书过期了怎么办？
A: 重新申请证书，替换 Nginx 配置中的证书路径，然后 `sudo nginx -s reload`。

### Q: 以后想改配置怎么办？
A: 重新运行 setup 向导，或直接编辑 `~/.claude/cc-notify/config.json`：
```bash
# marketplace 安装：
bash ~/.claude/plugins/cc-notify/skills/cc-notify/scripts/setup.sh
# 手动安装：
bash skills/cc-notify/scripts/setup.sh
```
