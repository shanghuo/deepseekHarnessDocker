# deepseekHarnessDocker
用于把deepseekHarness关在Docker中相对隔离运行，避免破坏宿主机。用作开发服务器

# 部署方式
在你的开发电脑/服务器上准备好docker，然后下载/克隆`docker-compose.yml`和`Dockerfile`，结合你电脑实际情况改写`docker-compose.yml`中参数并运行`docker compose up -d --build`即可启动并访问。

# 包含的
- deepseekHarness 一个智能体
- code-server 如果你电脑不在身边，可以远程手机上查看代码
- nginx 为你提供http和https访问支持，你还可以绑定域名/替换证书

# 访问方式
- <ip:port>/ 访问deepseekHarness
- <ip:port>/code/ 访问code-server

# 安全性
- 当前docker容器可以一定程度避免ai误删宿主电脑文件，但具体取决于给予ai的权限和技能
- 当前docker容器有效保证了ai安装的环境不会污染宿主机，有效避免导致宿主机环境变量等乱成一锅粥
- 此docker容器结合本地(我们团队的)网络的情况**开放所有网络风险行为**，因此若**直接部署到没经过专门处理的网络中的主机上，可能导致严重网络安全问题**请悉知

若你使用本项目发生任何问题，我们不承担任何责任！！！
