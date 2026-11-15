#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== libcurl 的 TLS 选项 ==="
grep -E 'config BR2_PACKAGE_LIBCURL_(OPENSSL|MBEDTLS|GNUTLS|WOLFSSL|RUSTLS)' "$BR/package/libcurl/Config.in"
echo
echo "=== 已构建的包版本 ==="
for p in htop libcurl mbedtls; do
	d=$(ls -d "$BR"/output/build/$p-* 2>/dev/null | head -1)
	[ -n "$d" ] && echo "$p → $(basename "$d")" || echo "$p → (未构建)"
done
