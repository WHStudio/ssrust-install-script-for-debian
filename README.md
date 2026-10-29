# ssrust-install-script-for-debian

One-click installer for the [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) server (`ssserver`) on Debian 13. It supports:

- SS2022 ciphers: aes-128-gcm (default), aes-256-gcm and chacha20-poly1305.
- Single-user or multi-user (EIH) setups.
- An ACL plus a uid-based nftables guard that block private and loopback destinations.
- A hardened systemd unit.
- mihomo YAML and ss:// link output.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/WHStudio/ssrust-install-script-for-debian/main/install.sh)
```

Documentation is in Chinese: [README.zh_CN.md](README.zh_CN.md).
