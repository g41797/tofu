#!/bin/bash
# docs_zig.sh: Regenerate autodoc artifacts
set -e
echo "Regenerating Zig autodocs..."
zig build docs
echo "Autodocs regenerated."
