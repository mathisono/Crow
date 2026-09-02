#!/bin/sh
#
# Crow USB Storage Setup for AREDN
#
# Installs the kernel modules and tools needed for USB mass storage
# on AREDN nodes. Run once before using /storage usb commands.
#
# Usage: sh /usr/local/crow/platforms/aredn/usb-setup.sh [assimilate|format <device>]
#
#   sh usb-setup.sh            — install USB packages only
#   sh usb-setup.sh assimilate — install/load support and discover an existing drive
#   sh usb-setup.sh format     — install packages + format first USB drive as ext4
#   sh usb-setup.sh format sda1 — install packages + format /dev/sda1 as ext4
#
# Safe to re-run; already-installed packages are skipped.
#

set -e

USB_PACKAGES="kmod-usb-storage kmod-scsi-core block-mount"
DWC3_PACKAGES="kmod-usb-dwc3 kmod-usb-dwc3-qcom"
LABEL="CROWDATA"
MODE="${1:-setup}"
STATUS_FILE="/tmp/crow-storage-assimilate.status"

case "$MODE" in
    setup|assimilate|format) ;;
    *)
        echo "Usage: $0 [assimilate|format [device]]" >&2
        exit 2
        ;;
esac

set_status() {
    if [ "$MODE" = "assimilate" ]; then
        echo "$1" > "$STATUS_FILE"
    fi
    return 0
}

set_status starting

if [ "$MODE" = "format" ]; then
    USB_PACKAGES="$USB_PACKAGES kmod-fs-ext4 e2fsprogs"
fi

echo "=== Crow USB Storage Setup ==="

# ---- Step 1: Install USB kernel modules ----
echo "Installing USB storage packages..."

if command -v apk >/dev/null 2>&1; then
    PACKAGE_MANAGER="apk"
elif command -v opkg >/dev/null 2>&1; then
    PACKAGE_MANAGER="opkg"
else
    echo "ERROR: neither apk nor opkg is available." >&2
    set_status no-package-manager
    exit 10
fi

package_installed() {
    case "$PACKAGE_MANAGER" in
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed 2>/dev/null | grep -q "^${1} " ;;
    esac
}

install_package() {
    case "$PACKAGE_MANAGER" in
        apk) apk add "$1" ;;
        opkg) opkg install "$1" ;;
    esac
}

need_packages=0
for pkg in $USB_PACKAGES; do
    package_installed "$pkg" || need_packages=1
done
if [ "$need_packages" = "1" ]; then
    case "$PACKAGE_MANAGER" in
        apk) apk update >/dev/null 2>&1 || true ;;
        opkg) opkg update >/dev/null 2>&1 || true ;;
    esac
fi

for pkg in $USB_PACKAGES; do
    if package_installed "$pkg"; then
        echo "  ${pkg}: already installed"
    else
        echo "  ${pkg}: installing..."
        if ! install_package "$pkg"; then
            echo "ERROR: failed to install ${pkg}." >&2
            set_status package-install-failed
            exit 11
        fi
    fi
done

# ---- Step 2: Install DWC3 controller driver (IPQ40xx / Qualcomm SoCs) ----
# Check if this platform needs the DWC3 driver (device tree has dwc3 nodes)
if [ -z "$(ls /sys/bus/usb/devices/usb* 2>/dev/null)" ] &&
   [ -d /sys/firmware/devicetree/base/soc ] &&
   find /sys/firmware/devicetree/base/soc -maxdepth 1 -name "usb@*" -print -quit 2>/dev/null | grep -q .; then
    needs_dwc3=0
    for usb_dt in /sys/firmware/devicetree/base/soc/usb@*; do
        compat=$(cat "$usb_dt/compatible" 2>/dev/null | tr '\0' ' ')
        case "$compat" in
            *dwc3*|*qcom*)
                needs_dwc3=1
                break
                ;;
        esac
    done

    if [ "$needs_dwc3" = "1" ]; then
        for pkg in $DWC3_PACKAGES; do
            if package_installed "$pkg"; then
                echo "  ${pkg}: already installed"
            else
                echo "  ${pkg}: installing..."
                if ! install_package "$pkg"; then
                    echo "ERROR: failed to install ${pkg}." >&2
                    set_status package-install-failed
                    exit 11
                fi
            fi
        done
    fi
fi

# ---- Step 3: Verify USB controller is active ----
sleep 2
if [ -z "$(ls /sys/bus/usb/devices/usb* 2>/dev/null)" ]; then
    echo ""
    echo "WARNING: No USB host controllers detected."
    echo "  If you just installed DWC3 drivers, try rebooting the node"
    echo "  or run: echo <device> > /sys/bus/platform/drivers/dwc3-qcom/unbind"
    echo "  then:   echo <device> > /sys/bus/platform/drivers/dwc3-qcom/bind"
    echo ""

    # Try auto-rebind if we can identify the DWC3 device
    for dev in /sys/bus/platform/drivers/dwc3-qcom/*.*; do
        devname=$(basename "$dev")
        if [ "$devname" != "bind" ] && [ "$devname" != "unbind" ] && [ "$devname" != "uevent" ] && [ "$devname" != "module" ]; then
            echo "Attempting USB controller reset (${devname})..."
            echo "$devname" > /sys/bus/platform/drivers/dwc3-qcom/unbind 2>/dev/null || true
            sleep 3
            echo "$devname" > /sys/bus/platform/drivers/dwc3-qcom/bind 2>/dev/null || true
            sleep 5
            break
        fi
    done
fi

if [ -z "$(ls /sys/bus/usb/devices/usb* 2>/dev/null)" ]; then
    set_status no-usb-controller
    if [ "$MODE" = "assimilate" ]; then
        exit 12
    fi
fi

# Load the storage stack now. Loading usb-storage probes already-enumerated
# mass-storage interfaces, so the drive does not normally need to be replugged.
for module in scsi_mod sd_mod usb_storage uas ext4 vfat; do
    /sbin/modprobe "$module" >/dev/null 2>&1 || true
done
sleep 2

# If a storage-class device was present before its driver, rebind only that
# USB device. Do not reset serial/GPS interfaces or the whole USB controller.
if [ -z "$(ls /sys/block/sd* 2>/dev/null)" ]; then
    for class_file in /sys/bus/usb/devices/*:*/bInterfaceClass; do
        [ -f "$class_file" ] || continue
        [ "$(cat "$class_file" 2>/dev/null)" = "08" ] || continue
        interface_dir=$(dirname "$class_file")
        interface_name=$(basename "$interface_dir")
        device_name=${interface_name%%:*}
        case "$device_name" in
            [0-9]*-[0-9]*)
                echo "Reprobing USB mass-storage device ${device_name}..."
                echo "$device_name" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
                sleep 1
                echo "$device_name" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
                ;;
        esac
    done
    sleep 3
fi

# ---- Step 4: Check for USB drives ----
echo ""
echo "=== USB Device Check ==="
sleep 2

found_drive=""
for b in /sys/block/sd*; do
    [ -d "$b" ] || continue
    bname=$(basename "$b")
    removable=$(cat "$b/removable" 2>/dev/null)
    if [ "$removable" = "1" ]; then
        sectors=$(cat "$b/size" 2>/dev/null)
        size_mb=$((sectors * 512 / 1024 / 1024))
        model=$(cat "$b/device/model" 2>/dev/null)
        echo "  Found: /dev/${bname} — ${model} (${size_mb} MB, removable)"

        # Find partition
        for part in "$b/${bname}"[0-9]*; do
            [ -d "$part" ] && found_drive="/dev/$(basename "$part")" && echo "  Partition: ${found_drive}"
        done
        [ -z "$found_drive" ] && found_drive="/dev/${bname}" && echo "  No partitions, using raw device: ${found_drive}"
    fi
done

if [ -z "$found_drive" ]; then
    echo "  No removable USB drives found."
    echo "  If you just plugged in a drive, try unplugging and replugging it."
    echo ""
    echo "Setup complete (packages installed). Plug in a USB drive and use"
    echo "  /storage usb scan"
    echo "  /storage usb enable"
    echo "from the Crow UI."
    if [ "$MODE" = "assimilate" ]; then
        set_status no-removable-drive
        exit 13
    fi
    exit 0
fi

# Install only the filesystem driver required by the existing drive. Assimilate
# never reformats or relabels media.
if [ "$MODE" != "format" ]; then
    block_info=$(/sbin/block info "$found_drive" 2>/dev/null || true)
    fs_type=$(echo "$block_info" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
    fs_package=""
    fs_module=""
    case "$fs_type" in
        ext2|ext3|ext4)
            fs_package="kmod-fs-ext4"
            fs_module="ext4"
            ;;
        vfat|msdos)
            fs_package="kmod-fs-vfat"
            fs_module="vfat"
            ;;
        "")
            echo "ERROR: no recognizable filesystem found on ${found_drive}." >&2
            set_status unsupported-filesystem
            if [ "$MODE" = "assimilate" ]; then
                exit 14
            fi
            ;;
        *)
            echo "ERROR: unsupported existing filesystem ${fs_type} on ${found_drive}." >&2
            set_status unsupported-filesystem
            if [ "$MODE" = "assimilate" ]; then
                exit 14
            fi
            ;;
    esac
    if [ -n "$fs_package" ] && ! package_installed "$fs_package"; then
        echo "  ${fs_package}: installing for ${fs_type}..."
        if ! install_package "$fs_package"; then
            echo "ERROR: failed to install ${fs_package}." >&2
            set_status package-install-failed
            exit 11
        fi
    fi
    [ -n "$fs_module" ] && /sbin/modprobe "$fs_module" >/dev/null 2>&1 || true
fi

# ---- Step 5: Format if requested ----
if [ "$MODE" = "format" ]; then
    target="${2:+/dev/$2}"
    target="${target:-$found_drive}"

    # Safety: refuse non-removable devices
    block=$(echo "$target" | sed 's|/dev/||; s|[0-9]*$||')
    if [ "$(cat /sys/block/${block}/removable 2>/dev/null)" != "1" ]; then
        echo "ERROR: ${target} is not a removable device. Refusing to format."
        exit 1
    fi

    echo ""
    echo "Formatting ${target} as ext4 (label: ${LABEL})..."
    mkfs.ext4 -L "$LABEL" -m 1 "$target"
    echo "Format complete."
fi

set_status ready

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Flash usage:"
df -h /overlay
echo ""
echo "Use these commands from the Crow UI:"
echo "  /storage usb scan       — detect USB drives"
echo "  /storage usb enable     — mount and activate USB storage"
echo "  /storage assimilate     — install/load support and activate an existing drive"
echo "  /storage quota images N — set image quota to N MB"
echo "  /storage status         — check current storage state"
