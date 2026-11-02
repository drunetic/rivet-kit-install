# patch. installers

Installers for **patch.**, private kit-tracking and production software. These scripts contain
none of patch itself: they download it with a **licence key** (it starts `patch_`), and only people
who have been given one can install it. There is no public download, no sign-up and no support beyond the people
who gave you your code.

## Proxmox VE

In the **Proxmox host's** shell (Datacenter → your node → Shell):

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/proxmox.sh)"
```

It asks for your licence key, then offers **Defaults** or **Advanced** for the container (size,
storage, network). It creates a small Debian container with Docker in it and installs patch there.
Nothing is installed on the Proxmox host. Everything else is done in your browser afterwards.

## Any Debian or Ubuntu machine (VM, mini PC, Hyper-V guest)

As root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/drunetic/rivet-kit-install/main/install.sh)"
```

## TrueNAS SCALE

Use [`truenas.yaml`](truenas.yaml): the steps are at the top of the file.

## Windows Server

Run patch in a small Linux VM under Hyper-V, then use the Debian/Ubuntu line above inside it.
Docker does not run Linux containers natively on Windows Server.

1. Server Manager → Add roles → **Hyper-V** (restart when asked).
2. Download the Debian netinst ISO from debian.org (amd64).
3. Hyper-V Manager → New → Virtual Machine: Generation 2, 2048 MB memory (not dynamic), the
   default switch or an external switch on your LAN, a 32 GB disk, install from the ISO.
   Before starting: Settings → Security → Secure Boot template **Microsoft UEFI Certificate Authority**.
4. Install Debian: no desktop, tick **SSH server**.
5. Log in, `su -`, then run the Debian/Ubuntu line above.
6. Settings → Automatic Start Action → **Always start** so it comes back after a reboot.

## After installing

Open the address it prints (or scan its QR code on a phone). The first visit makes your account,
then offers remote access through a Cloudflare Tunnel, so phones can reach patch from anywhere.
Instance admins also get **Settings → Updates**, **Licence** and **Remote access** in the app. On
the server, `patchctl help` lists the same jobs for when the app cannot be reached.

## Licence

Proprietary. See [LICENSE](LICENSE). Use only with permission; no warranty.
