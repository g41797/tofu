@echo off

REM Windows native verification
REM Usage: zbta_win.cmd > zig-out\verify_win.log 2>&1

echo %date% %time%

rmdir /s /q .zig-cache 2>nul
zig build test -freference-trace --summary all -Doptimize=Debug

rmdir /s /q .zig-cache 2>nul
zig build test -freference-trace --summary all -Doptimize=ReleaseSafe

rmdir /s /q .zig-cache 2>nul
zig build test -freference-trace --summary all -Doptimize=ReleaseSmall

rmdir /s /q .zig-cache 2>nul
zig build test -freference-trace --summary all -Doptimize=ReleaseFast

echo %date% %time%
