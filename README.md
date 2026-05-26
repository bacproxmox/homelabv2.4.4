# Homelab v2.4.4

Proxmox + TrueNAS + Docker service automation package.

## Bootstrap

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bacproxmox/homelabv2.4.4/main/bootstrap.sh)
```

## v2.4.4 focus

This release uses the working v2.4.1 VM/pipeline foundation and adds isolated service/config fixes only. See `docs/RELEASE-2.4.4.md`.

Highlights:

- Keeps v2.4.1 guided pipeline and fixed MAC foundation.
- Adds optional `nvme-media` storage for VM106 and VM107 using the blank MLD M500 1TB NVMe.
- Adds Bacscloud Admin Overview cleanup, Google Social Login, controlled Registration, branding, cron, and quota policy.
- Hardens PBS install/backup automation without changing the shared VM creation library.
- Adds Immich CPU fallback when `/dev/dri` is not present.
- Keeps Chia DB cache/downloads on TrueNAS `tank/chia-db`; active Chia DB remains local on VM107.
