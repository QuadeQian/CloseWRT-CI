#!/bin/sh
# adblock-lean 适配器（CloseWRT-CI 烘焙包框架）。
# 安装放在 WAN 上线后进行：优先在线安装（拿最新版），失败则回退镜像内烘焙的离线副本。
# 阶段：
#   install   - 首启动仅植入 WAN-up hotplug（安装需要网络，留给 WAN-up）
#   activate  - WAN 上线时执行：在线安装（带重试）→ 离线回退 → 生成配置 → 启用/启动
set -e

PKG="adblock-lean"
SRC_TARBALL="$(dirname "$0")/src.tar.gz"
# 纯在线（bake:false）时本地无归档，先从 raw 拉取 installer 再跑在线安装
RAW_INSTALLER_URL="https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh"
HOTPLUG="/etc/hotplug.d/iface/30-cwrt-$PKG"
INSTALLED_FLAG="/etc/.cwrt-$PKG-installed"

install_pkg() {
    # 首启动：仅植入 hotplug，真正安装等 WAN 上线（此时才有网络）
    cat > "$HOTPLUG" <<EOF
#!/bin/sh
[ "\$ACTION" = ifup ] || exit 0
[ "\$INTERFACE" = wan ] || exit 0
[ -f "$INSTALLED_FLAG" ] && exit 0
$0 activate
EOF
    chmod +x "$HOTPLUG"
    echo "adblock-lean: WAN-up hotplug planted; install deferred to WAN up."
    # 边界：首启动若 WAN 已上线，ifup 事件可能早于 hotplug，这里直接补触发一次
    if ubus call network.interface.wan status 2>/dev/null | grep -q '"up": *true'; then
        echo "adblock-lean: WAN already up at first boot, triggering activate..."
        "$0" activate &
    fi
}

# 用给定 installer 跑在线安装（自动拉最新版），重试 3 次
online_with() {
    installer="$1"
    i=1
    while [ "$i" -le 3 ]; do
        if sh "$installer" >/dev/null 2>&1; then
            echo "adblock-lean: online install OK (attempt $i)."
            return 0
        fi
        echo "adblock-lean: online install attempt $i failed, retrying..." >&2
        i=$((i + 1))
        sleep 15
    done
    return 1
}

do_install() {
    if [ -f "$SRC_TARBALL" ]; then
        # bake:true —— 临时解压归档，用其 installer 先在线、失败回退离线，用完即清
        tmp="$(mktemp -d)"
        tar -xzf "$SRC_TARBALL" -C "$tmp"
        installer="$tmp/abl-install.sh"
        if online_with "$installer"; then
            rm -rf "$tmp"
            return 0
        fi
        echo "adblock-lean: online failed, using baked dist (offline)..."
        if sh "$installer" -s "$tmp" -v 0.0.0-builtin >/dev/null 2>&1; then
            rm -rf "$tmp"
            return 0
        fi
        rm -rf "$tmp"
        return 1
    fi
    # bake:false —— 纯在线：先拉 installer，再在线安装
    installer="/tmp/abl-install.sh"
    echo "adblock-lean: fetching installer (online-only mode)..."
    if ! uclient-fetch "$RAW_INSTALLER_URL" -O "$installer" >/dev/null 2>&1; then
        echo "adblock-lean: failed to fetch installer." >&2
        return 1
    fi
    online_with "$installer"
}

configure_and_start() {
    # 仅首次生成默认配置（按设备 RAM 自动选预设），之后保留用户修改
    if [ ! -f /etc/adblock-lean/config ]; then
        /etc/init.d/$PKG gen_config >/dev/null 2>&1 || true
        if [ -f /etc/adblock-lean/config ]; then
            sed -i 's/^cron_schedule=.*/cron_schedule="0 5 * * *"/' /etc/adblock-lean/config
        fi
    fi
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron start 2>/dev/null || true
    /etc/init.d/$PKG enable
    # 已运行则跳过 start，避免每次 WAN-up 都重拉 blocklist（崩溃后由 status 检测自动重启）
    if /etc/init.d/$PKG status >/dev/null 2>&1; then
        echo "adblock-lean: already running, skip start (no blocklist re-fetch)."
    else
        /etc/init.d/$PKG start
    fi
}

activate_pkg() {
    if [ ! -f "$INSTALLED_FLAG" ]; then
        if do_install; then
            touch "$INSTALLED_FLAG"
        else
            echo "adblock-lean: install failed; will retry on next WAN up." >&2
            return 1
        fi
    fi
    configure_and_start
    echo "adblock-lean: activated."
}

case "${1:-install}" in
    install)  install_pkg ;;
    activate) activate_pkg ;;
    *) echo "usage: $0 [install|activate]"; exit 1 ;;
esac
