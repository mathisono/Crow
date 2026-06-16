#!/bin/sh
# One-time compatibility importer for systems upgrading from Raven to Crow.
# Crow owns /etc/crow.conf, /etc/crow.conf.override, and /usr/local/crow.
# Legacy Raven paths are used only as import sources when Crow files do not exist.

set -eu

copy_if_missing() {
    src="$1"
    dst="$2"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        echo "crow-migrate: imported $src -> $dst"
    fi
}

copy_tree_if_missing() {
    src="$1"
    dst="$2"
    if [ -d "$src" ] && [ ! -d "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst"
        echo "crow-migrate: imported $src -> $dst"
    fi
}

copy_if_missing /etc/raven.conf /etc/crow.conf
copy_if_missing /etc/raven.conf.override /etc/crow.conf.override

# Preserve old local runtime data only when Crow data has not been created yet.
copy_tree_if_missing /usr/local/raven/data /usr/local/crow/data
copy_tree_if_missing /usr/local/raven/store /usr/local/crow/store
copy_tree_if_missing /usr/local/raven/winlink /usr/local/crow/winlink

# Preserve USB/external storage data if the old mountpoint exists and the new one does not.
copy_tree_if_missing /mnt/raven /mnt/crow

exit 0
