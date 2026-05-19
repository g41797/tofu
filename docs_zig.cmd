@echo off
:: docs_zig.cmd: Regenerate autodoc artifacts
echo Regenerating Zig autodocs...
zig build docs
echo Autodocs regenerated.
