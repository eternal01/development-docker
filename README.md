# development-docker

基于 Docker Compose 的可迁移、多语言开发环境。宿主机 `~/codes` 映射到容器 `/workspace`，workspace 内使用 `developer` 作为开发用户。

项目提供一个包含 SSH 服务的 workspace 容器，并按需提供数据库、缓存、消息队列、注册中心、监控、CI 和网关等基础设施服务。开发工具链留在容器内，宿主机只需要 Docker、IDE 和 AI 应用。

## 快速开始

```bash
cp .env.example .env
mkdir -p ~/codes
docker compose build workspace
docker compose up -d workspace
```

进入开发终端：

```bash
docker compose exec -u developer workspace zsh
```

或使用项目命令桥：

```bash
./scripts/dev up
./scripts/dev shell
./scripts/dev exec go version
./scripts/dev doctor
```

查看状态和日志：

```bash
docker compose ps
docker compose logs -f workspace
```

## 项目结构

```text
docker-compose.yml              workspace、网络和缓存卷
compose/                        可选基础设施 Compose 模块
workspaces/workspace.Dockerfile workspace 镜像
workspaces/docker-entrypoint.sh 容器入口和 SSHD 启动
workspaces/dotfiles/             shell 配置
workspaces/scripts/              语言探测和项目初始化
scripts/dev                      日常容器命令桥
scripts/dev-up.sh                语言环境预设启动
scripts/build-workspace.sh       workspace 多架构构建
```

## 用户与 SSH

workspace 容器以 root 启动入口，用于初始化权限和 SSHD；主开发进程和 SSH 登录会自动使用 `developer` 用户。

SSH 默认仅绑定宿主机回环地址的 `2222` 端口；其他基础设施服务也默认只在本机可访问。若确需局域网访问，在 `.env` 中将 `WORKSPACE_BIND_IP` 设置为可信网卡地址；不建议直接暴露到公网。

SSH 默认监听宿主机 `2222` 端口：

```bash
ssh developer@localhost -p 2222
```

公钥放入容器：

```bash
docker compose exec -u root workspace mkdir -p /home/developer/.ssh
docker compose exec -u root workspace sh -c \
  'cat >> /home/developer/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub
docker compose exec -u root workspace sh -c \
  'chown -R developer:developer /home/developer/.ssh && chmod 700 /home/developer/.ssh && chmod 600 /home/developer/.ssh/authorized_keys'
```

关闭 SSH：

```env
WORKSPACE_SSH_ENABLED=false
```

修改后重建容器：

```bash
docker compose up -d --force-recreate workspace
```

容器管理命令使用 root：

```bash
docker compose exec -u root workspace bash
```

日常开发命令使用 developer：

```bash
docker compose exec -u developer workspace zsh
```

## IDE 和 AI 工具

项目不依赖某个特定 IDE。所有 IDE 都可以通过 SSH、Docker Compose 或容器终端使用同一套环境。

推荐连接参数：

```text
Host: localhost
Port: 2222
User: developer
Workspace: /workspace
```

VS Code 用户可以使用项目内的 `.devcontainer/devcontainer.json` 重新打开容器；也可以直接使用 SSH。JetBrains、Cursor、Windsurf 等工具可以使用 SSH 远程开发或 Docker 解释器。

宿主机 GUI AI 应用直接打开 `~/codes/project`。项目命令通过容器执行：

```bash
./scripts/dev exec go test ./...
./scripts/dev exec cargo test
./scripts/dev exec composer install
./scripts/dev exec npm test
```

这样代码由宿主机编辑，SDK、编译器和依赖由 workspace 提供。

## 多语言环境

语言版本由 mise 管理：

```bash
docker compose exec -u developer workspace zsh
cd /workspace/my-project
init-project
mise install
mise ls
```

支持自动识别：

| 项目文件 | 工具 | 默认版本来源 |
|---|---|---|
| `package.json` | Node.js | 可安全解析的 `engines.node`；未声明时使用 `22` |
| `go.mod` | Go | `go` 指令；未声明时使用 `1.23` |
| `Cargo.toml` | Rust | `rust-version`；未声明时使用 `stable` |
| `composer.json` | PHP | 可安全解析的 `require.php`；未声明时使用 `8.3` |
| `pyproject.toml` | Python | 可安全解析的 `requires-python`；未声明时使用 `3.12` |
| `requirements.txt` | Python | 使用 `3.12` |

手动指定版本：

```bash
mise use go@1.23
mise use rust@stable
mise use php@8.3
mise install
```

项目探测仅对可安全判断的版本约束生成配置；复杂或仅有上限的约束会提示手动选择，不会猜一个可能不兼容的版本。`WORKSPACE_PREINSTALL_LANGUAGES` 则会在镜像构建时安装并写入 mise 全局配置，使预装工具在未提供项目级版本配置时也可用。

镜像构建阶段预装语言：

```env
WORKSPACE_PREINSTALL_LANGUAGES="go@1.23 rust@stable php@8.3 node@22 python@3.12"
```

## Homebrew

系统底层软件通过 Debian 安装，通用 CLI 工具通过 Homebrew 安装，语言运行时通过 mise 管理。镜像构建使用 BuildKit 缓存复用 mise/Homebrew 下载；mise 二进制按发布页 SHA-256 校验，Homebrew 引导脚本固定到不可变提交（Homebrew 后续公式仍按上游更新）。

修改默认工具：

```env
WORKSPACE_BREW_PACKAGES="gh jq yq ripgrep fzf tree tmux fd neovim starship"
```

重新构建：

```bash
docker compose build workspace
docker compose up -d workspace
```

终端使用原生 Zsh 补全，Starship 可选作为提示符，fzf 提供历史与模糊搜索快捷键；缺少可选工具时使用基础提示符继续启动。

容器内安装临时工具：

```bash
docker compose exec -u developer workspace brew install httpie
```

需要长期复现的工具应加入 `WORKSPACE_BREW_PACKAGES` 后重新构建镜像。GitHub CLI（`gh`）默认安装。

### GitHub HTTPS 认证

首次使用 GitHub HTTPS 时，在 workspace 内登录并配置 Git credential helper：

```bash
docker compose exec -u developer workspace gh auth login --hostname github.com --git-protocol https --web
docker compose exec -u developer workspace gh auth setup-git
```

`gh` 登录状态存储在独立的 `workspace-gh-config` Docker named volume 中，容器重建后仍保留；全局 Git 配置不挂载，容器重建后需要再次运行 `gh auth setup-git`。登录信息是敏感数据，Docker volume **不提供加密**；有 Docker daemon / volume 访问权限的用户可能读取它。注销：

```bash
docker compose exec -u developer workspace gh auth logout --hostname github.com
```

GitHub HTTPS credential helper 只会用于 HTTPS remote；SSH remote 不会自动转换。需要时，在目标仓库中显式改为 HTTPS URL（令牌不要写入 remote）：

```bash
git remote set-url origin https://github.com/OWNER/REPOSITORY.git
```

## 宿主机代理

在 `.env` 设置宿主机代理：

```env
HOST_PROXY_URL=http://host.docker.internal:7897
HTTP_PROXY=${HOST_PROXY_URL}
HTTPS_PROXY=${HOST_PROXY_URL}
```

代理会用于镜像构建和容器运行阶段的 apt、mise、Homebrew、Go、Rust、PHP 等下载。

如果代理只监听宿主机回环地址：

```env
HOST_PROXY_URL=http://127.0.0.1:7897
WORKSPACE_BUILD_NETWORK=host
```

没有代理时将 `HOST_PROXY_URL` 留空。

## Debian 软件源

默认使用官方源：

```env
DEBIAN_MIRROR=deb.debian.org
DEBIAN_SECURITY_MIRROR=security.debian.org
```

也可以切换镜像：

```env
DEBIAN_MIRROR=mirrors.aliyun.com
DEBIAN_SECURITY_MIRROR=mirrors.aliyun.com
```

构建日志：

```bash
docker compose --progress=plain build workspace
```

## 多架构构建

普通 Compose 构建当前 Docker 主机架构：

```bash
docker compose build workspace
```

构建单一指定架构并加载到本地：

```bash
PLATFORMS=linux/arm64 make build-workspace-multiarch
```

构建并推送 amd64/arm64 多架构镜像：

```bash
docker buildx create --name development-docker-builder --use
docker buildx inspect --bootstrap
PUSH=1 WORKSPACE_IMAGE=registry.example.com/team/workspace:latest \
  PLATFORMS=linux/amd64,linux/arm64 make build-workspace-multiarch
```

多架构构建必须推送到镜像仓库，不能通过普通 `--load` 加载 manifest list。Compose workspace 使用 `.env` 中的 `WORKSPACE_IMAGE` 作为镜像标签；在另一台机器使用已推送的镜像时，先拉取并禁止本地构建：

```bash
docker compose pull workspace
docker compose up -d --no-build workspace
```

## 基础设施服务

默认启动保持精简：`docker compose up -d workspace`、`./scripts/dev up` 和 `make up` 只启动 workspace。Compose 文件中定义了可选服务，不代表这些服务会随默认命令启动；只有显式选择 profile 或服务时才会启动。

按需使用 Compose profile：

```bash
docker compose --profile mysql up -d
docker compose --profile postgres up -d
docker compose --profile cache up -d
docker compose --profile mq up -d
docker compose --profile registry up -d
docker compose --profile storage up -d
docker compose --profile observability up -d
docker compose --profile ci up -d
docker compose --profile gateway up -d
docker compose --profile docs up -d
```

Kafka 容器间使用 `kafka:9092`；宿主机客户端使用 `localhost:${KAFKA_PORT}`。`KAFKA_EXTERNAL_HOST` 是写入 Broker 元数据的宿主可达地址。远程客户端需将它设为 Docker 主机可达地址，并把 `WORKSPACE_BIND_IP` 设为相应网卡地址；默认绑定回环地址，不接受远程连接。

语言预设：

```bash
make go-env
make rust-env
make php-env
```

完整环境：

```bash
make full-env
```

完整环境资源消耗较大。GitLab 不属于默认启动项，需要时可单独启动 GitLab 及其 PostgreSQL、Redis 依赖：

```bash
make gitlab-env
```

宿主机浏览器访问 `http://localhost:8989`。GitLab Runner 只在 `make ci` 中启动；Runner 运行在 Compose 网络内，因此 `.env` 中的 `GITLAB_CI_SERVER_URL` 应使用 `http://gitlab`，而不是宿主机的 `localhost`。启用 Runner 前将示例注册令牌替换为有效令牌。

若还需要 GitLab Runner 和 Portainer，可显式启动完整 CI 管理组合：

```bash
make ci
```

`make ci` 只启动 PostgreSQL、Redis、GitLab、GitLab Runner 和 Portainer，不会顺带启动 MySQL、MongoDB 等其他数据库。也可以显式指定服务：

```bash
make dev workspace postgres redis gitlab
```

## 镜像检查与缓存

普通启动使用 Docker 本地缓存。需要检查所有 profile 镜像时：

```bash
make check
```

需要启动前执行镜像检查：

```bash
CHECK_VERSIONS=1 make go-env
```

需要显式重新拉取镜像：

```bash
PULL_IMAGES=1 make go-env
```

更新 Compose 镜像和构建参数记录：

```bash
make lock
make verify-lock
```

`.env.lock` 是 Compose 镜像引用与构建参数的快照，不会自动锁定可变镜像标签；`make verify-lock` 检查当前解析结果是否偏离快照。代理参数不会写入锁文件。需要不可变镜像时，应在镜像引用中使用 digest。

## 常用命令

```bash
make init
make build-workspace
make up
make shell
make ps
make logs
make down
make config
make doctor
make test
```

配置与入口检查：

```bash
make doctor
make test
docker compose config
docker compose --profile mysql --profile cache config
```

## 持久化目录

宿主机代码目录：

```text
~/codes -> /workspace
```

常用 Docker volume：

```text
workspace-shell-state
workspace-ssh
workspace-ssh-host-keys
workspace-mise-cache
workspace-gh-config
workspace-brew-cache
workspace-go-mod
workspace-cargo-registry
workspace-cargo-git
workspace-composer
etcd
grafana
```

基础设施数据默认位于：

```text
~/.development-docker/data
```

## 安全说明

`.env` 只用于本机配置，不应提交到 Git。示例文件中的数据库密码仅适合本地开发，请勿用于生产环境。

GitLab Runner 使用 Docker Socket 或 shell executor 时可能获得宿主机级权限，只应在可信环境中启用。默认启动不包含 GitLab；启用 Runner 前应先配置有效的注册令牌和可信执行器。
