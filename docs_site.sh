#!/bin/bash
# docs_site.sh: Build the full documentation site
set -e
echo "Building full documentation site..."
cd docs_site && mkdocs build
echo "Site build complete."
