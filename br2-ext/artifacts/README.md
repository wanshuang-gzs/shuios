# artifacts

这个目录是 `tools/build-rust.sh` 的输出位置：`shuiosd`、`shui`、`shui-ctl`
三个预编译二进制会被放到这里，再由 Buildroot 的 `shuios-runtime` 包安装进镜像。

二进制不进版本库（见 `.gitignore`），因为它们是构建产物。首次构建前请先执行：

```
./tools/build-rust.sh
```
