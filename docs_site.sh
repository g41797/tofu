#!/bin/bash
# Full doc site build: Zig autodoc + MkDocs
# Requires: pip install mkdocs-material mkdocs-awesome-pages-plugin mkdocs-minify-plugin
#           mkdocs-open-in-new-tab mkdocs-git-revision-date-localized-plugin
set -e
./docs_zig.sh
cd docs_site && mkdocs build
