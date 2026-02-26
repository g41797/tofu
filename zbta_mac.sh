#!/bin/bash

# macOS native verification
# Usage: ./zbta_mac.sh &> /tmp/verify_mac.log

date

rm -rf ./.zig-cache/

zig build test -freference-trace --summary all -Doptimize=Debug

rm -rf ./.zig-cache/

zig build test -freference-trace --summary all -Doptimize=ReleaseSafe

rm -rf ./.zig-cache/

zig build test -freference-trace --summary all -Doptimize=ReleaseSmall

rm -rf ./.zig-cache/

zig build test -freference-trace --summary all -Doptimize=ReleaseFast

date
