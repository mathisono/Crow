#!/bin/sh
#
# Crow USB Storage Setup for AREDN
#
# Installs the kernel modules and tools needed for USB mass storage
# on AREDN nodes. Run once before using /storage usb commands.
#
# Usage: sh /usr/local/raven/platforms/aredn/usb-setup.sh [format <device>]
#
#   sh usb-setup.sh            — install USB packages only
#   sh usb-setup.sh format     — install packages + format first USB drive as ext4
#   sh usb-setup.sh format sda1 — install packages + format /dev/sda1 as ext4
#
# Safe to re-run; already-installed packages are skipped.
#

set -e

USB_PACKAGES="kmod-usb-storage kmod-scsi-core kmod-fs-ext4 kmod-fs-vfat block-mount e2fsprogs"
DWC3_PACKAGES="kmod-usb-dwc3 kmod-usb-dwc3-qcom"
LABEL="CROWDATA"

echo "=== Crow USB Storage Setup ==="

# ---- Step 1: Install USB kernel modules ----
echo "Installing USB storage packages..."
opkg update >/dev/null 2>&1 || true

for pkg in $USB_PACKAGES; do
    if opkg list-installed | grep -q "^${pkg} "; then
        echo "  ${pkg}: already installed"
    else
        echo "  ${pkg}: installing..."
        opkg install "$pkg" 2>&1 | grep -v "^Downloading"
    fi
done

# ---- Step 2: Install DWC3 controller driver (IPQ40xx / Qualcomm SoCs) ----
# Check if this platform needs the DWC3 driver (device tree has dwc3 nodes)
if [ -d /sys/firmware/devicetree/base/soc ] && find /sys/firmware/devicetree/base/soc -maxdepth 1 -name "usb@*" -print -quit 2>/dev/null | grep -q .; then
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
            if opkg list-installed | grep -q "^${pkg} "; then
                echo "  ${pkg}: already installed"
            else
                echo "  ${pkg}: installing..."
                opkg install "$pkg" 2>&1 | grep -v "^Downloading"
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
    exit 0
fi

# ---- Step 5: Format if requested ----
if [ "$1" = "format" ]; then
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

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Flash usage:"
df -h /overlay
echo ""
echo "Use these commands from the Crow UI:"
echo "  /storage usb scan       — detect USB drives"
echo "  /storage usb enable     — mount and activate USB storage"
echo "  /storage quota images N — set image quota to N MB"
echo "  /storage status         — check current storage state"
