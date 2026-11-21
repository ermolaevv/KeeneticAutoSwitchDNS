#!/bin/sh
# ==============================================================================
# OPKG Package Builder for KeeneticAutoSwitchDNS (Pure Shell Edition)
# Run directly on router or any Linux host
# ==============================================================================

set -e

PKG_NAME="keenetic-autoswitch-dns"
VERSION_INPUT="${1:-$GITHUB_REF_NAME}"
VERSION_CLEAN=$(echo "$VERSION_INPUT" | sed 's/^v//')
PKG_VERSION="${VERSION_CLEAN:-1.0.0}"
PKG_ARCH="all"
OUTPUT="${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/ipk-build.XXXXXX)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Building $OUTPUT..."

# 1. Prepare data directory
DATA_DIR="$TMP_DIR/data"
mkdir -p "$DATA_DIR/opt/bin" "$DATA_DIR/opt/etc/init.d"
cp "$SCRIPT_DIR/autoswitch.sh" "$DATA_DIR/opt/bin/autoswitch.sh"
cp "$SCRIPT_DIR/S99autoswitch" "$DATA_DIR/opt/etc/init.d/S99autoswitch"
chmod 755 "$DATA_DIR/opt/bin/autoswitch.sh"
chmod 755 "$DATA_DIR/opt/etc/init.d/S99autoswitch"

# 2. Prepare control directory
CONTROL_DIR="$TMP_DIR/control"
mkdir -p "$CONTROL_DIR"

cat << EOF > "$CONTROL_DIR/control"
Package: $PKG_NAME
Version: $PKG_VERSION
Depends: jq
Section: net
Architecture: $PKG_ARCH
Maintainer: KeeneticAutoSwitchDNS
Description: Automated DNS profile failover switch for Keenetic routers
EOF

cat << 'EOF' > "$CONTROL_DIR/postinst"
#!/bin/sh
chmod +x /opt/bin/autoswitch.sh
chmod +x /opt/etc/init.d/S99autoswitch
mkdir -p /opt/var/run

/opt/etc/init.d/S99autoswitch restart
exit 0
EOF

cat << 'EOF' > "$CONTROL_DIR/prerm"
#!/bin/sh
if [ -x /opt/etc/init.d/S99autoswitch ]; then
    /opt/etc/init.d/S99autoswitch stop 2>/dev/null
fi
exit 0
EOF

chmod 644 "$CONTROL_DIR/control"
chmod 755 "$CONTROL_DIR/postinst" "$CONTROL_DIR/prerm"

# 3. Create debian-binary
echo "2.0" > "$TMP_DIR/debian-binary"

# 4. Pack control.tar.gz and data.tar.gz
(cd "$CONTROL_DIR" && tar -czf "$TMP_DIR/control.tar.gz" ./*)
(cd "$DATA_DIR" && tar -czf "$TMP_DIR/data.tar.gz" ./*)

# 5. Pack final .ipk (outer tar.gz)
(cd "$TMP_DIR" && tar -czf "$SCRIPT_DIR/$OUTPUT" ./debian-binary ./control.tar.gz ./data.tar.gz)

echo "[SUCCESS] Package created: $SCRIPT_DIR/$OUTPUT"

