#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Verify project detection chooses a valid lower-bound version and respects
# existing mise configuration files.
node_project="${TMP_DIR}/node-project"
mkdir -p "${node_project}"
printf '%s\n' '{"engines":{"node":">=18 <21"}}' > "${node_project}/package.json"
bash "${ROOT_DIR}/workspaces/scripts/detect-stack.sh" "${node_project}" > "${TMP_DIR}/detect-node.out"
grep -q 'node = "18"' "${node_project}/.mise.toml" || fail 'Node range was not converted to a valid lower bound'
! grep -q '1821' "${node_project}/.mise.toml" || fail 'Node range was concatenated into an invalid version'

configured_project="${TMP_DIR}/configured-project"
mkdir -p "${configured_project}"
printf '%s\n' '[tools]' 'python = "3.13"' > "${configured_project}/mise.toml"
: > "${configured_project}/requirements.txt"
bash "${ROOT_DIR}/workspaces/scripts/detect-stack.sh" "${configured_project}" >/dev/null
test ! -e "${configured_project}/.mise.toml" || fail 'Existing mise.toml was shadowed'

python_project="${TMP_DIR}/python-project"
mkdir -p "${python_project}"
printf '%s\n' '[project]' 'requires-python = ">=3.10,<3.13"' > "${python_project}/pyproject.toml"
bash "${ROOT_DIR}/workspaces/scripts/detect-stack.sh" "${python_project}" >/dev/null
grep -q 'python = "3.10"' "${python_project}/.mise.toml" || fail 'Python lower-bound constraint was not detected'

node_wildcard_project="${TMP_DIR}/node-wildcard-project"
mkdir -p "${node_wildcard_project}"
printf '%s\n' '{"engines":{"node":"20.x"}}' > "${node_wildcard_project}/package.json"
bash "${ROOT_DIR}/workspaces/scripts/detect-stack.sh" "${node_wildcard_project}" >/dev/null
grep -q 'node = "20"' "${node_wildcard_project}/.mise.toml" || fail 'Node major wildcard selected an unrelated version'

python_upper_bound_project="${TMP_DIR}/python-upper-bound-project"
mkdir -p "${python_upper_bound_project}"
printf '%s\n' '[project]' 'requires-python = "<3.12"' > "${python_upper_bound_project}/pyproject.toml"
bash "${ROOT_DIR}/workspaces/scripts/detect-stack.sh" "${python_upper_bound_project}" >"${TMP_DIR}/detect-python.out" 2>"${TMP_DIR}/detect-python.err"
test ! -e "${python_upper_bound_project}/.mise.toml" || fail 'Unsupported Python upper bound generated an unsafe default'
grep -q 'cannot safely infer Python version' "${TMP_DIR}/detect-python.err" || fail 'Unsupported Python upper bound was not explained'

# A fake Docker executable records exact argv, proving the bridge preserves
# argument boundaries and maps a nested host project to its container path.
mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/codes/project"
cat > "${TMP_DIR}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${DEV_DOCKER_ARGS}"
MOCK
chmod +x "${TMP_DIR}/bin/docker"
DEV_DOCKER_ARGS="${TMP_DIR}/dev-argv" \
APP_CODE_PATH_HOST="${TMP_DIR}/codes" APP_CODE_PATH_CONTAINER=/workspace \
PATH="${TMP_DIR}/bin:${PATH}" \
  bash -c 'cd "$1" && "$2" exec printf "%s" "hello world"' _ \
  "${TMP_DIR}/codes/project" "${ROOT_DIR}/scripts/dev"
python3 - "${TMP_DIR}/dev-argv" "${TMP_DIR}/codes/project" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0").decode().split("\0")
expected = ["compose", "exec", "-u", "developer", "-T", "-w", "/workspace/project",
            "workspace", "mise", "exec", "--", "printf", "%s", "hello world"]
if args != expected:
    raise SystemExit(f"unexpected dev argv: {args!r}")
PY

# The default `~/codes` path in .env is a literal Compose value in the env
# parser; verify it and the `${HOME}` spelling both map nested projects.
mkdir -p "${TMP_DIR}/dev-repo/scripts" "${TMP_DIR}/dev-home/codes/project"
cp "${ROOT_DIR}/scripts/dev" "${TMP_DIR}/dev-repo/scripts/dev"
printf '%s\n' 'APP_CODE_PATH_HOST=~/codes' 'APP_CODE_PATH_CONTAINER=/workspace' > "${TMP_DIR}/dev-repo/.env"
HOME="${TMP_DIR}/dev-home" DEV_DOCKER_ARGS="${TMP_DIR}/dev-tilde-argv" \
PATH="${TMP_DIR}/bin:${PATH}" bash -c 'cd "$1" && "$2" exec pwd' _ \
  "${TMP_DIR}/dev-home/codes/project" "${TMP_DIR}/dev-repo/scripts/dev"
python3 - "${TMP_DIR}/dev-tilde-argv" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0").decode().split("\0")
if "-w" not in args or args[args.index("-w") + 1] != "/workspace/project":
    raise SystemExit(f"~/codes was not mapped to nested project path: {args!r}")
PY
printf '%s\n' 'APP_CODE_PATH_HOST=${HOME}/codes' 'APP_CODE_PATH_CONTAINER=/workspace' > "${TMP_DIR}/dev-repo/.env"
HOME="${TMP_DIR}/dev-home" DEV_DOCKER_ARGS="${TMP_DIR}/dev-home-argv" \
PATH="${TMP_DIR}/bin:${PATH}" bash -c 'cd "$1" && "$2" exec pwd' _ \
  "${TMP_DIR}/dev-home/codes/project" "${TMP_DIR}/dev-repo/scripts/dev"
python3 - "${TMP_DIR}/dev-home-argv" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0").decode().split("\0")
if "-w" not in args or args[args.index("-w") + 1] != "/workspace/project":
    raise SystemExit(f"${{HOME}}/codes was not mapped to nested project path: {args!r}")
PY
HOME="${TMP_DIR}/dev-home" DEV_DOCKER_ARGS="${TMP_DIR}/dev-doctor-argv" \
PATH="${TMP_DIR}/bin:${PATH}" bash "${TMP_DIR}/dev-repo/scripts/dev" doctor \
  >"${TMP_DIR}/dev-doctor.out" || fail 'doctor rejected the default ~/codes directory'
grep -q 'Workspace configuration and runtime checks passed' "${TMP_DIR}/dev-doctor.out" || \
  fail 'doctor did not report successful default ~/codes validation'

# Build proxy values must not be persisted into the image environment. Runtime
# injection remains configured by Compose, and the checked-in snapshot excludes them.
! grep -Eq '^ENV (HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)=' \
    "${ROOT_DIR}/workspaces/workspace.Dockerfile" || fail 'Proxy values are persisted in the workspace image ENV'
grep -q 'HTTP_PROXY=${HTTP_PROXY}' "${ROOT_DIR}/docker-compose.yml" || fail 'Runtime proxy injection is missing'
grep -q '^workspace=development-docker/workspace:multiarch$' "${ROOT_DIR}/.env.lock" || fail 'Workspace image is missing from .env.lock'
grep -q '^traefik.TRAEFIK_VERSION=v3.0.2$' "${ROOT_DIR}/.env.lock" || fail 'Traefik version is missing from .env.lock'
! grep -Eq '^workspace\.(HTTP_PROXY|HTTPS_PROXY|NO_PROXY)=' "${ROOT_DIR}/.env.lock" || fail 'Proxy values are present in .env.lock'
grep -q 'WORKSPACE_BREW_PACKAGES=gh jq yq ripgrep fzf tree tmux fd neovim starship' \
    "${ROOT_DIR}/.env.lock" || fail 'Workspace package snapshot is stale'

# Verify externally supplied image and UID override values survive loading .env.
DEV_DOCKER_ARGS="${TMP_DIR}/build-argv" \
WORKSPACE_IMAGE=registry.example.test/dev/workspace:test \
WORKSPACE_PUID=4242 PLATFORMS=linux/arm64 \
PATH="${TMP_DIR}/bin:${PATH}" \
  bash "${ROOT_DIR}/scripts/build-workspace.sh" >/dev/null
python3 - "${TMP_DIR}/build-argv" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0").decode().split("\0")
for expected in ("registry.example.test/dev/workspace:test", "PUID=4242"):
    if expected not in args:
        raise SystemExit(f"build override missing from docker argv: {expected}")
PY

# A caller HOST_PROXY_URL must be re-evaluated after loading .env defaults.
mkdir -p "${TMP_DIR}/proxy-repo/scripts"
cp "${ROOT_DIR}/scripts/build-workspace.sh" "${TMP_DIR}/proxy-repo/scripts/build-workspace.sh"
printf '%s\n' 'HOST_PROXY_URL=http://proxy-from-env:7897' 'HTTP_PROXY=${HOST_PROXY_URL}' 'HTTPS_PROXY=${HOST_PROXY_URL}' > "${TMP_DIR}/proxy-repo/.env"
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  DEV_DOCKER_ARGS="${TMP_DIR}/proxy-build-argv" HOST_PROXY_URL=http://proxy-from-shell:8000 \
  PATH="${TMP_DIR}/bin:${PATH}" bash "${TMP_DIR}/proxy-repo/scripts/build-workspace.sh" >/dev/null
python3 - "${TMP_DIR}/proxy-build-argv" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().rstrip(b"\0").decode().split("\0")
for key in ("HTTP_PROXY=http://proxy-from-shell:8000", "HTTPS_PROXY=http://proxy-from-shell:8000"):
    if key not in args:
        raise SystemExit(f"caller proxy override missing from docker argv: {key}")
PY

# Keep global tool activation and fail-fast syntax checking as regression gates.
grep -q 'mise use --global' "${ROOT_DIR}/workspaces/workspace.Dockerfile" || fail 'Preinstalled mise tools are not activated globally'
grep -q 'sha256sum --check' "${ROOT_DIR}/workspaces/workspace.Dockerfile" || fail 'mise download is not checked against release SHA-256'
grep -q '09c62fc577ec170172b0a184060f141a2c622dc1/install.sh' \
  "${ROOT_DIR}/workspaces/workspace.Dockerfile" || fail 'Homebrew installer source is not pinned to a commit'
printf 'if then\\n' > "${TMP_DIR}/invalid-shell.sh"
if find "${TMP_DIR}" -type f -name 'invalid-shell.sh' -print0 | xargs -0 -n 1 bash -n >/dev/null 2>&1; then
  fail 'Shell syntax check command masked a syntax error'
fi

grep -q 'workspace-gh-config:' "${ROOT_DIR}/docker-compose.yml" || fail 'gh credentials are not persisted in a dedicated volume'
grep -q 'gh auth setup-git' "${ROOT_DIR}/README.md" || fail 'GitHub HTTPS credential-helper setup is undocumented'

echo 'Workspace regression tests passed.'
