#!/usr/bin/env bash

set -euo pipefail

echo "========================================="
echo "macOS VM Host Capability Check (Fedora)"
echo "========================================="
echo

echo "===== OS ====="
cat /etc/os-release || true
echo

echo "===== Kernel ====="
uname -a
echo

echo "===== CPU ====="
lscpu
echo

echo "===== Virtualization Flags ====="
egrep -o '(vmx|svm)' /proc/cpuinfo | sort -u || echo "No virtualization flags found"
echo

echo "===== RAM ====="
free -h
echo

echo "===== KVM Modules ====="
lsmod | grep kvm || echo "KVM not loaded"
echo

echo "===== CPU Virtualization Support ====="
if egrep -q '(vmx|svm)' /proc/cpuinfo; then
    echo "SUPPORTED"
else
    echo "NOT SUPPORTED"
fi
echo

echo "===== IOMMU Status ====="
dmesg | grep -Ei 'iommu|amd-vi|intel-iommu' || echo "No IOMMU detected"
echo

echo "===== GPU Devices ====="
lspci | grep -Ei 'vga|3d|display'
echo

echo "===== Full GPU Details ====="
lspci -nnk | grep -EA3 'VGA|3D|Display'
echo

echo "===== IOMMU Groups ====="
if [ -d /sys/kernel/iommu_groups ]; then
    for g in /sys/kernel/iommu_groups/*; do
        echo "Group $(basename "$g"):"
        for d in "$g"/devices/*; do
            lspci -nns "${d##*/}"
        done
        echo
    done
else
    echo "No IOMMU groups exposed"
fi
echo

echo "===== Installed Virtualization Packages ====="
rpm -qa | grep -Ei 'qemu|virt-manager|libvirt|ovmf' || true
echo

echo "===== libvirtd ====="
systemctl status libvirtd --no-pager || true
echo

echo "===== Secure Boot ====="
mokutil --sb-state 2>/dev/null || echo "mokutil not installed"
echo

echo "===== Disk Space ====="
df -h /
echo

echo "===== Suggested Result ====="

CPU_OK=$(egrep -c '(vmx|svm)' /proc/cpuinfo || true)

if [ "$CPU_OK" -gt 0 ]; then
    echo "Virtualization supported"
else
    echo "Virtualization NOT supported"
fi

GPU_COUNT=$(lspci | grep -Ei 'vga|3d|display' | wc -l)

if [ "$GPU_COUNT" -ge 2 ]; then
    echo "Multi-GPU detected -> GPU passthrough likely possible"
else
    echo "Single GPU -> basic macOS VM easier than passthrough"
fi

echo
echo "Done."
