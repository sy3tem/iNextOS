# Rockchip RK3528A quad core | 1x GbE (SoC gmac1 + RTL8211F) + 1x GbE (PCIe RTL8111H) | AIC8800 SDIO WiFi | eMMC
BOARD_NAME="NanoPi R28S"
BOARD_VENDOR="friendlyelec"
BOARDFAMILY="rk35xx"
BOARD_MAINTAINER="sy3tem"
BOOTCONFIG="hinlink_rk3528_defconfig"          # supplied by patch/u-boot/legacy/u-boot-radxa-rk35xx/defconfig/ (RK3528 vendor U-Boot)
BOOT_SOC="rk3528"                              # explicit; selects spl-blobs + ddrbin/bl31 blobs (rockchip64_common.inc rk3528 case)
KERNEL_TARGET="edge"                           # mainline 6.19: common.conf then sets LINUXFAMILY=rockchip64 and KERNELPATCHDIR=archive/rockchip64-6.19
BOOT_FDT_FILE="rockchip/rk3528-nanopi-r28s.dtb"
BOOT_SCENARIO="spl-blobs"                      # idbloader.img + u-boot.itb, written in two stages
IMAGE_PARTITION_TABLE="gpt"
BOOTFS_TYPE="ext4"                             # same as the NanoPi Zero2 board
BOOTSIZE="512"
FULL_DESKTOP="no"
HAS_VIDEO_OUTPUT="no"

# ── iNextOS branding + AIC8800 SDIO WiFi (DKMS is compiled inside the chroot) ──
enable_extension "istorenext"                  # VENDOR=iNextOSA / HOST=iNextOS / ROOTPWD=password / SKIP_ARMBIAN_REPO=yes
enable_extension "radxa-aic8800"
AIC8800_TYPE="sdio"

# ── Console must be UART0 (ttyS0), not the family default (ttyS2, which is the Bluetooth UART) ──
#    Un-numbered hooks get a "500_" sort id, so this runs BEFORE post_family_config__900_late_default_serial_console_by_branch().
#    That late hook keeps an already-set SERIALCON ("SERIALCON already set to ..., keeping it"), which is the documented
#    override mechanism. BOOTSCRIPT has to be set here too: the board file is sourced before the family conf, and
#    rk35xx.conf/rockchip64_common.inc would otherwise overwrite any top-level BOOTSCRIPT of ours.
#
#    BOOTENV_FILE cannot be set at the top level either (the family conf reassigns it), and for rk3528
#    rockchip64_common.inc leaves it at its file-scope default "rockchip64.txt" -- whose verbosity=1 becomes
#    loglevel=1 in the kernel cmdline (nothing is printed after "Starting kernel ..."), and whose console=both
#    puts tty1 last so /dev/console is the HDMI-less video console. config/bootenv/r28s.txt fixes both: it is
#    copied by distro_agnostic(), which runs before the armbian-bsp-cli postinst, so it is what the image keeps.
function post_family_config__r28s_serial_console() {
	[[ "${BRANCH}" == "vendor" ]] && return 0
	declare -g SERIALCON="ttyS0"
	declare -g BOOTSCRIPT="boot-rockchip64-ttyS0.cmd:boot.cmd"
	declare -g BOOTENV_FILE="r28s.txt"
}

# ── Interface ordering + management port ──
#    iNextOS' fix-ifaces-name reads /etc/eth_order (comma separated sysfs device paths, first one becomes eth0);
#    istorenext-init-network reads /root/.default-network once, on first boot.
#    Port 1 (silkscreen) = SoC gmac  = ffbe0000.ethernet -> eth0
#    Port 2 (silkscreen) = PCIe NIC  = 0000:01:00.0      -> eth1  = management, static 192.168.100.1
function post_family_tweaks__r28s_network_order() {
	echo "ffbe0000.ethernet,0000:01:00.0" > "${SDCARD}/etc/eth_order"
	echo "DEFAULT_INTERFACE=eth1" > "${SDCARD}/root/.default-network"
}

# ── Do not let a kernel package upgrade replace our DTB ──
function post_family_tweaks__r28s_hold_dtb() {
	chroot_sdcard apt-mark hold linux-dtb-edge-rockchip64 > /dev/null 2>&1 || true
	return 0
}

# ── Hardware fix-ups for what the upstream iStoreNext glue does not cover ──
#    Two problems, both verified on the board:
#      1. interface naming: their fix-ifaces-name derives the sysfs path as
#         /sys/devices/platform/<device>, which never matches the SoC gmac --
#         on Rockchip the platform device is nested one level deeper, under
#         ".../platform/soc/".  The gmac therefore keeps the udev name "end0".
#      2. LEDs: the DT declares linux,default-trigger="netdev" for WAN/LAN, but
#         ledtrig-netdev is a module that nothing loads, so the trigger falls
#         back to "none" and both LEDs stay dark.
#    Shipped as one script + two units.  Two units because the two jobs have
#    opposite ordering requirements: renaming has to finish before
#    network-pre.target, whereas the LEDs can only be bound after
#    armbian-led-state.service has restored (and thus undone) the saved state.
#    The 600_ sort id makes this hook run after the upstream post_family_tweaks__5xx_*.
#
#    NOTE: the heredocs below are deliberately unindented (no <<-) so that the
#    indentation of the generated files is exactly what is written here.
function post_family_tweaks__600_r28s_hwfix() {
	display_alert "Installing NanoPi R28S hardware fix-ups" "interface names + WAN/LAN LEDs" "info"

	mkdir -p "${SDCARD}"/usr/local/sbin "${SDCARD}"/etc/systemd/system \
		"${SDCARD}"/etc/systemd/system/sysinit.target.wants \
		"${SDCARD}"/etc/systemd/system/multi-user.target.wants

	cat > "${SDCARD}"/usr/local/sbin/r28s-hwfix <<'HWEFIX_SCRIPT'
#!/bin/bash
# NanoPi R28S (Rockchip RK3528A) hardware fix-ups.
#
#   r28s-hwfix iface   reorder the NICs to eth0/eth1 before networking comes up
#   r28s-hwfix leds    bind the WAN/LAN LEDs to their ports

set -u

# ---------------------------------------------------------------------------
# Interfaces
# ---------------------------------------------------------------------------
# /etc/eth_order lists the NICs in silkscreen order; entry N has to become ethN.
# The stock istorenext helper "fix-ifaces-name" builds the sysfs path as
# /sys/devices/platform/<device>, which never matches the SoC gmac: on Rockchip
# the platform device is nested one level deeper, under "soc/" --
#   /sys/devices/platform/soc/ffbe0000.ethernet
# so the gmac keeps the udev name "end0" and is never renamed.  Resolve the
# owner of each netdev through readlink instead, which is layout independent.
iface_by_device() {	# $1 = sysfs device name (e.g. ffbe0000.ethernet)
	local i d
	for i in $(ls /sys/class/net); do
		d=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || continue
		[ -n "$d" ] && [ "$(basename "$d")" = "$1" ] && { echo "$i"; return 0; }
	done
	return 0
}

# renaming requires the link to be down; restore the previous admin state after
rename_if() {		# $1 = current name, $2 = wanted name
	[ -n "$1" ] && [ "$1" != "$2" ] && [ -e "/sys/class/net/$1" ] || return 0
	local flags=0
	read -r flags < "/sys/class/net/$1/flags" 2>/dev/null || flags=0
	ip link set "$1" down 2>/dev/null || true
	ip link set "$1" name "$2" 2>/dev/null || return 0
	[ $((flags & 1)) -ne 0 ] && ip link set "$2" up 2>/dev/null
	return 0
}

iface_mode() {
	[ -s /etc/eth_order ] || return 0

	local n dev cur
	# pass 1: park every mis-named NIC under a scratch name, so the final names
	# cannot collide with a NIC that still owns one of them.  A NIC that already
	# carries the right name is left completely alone -- it may well be the one
	# this very script is being reached over.
	n=0
	for dev in $(tr ',' ' ' < /etc/eth_order); do
		cur=$(iface_by_device "$dev")
		[ -z "$cur" ] || [ "$cur" = "eth$n" ] || rename_if "$cur" "r28s$n"
		n=$((n + 1))
	done

	# pass 2: hand out the final names
	n=0
	for dev in $(tr ',' ' ' < /etc/eth_order); do
		rename_if "r28s$n" "eth$n"
		n=$((n + 1))
	done
	return 0
}

# ---------------------------------------------------------------------------
# LEDs
# ---------------------------------------------------------------------------
# The DT declares linux,default-trigger = "netdev" for the WAN/LAN LEDs, but
# ledtrig-netdev is built as a module that nothing loads, so the trigger
# silently falls back to "none" and both LEDs stay dark.  Load it and point
# each LED at its port.  Silkscreen order:
#   port 1 = SoC gmac       = eth0 = WAN
#   port 2 = PCIe RTL8111H  = eth1 = LAN
bind_led() {		# $1 = led name, $2 = netdev
	local led="/sys/class/leds/$1"
	[ -d "$led" ] || return 0
	[ -e "/sys/class/net/$2" ] || return 0
	echo netdev > "$led/trigger" 2>/dev/null || return 0
	echo "$2" > "$led/device_name" 2>/dev/null || true
	return 0
}

leds_mode() {
	modprobe ledtrig-netdev 2>/dev/null || true
	bind_led wan_led eth0
	bind_led lan_led eth1
	return 0
}

case "${1:-}" in
iface) iface_mode ;;
leds) leds_mode ;;
*)
	iface_mode
	leds_mode
	;;
esac

exit 0
HWEFIX_SCRIPT
	chmod 755 "${SDCARD}"/usr/local/sbin/r28s-hwfix

	cat > "${SDCARD}"/etc/systemd/system/r28s-iface-name.service <<'HWEFIX_IFACE'
[Unit]
Description=NanoPi R28S: reorder network interfaces to eth0/eth1
DefaultDependencies=no
After=systemd-udev-settle.service fix-ifaces-name.service
Before=network-pre.target network.target networking.service ifupdown-pre.service istorenext-init-network.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/r28s-hwfix iface
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=sysinit.target
HWEFIX_IFACE

	cat > "${SDCARD}"/etc/systemd/system/r28s-leds.service <<'HWEFIX_LEDS'
[Unit]
Description=NanoPi R28S: bind WAN/LAN LEDs to their network ports
After=sysinit.target local-fs.target armbian-led-state.service
Wants=armbian-led-state.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/r28s-hwfix leds
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HWEFIX_LEDS

	# enable them the deterministic way: systemd only needs the .wants symlink
	ln -sf /etc/systemd/system/r28s-iface-name.service \
		"${SDCARD}"/etc/systemd/system/sysinit.target.wants/r28s-iface-name.service
	ln -sf /etc/systemd/system/r28s-leds.service \
		"${SDCARD}"/etc/systemd/system/multi-user.target.wants/r28s-leds.service

	return 0
}

# ── iStoreNext Web UI ("roceos") ──
#    The Web UI is a Go backend on 127.0.0.1:8080 plus an SPA served by nginx
#    from /opt/roceos/www.  None of it is present on the public armbian-easepi
#    build chain -- that tree only carries branding/network glue
#    (extensions/istorenext.sh, packages/bsp/istorenext/*).  The payload is
#    published on the vendor's update server, which config/roceos/install-roceos.sh
#    fetches (channels endpoint is public; sha256 is pinned by the server).
#    Running it here, on the build host, means the flashed image already has the
#    UI and the device needs no network for its first boot.
#
#    The script is also left in the image as /usr/local/sbin/roceos-install with
#    a vendored glue copy, so the same operation can be repeated on the device.
function post_family_tweaks__700_r28s_roceos() {
	display_alert "Installing the iStoreNext Web UI (roceos)" "backend + frontend" "info"

	local src="${SRC}/config/roceos"

	# 1. ship the installer + vendored glue into the image, so the very same
	#    operation can be repeated on the device (reinstall / repair / offline)
	install -Dm755 "${src}/install-roceos.sh" "${SDCARD}/usr/local/sbin/roceos-install"
	install -d "${SDCARD}/usr/local/share/roceos"
	cp -rf "${src}/glue" "${SDCARD}/usr/local/share/roceos/glue"

	# 2. install the payload into the image now.  The download happens here, on
	#    the build host, which is also why --arch is passed explicitly: the build
	#    container is x86_64 while the image being populated is arm64.
	#    --skip-ai: roceos-ai wants librkllmrt.so, the *RK3588* RKNPU2 runtime.
	#    The RK3528 has no NPU at all, so the service is installed but left
	#    disabled instead of crash-looping.
	if ! "${src}/install-roceos.sh" \
		--root "${SDCARD}" \
		--arch arm64 \
		--glue "${src}/glue" \
		--skip-ai; then
		display_alert "roceos install failed" \
			"the image will boot without a Web UI; re-run /usr/local/sbin/roceos-install on the device" "warn"
	fi

	return 0
}
