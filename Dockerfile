# DeepSeek Harness (dsh) —— Debian + 内置 nginx 反代（HTTP + HTTPS）+ code-server Web IDE
# 路由：根路径 / = dsh；/code/ = code-server（子路径，内部默认端口 127.0.0.1:8080，不占对外开发端口范围）
# 任意位置可访问：nginx 把 Host 归一化为 127.0.0.1 并去掉 Origin/sec-fetch-site，
# dsh 的 /api 信任围栏对任何来源放行（安全交由路由器/网络层）。
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_MAJOR=22 \
    DSH_HOME=/dsh \
    HOME=/root

# 构建期代理（docker build 的 RUN 里 npm/curl/git 下载走代理；运行时代理由 compose 的 environment 注入）
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=$HTTP_PROXY \
    HTTPS_PROXY=$HTTPS_PROXY \
    ALL_PROXY=$ALL_PROXY \
    NO_PROXY=$NO_PROXY \
    http_proxy=$HTTP_PROXY \
    https_proxy=$HTTPS_PROXY \
    all_proxy=$ALL_PROXY \
    no_proxy=$NO_PROXY

# ===== 环境相关变量（值在 docker-compose.yml 的 build.args 中集中配置；无默认值，必须显式传入）=====
ARG HOST_IP
ARG PROXY_URL
ARG DEV_PORT_RANGE

# 基础工具 + Node 22 + nginx + openssl
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git python3 make g++ procps openssl nginx \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# pnpm + dsh 本体
# dsh 不锁版本：跟随最新（官方更新频繁，避免手动改版本号）
# 回退/锁定：改回 @deepseek-ai/dsh@<版本> 即可；重建前建议先 docker tag dsh:latest dsh:backup-<版本>
RUN npm install -g pnpm@11 @deepseek-ai/dsh@latest \
 && npm cache clean --force

# dsh webserver 监听所有网卡（CLI 故意拒绝 --host 0.0.0.0，这里用配置层覆盖）
RUN mkdir -p "$DSH_HOME" /workspace \
 && printf '%s\n' \
    '- id: webserver' \
    '  config:' \
    '    host: 0.0.0.0' \
    '    port: 3080' \
    > /etc/dsh-webserver.cordis.yml

# 注入容器全局记忆模板（/etc/dsh/MEMORY.md）—— 端口规则/代理/Bun 规范/网络安全约定，供所有会话阅读
# /dsh 是持久化挂载卷，构建期写入会被宿主空目录遮蔽；模板放 /etc/dsh，boot.sh 首次启动时复制到 /dsh/MEMORY.md
RUN mkdir -p /etc/dsh \
 && printf '%s\n' \
    '# 容器全局记忆 (Container Global Memory)' \
    '' \
    '> 供未来所有使用本容器的会话/智能体阅读。' \
    '' \
    '## ⚠️ 端口规则（仅限开发测试）' \
    '- **开发/测试阶段（在本容器内）：需要对外暴露端口的项目，只能用 '"${DEV_PORT_RANGE}"' 范围的端口，外部才可见**' \
    '- **生产阶段：无此限制，端口按实际需求指定**' \
    '- 端口必须做成显式可配置项（如环境变量/配置），禁止硬编码死端口' \
    '- 启动服务后先本机 curl 验证，再确认外部可访问' \
    '' \
    '## 代理（仅开发阶段）' \
    '- **开发阶段出网经 HTTP 代理 '"${PROXY_URL}"'**' \
    '  （HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 已设；NO_PROXY=localhost,127.0.0.1,::1；NODE_USE_ENV_PROXY=1）' \
    '- **生产环境无此代理** → 代理只通过环境变量注入，**绝不写进代码/配置文件**（代码中不得出现代理地址）' \
    '' \
    '## 网络安全约定' \
    '- **任意 IP/域名访问到当前容器内都是已经绝对保证可信的**，身份鉴权等外部都已做好，**这个容器内不需要考虑任何开发阶段网络安全问题**' \
    '- **但开发中必须正常考虑生产环境网络安全问题**（生产需恢复鉴权、禁止免密暴露公网等）' \
    > /etc/dsh/MEMORY.md

# 自签名证书（HTTPS，SAN 覆盖 HOST_IP 与 localhost；首次访问点“继续”即可）
RUN mkdir -p /etc/nginx/certs \
 && openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/nginx/certs/dsh.key \
      -out /etc/nginx/certs/dsh.crt \
      -subj "/CN=${HOST_IP}" \
      -addext "subjectAltName=IP:${HOST_IP},DNS:localhost,IP:127.0.0.1" \
      -addext "extendedKeyUsage=serverAuth"

# nginx：80 HTTP + 443 HTTPS —— 根路径反代 dsh(3080)；/code/ 子路径反代 code-server(默认 127.0.0.1:8080)
# dsh 前端资源为绝对路径且无 base-path 配置，无法挂子路径，只能占根路径
# absolute_redirect off：保留相对重定向，避免 code-server 302 被 nginx 拼成容器内部端口
# Host 用 $http_host（含端口）而非 $host（去端口），否则 code-server 的 WS Origin 校验不匹配→403
RUN printf '%s\n' \
    'server {' \
    '    listen 80;' \
    '    absolute_redirect off;' \
    '    location / {' \
    '        proxy_pass http://127.0.0.1:3080;' \
    '        proxy_http_version 1.1;' \
    '        proxy_set_header Host 127.0.0.1;' \
    '        proxy_set_header Origin "";' \
    '        proxy_set_header sec-fetch-site "";' \
    '        proxy_set_header Upgrade $http_upgrade;' \
    '        proxy_set_header Connection "upgrade";' \
    '        proxy_read_timeout 3600s;' \
    '        proxy_send_timeout 3600s;' \
    '    }' \
    '    location = /code { return 301 /code/; }' \
    '    location /code/ {' \
    '        proxy_pass http://127.0.0.1:8080/vscode/;' \
    '        proxy_http_version 1.1;' \
    '        proxy_set_header Upgrade $http_upgrade;' \
    '        proxy_set_header Connection "upgrade";' \
    '        proxy_set_header Host $http_host;' \
    '        proxy_set_header X-Forwarded-Host $http_host;' \
    '        proxy_set_header X-Forwarded-Proto $scheme;' \
    '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
    '        proxy_redirect ~^\./\.\./vscode(/?.*)$ /code$1;' \
    '        proxy_read_timeout 3600s;' \
    '        proxy_send_timeout 3600s;' \
    '    }' \
    '    location /_static/ {' \
    '        proxy_pass http://127.0.0.1:8080;' \
    '        proxy_set_header Host $http_host;' \
    '        proxy_set_header X-Forwarded-Host $http_host;' \
    '        proxy_set_header X-Forwarded-Proto $scheme;' \
    '    }' \
    '}' \
    'server {' \
    '    listen 443 ssl;' \
    '    absolute_redirect off;' \
    '    ssl_certificate     /etc/nginx/certs/dsh.crt;' \
    '    ssl_certificate_key /etc/nginx/certs/dsh.key;' \
    '    location / {' \
    '        proxy_pass http://127.0.0.1:3080;' \
    '        proxy_http_version 1.1;' \
    '        proxy_set_header Host 127.0.0.1;' \
    '        proxy_set_header Origin "";' \
    '        proxy_set_header sec-fetch-site "";' \
    '        proxy_set_header Upgrade $http_upgrade;' \
    '        proxy_set_header Connection "upgrade";' \
    '        proxy_read_timeout 3600s;' \
    '        proxy_send_timeout 3600s;' \
    '    }' \
    '    location = /code { return 301 /code/; }' \
    '    location /code/ {' \
    '        proxy_pass http://127.0.0.1:8080/vscode/;' \
    '        proxy_http_version 1.1;' \
    '        proxy_set_header Upgrade $http_upgrade;' \
    '        proxy_set_header Connection "upgrade";' \
    '        proxy_set_header Host $http_host;' \
    '        proxy_set_header X-Forwarded-Host $http_host;' \
    '        proxy_set_header X-Forwarded-Proto $scheme;' \
    '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
    '        proxy_redirect ~^\./\.\./vscode(/?.*)$ /code$1;' \
    '        proxy_read_timeout 3600s;' \
    '        proxy_send_timeout 3600s;' \
    '    }' \
    '    location /_static/ {' \
    '        proxy_pass http://127.0.0.1:8080;' \
    '        proxy_set_header Host $http_host;' \
    '        proxy_set_header X-Forwarded-Host $http_host;' \
    '        proxy_set_header X-Forwarded-Proto $scheme;' \
    '    }' \
    '}' \
    > /etc/nginx/conf.d/dsh.conf \
 && rm -f /etc/nginx/sites-enabled/default

# code-server（浏览器版 VS Code Web IDE）—— 不指定 bind-addr，用默认 127.0.0.1:8080（内部端口）
# 由 nginx（HTTP 80 / HTTPS 443）按 /code/ 子路径反代对外提供；不占用对外开发端口范围
# 生产部署时：加 bind-addr 换正式端口，且必须恢复鉴权
ARG CODE_SERVER_VERSION=4.132.0
RUN mkdir -p /opt \
 && curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-amd64.tar.gz" \
      -o /tmp/code-server.tar.gz \
 && tar -xzf /tmp/code-server.tar.gz -C /opt \
 && mv "/opt/code-server-${CODE_SERVER_VERSION}-linux-amd64" /opt/code-server \
 && rm -f /tmp/code-server.tar.gz \
 && ln -sf /opt/code-server/bin/code-server /usr/local/bin/code-server \
 && mkdir -p /root/.config/code-server \
 && printf '%s\n' \
    '# 开发测试阶段：免密码登录（前提：当前网络绝对可信，VLAN+外部鉴权已做好，容器内无需考虑开发阶段网络安全）' \
    '# ⚠️ 生产部署必须改回 auth: password（或启用 OAuth/反向代理），禁止免密暴露公网 —— code-server 终端=容器 root shell' \
    '# 不指定 bind-addr → 默认 127.0.0.1:8080（内部端口，不占对外开发端口范围），由 nginx 按 /code/ 子路径反代' \
    'auth: none' \
    'cert: false' \
    'disable-telemetry: true' \
    'disable-update-check: true' \
    > /root/.config/code-server/config.yaml \
 && code-server --install-extension oven.bun-vscode

# code-server 启动脚本（根目录 /workspace，配置走 /root/.config/code-server/config.yaml）
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# code-server 启动脚本 — 默认端口 127.0.0.1:8080（内部，不占对外开发端口范围），对外由 nginx 按 /code/ 子路径反代' \
    '# 生产换端口：在 /root/.config/code-server/config.yaml 加 bind-addr（生产无端口范围限制）' \
    'mkdir -p /root/.local/share/code-server /root/.cache/code-server' \
    'export HOME=/root' \
    'exec /usr/local/bin/code-server /workspace --config /root/.config/code-server/config.yaml "$@"' \
    > /opt/code-server/start.sh

# 容器启动入口：确保证书/全局记忆存在 → nginx → 证书热更新 watcher → code-server → dsh 前台（PID 1）
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# 容器启动入口：确保证书/全局记忆存在 → 启动 nginx → 证书热更新 watcher → code-server → dsh 前台（PID 1）' \
    '' \
    'CERT_DIR=/etc/nginx/certs' \
    '' \
    '# 首次启动（宿主证书目录为空）时生成自签名证书；宿主可随时覆盖，watcher 检测变化后自动重载 nginx' \
    'if [ ! -f "$CERT_DIR/dsh.crt" ] || [ ! -f "$CERT_DIR/dsh.key" ]; then' \
    '  mkdir -p "$CERT_DIR"' \
    '  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$CERT_DIR/dsh.key" -out "$CERT_DIR/dsh.crt" -subj "/CN='"${HOST_IP}"'" -addext "subjectAltName=IP:'"${HOST_IP}"',DNS:localhost,IP:127.0.0.1" -addext "extendedKeyUsage=serverAuth"' \
    'fi' \
    '' \
    '# 首次启动时注入容器全局记忆（/dsh 为持久化卷，宿主为空时从镜像模板 /etc/dsh/MEMORY.md 复制）' \
    'mkdir -p /dsh' \
    '[ -f /dsh/MEMORY.md ] || cp /etc/dsh/MEMORY.md /dsh/MEMORY.md' \
    '' \
    'nginx' \
    '' \
    '# 证书热更新：宿主覆盖证书后，检测到变化即 nginx -s reload（每分钟轮询一次，兼容宿主文件共享不触发 inotify 的情况）' \
    '(' \
    '  prev_hash=""' \
    '  while true; do' \
    '    hash=$(cat "$CERT_DIR/dsh.crt" "$CERT_DIR/dsh.key" 2>/dev/null | md5sum)' \
    '    hash=${hash%% *}' \
    '    if [ -n "$hash" ] && [ "$hash" != "$prev_hash" ]; then' \
    '      [ -n "$prev_hash" ] && nginx -s reload 2>/dev/null' \
    '      prev_hash="$hash"' \
    '    fi' \
    '    sleep 60' \
    '  done' \
    ') &' \
    '' \
    '/opt/code-server/start.sh >> /var/log/code-server.log 2>&1 &' \
    '' \
    '# dsh 凭据处理：仅当 $DSH_HOME/.credentials.yaml 存在时才处理（文件权限要求 0600，' \
    '# Windows 宿主 bind mount 无法保持，会导致 dsh 启动失败）。提取其中的 DEEPSEEK_API_KEY，' \
    '# 删除文件；dsh 启动就绪后通过 HTTP 请求 /api/credentials.set 把 key 提交回去。' \
    'CREDS_FILE="${DSH_HOME:-/dsh}/.credentials.yaml"' \
    'DSH_CRED_KEY=""' \
    'if [ -f "$CREDS_FILE" ]; then' \
    '  DSH_CRED_KEY=$(sed -n "s/^[[:space:]]*DEEPSEEK_API_KEY:[[:space:]]*//p" "$CREDS_FILE" | head -n 1 | tr -d "\r")' \
    '  case "$DSH_CRED_KEY" in' \
    '    \"*) DSH_CRED_KEY=${DSH_CRED_KEY#\"}; DSH_CRED_KEY=${DSH_CRED_KEY%\"} ;;' \
    '  esac' \
    '  rm -f "$CREDS_FILE"' \
    'fi' \
    '' \
    '# 提取到 key 时：后台一次性 helper 轮询等待 dsh /api 就绪，再以 HTTP 请求提交凭据' \
    '# （rpcId 为回显令牌，UUID 即可）；dsh 保持前台 exec，启动与信号行为与原逻辑完全一致' \
    'if [ -n "$DSH_CRED_KEY" ]; then' \
    '  (' \
    '    rpc_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)' \
    '    [ -n "$rpc_id" ] || rpc_id="boot-credential-1"' \
    '    body="{\"type\":\"client-request\",\"rpcId\":\"$rpc_id\",\"method\":\"credentials.set\",\"payload\":{\"ref\":\"DEEPSEEK_API_KEY\",\"value\":\"$DSH_CRED_KEY\"}}"' \
    '    tries=0' \
    '    while [ "$tries" -lt 60 ]; do' \
    '      resp=$(curl -sS -m 2 -X POST "http://127.0.0.1:3080/api/credentials.set" -H "content-type: application/json" --data "$body" 2>/dev/null)' \
    '      echo "$resp" | grep -qE "\"ok\"[: ]*true" && exit 0' \
    '      tries=$((tries + 1))' \
    '      sleep 1' \
    '    done' \
    '  ) &' \
    'fi' \
    'exec dsh web --patch /etc/dsh-webserver.cordis.yml' \
    > /usr/local/bin/boot.sh
RUN chmod +x /opt/code-server/start.sh /usr/local/bin/boot.sh

WORKDIR /workspace
# 对外入口只有 nginx 的 80/443；dsh(3080)、code-server(8080) 均为容器内反代目标，不对外暴露
# 开发阶段对外端口范围见 docker-compose.yml 的 ports 预留映射
EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/boot.sh"]
