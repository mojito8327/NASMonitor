# 预编译安装包

| 文件 | 说明 |
|---|---|
| `NASMonitor-1.3.zip` | macOS 菜单栏应用，arm64（Apple Silicon） |
| `SHA256SUMS` | 校验值 |

```bash
shasum -a 256 -c SHA256SUMS
unzip -q NASMonitor-1.3.zip
/usr/bin/xattr -cr NASMonitor.app   # 首次打开被 Gatekeeper 拦截时
open NASMonitor.app
```

应用为 ad-hoc 签名、未公证；也可在「系统设置 → 隐私与安全性」点「仍要打开」。Intel Mac 请从源码 `./build.sh` 构建。使用说明见仓库根目录 [README](../README.md)。
