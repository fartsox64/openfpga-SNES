#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RBF="$REPO/projects/output_files/snes_pocket.rbf"
CORE_DIR="$REPO/pkg/Cores/agg23.SNES"

reverse_rbf() {
    local src="$1" dst="$2"
    python3 -c "
import sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())
for i, b in enumerate(data):
    data[i] = ((b&1)<<7)|((b&2)<<5)|((b&4)<<3)|((b&8)<<1)|((b&16)>>1)|((b&32)>>3)|((b&64)>>5)|((b&128)>>7)
open(dst, 'wb').write(data)
" "$src" "$dst"
}

build_variant() {
    local tcl_type="$1" rev_name="$2"
    echo ""
    echo "=== Building $tcl_type ==="
    docker run --rm -v "$REPO:/build" raetro/quartus:21.1 \
        quartus_sh -t generate.tcl "$tcl_type"
    echo "Reversing bitstream -> $rev_name"
    reverse_rbf "$RBF" "$CORE_DIR/$rev_name"
}

# Build all variants
build_variant ntsc      snes_main.rev
build_variant pal       snes_pal.rev
build_variant ntsc_spc  snes_spc.rev

echo ""
echo "Done. .rev files written to: $CORE_DIR"
