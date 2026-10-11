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
function post_family_config__r28s_serial_console() {
	[[ "${BRANCH}" == "vendor" ]] && return 0
	declare -g SERIALCON="ttyS0"
	declare -g BOOTSCRIPT="boot-rockchip64-ttyS0.cmd:boot.cmd"
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
