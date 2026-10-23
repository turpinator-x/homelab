# Building the k3s Cluster

How the two-node cluster was built (October 2026), following the KubeCraft Kubernetes Homelab course and adapted for two nodes and host firewalls. IP addresses are shown as placeholders.

## Nodes

| Node | Role | Arch | OS |
|------|------|------|----|
| srv1 | server (control plane) | amd64 | Ubuntu Server 26.04 LTS |
| srvpi01 (was ubuntusrvpi) | agent (worker) | arm64 | Ubuntu Server 24.04 LTS |

## 1. Prepare the hosts

- Updated both machines (`apt update && apt upgrade`).
- Put srv1 on its wired link only: removed the WiFi section from netplan and blacklisted the WiFi driver, so k3s can't register the node on the wrong interface.
- Checked that cgroup v2 with the memory controller is enabled (`cat /sys/fs/cgroup/cgroup.controllers`). Ubuntu's Raspberry Pi kernel already enables it, so the `cgroup_enable=memory` boot parameter from Raspberry Pi OS guides wasn't needed.

## 2. Install the server on srv1

```bash
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="--disable=helm-controller" sh -
sudo systemctl status k3s
```

The installer adds `kubectl` and `crictl` symlinks and `k3s-uninstall.sh`. (Note: k3s still ran its bundled Helm install jobs for Traefik, so this `--disable` value appears to be ignored; the dedicated flag is `--disable-helm-controller`. Flux uses its own HelmRelease resources, so the two don't conflict.)

## 3. Open only the ports the cluster needs (ufw)

```bash
# srv1
sudo ufw allow from <lan-cidr> to any port 6443 proto tcp       # API server: kubectl + agents joining
sudo ufw allow from <pi-ip> to any port 10250 proto tcp         # kubelet
sudo ufw allow from <pi-ip> to any port 8472 proto udp          # Flannel VXLAN
sudo ufw allow from 10.42.0.0/16 to any                         # pod network
sudo ufw allow from 10.43.0.0/16 to any                         # service network
sudo ufw allow from <pi-ip> to any port 9100 proto tcp          # node-exporter (added for monitoring)

# srvpi01
sudo ufw allow from <srv1-ip> to any port 10250 proto tcp
sudo ufw allow from <srv1-ip> to any port 8472 proto udp
sudo ufw allow from 10.42.0.0/16 to any
sudo ufw allow from 10.43.0.0/16 to any
sudo ufw allow from <srv1-ip> to any port 9100 proto tcp
```

Pods reaching the *other node's* IP (for example Prometheus scraping node-exporter, which runs on the host network) arrive with the sending node's address, not a pod address, so they need a node-to-node rule like the kubelet's.

## 4. Join the Pi as an agent

```bash
sudo cat /var/lib/rancher/k3s/server/node-token        # on srv1 (a secret: never commit it)

TOKEN='<node token>'                                   # on the Pi
curl -sfL https://get.k3s.io | sudo K3S_URL=https://<srv1-ip>:6443 K3S_TOKEN="$TOKEN" sh -
sudo systemctl status k3s-agent
```

## 5. Manage the cluster from the workstation

The workstation already had a kubeconfig for Rancher Desktop, so the homelab config was merged in as a second context instead of replacing it:

```bash
# on srv1: readable copy of the admin kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/k3s.yaml && sudo chown $USER ~/k3s.yaml

# on the workstation
scp srv1:k3s.yaml ~/.kube/homelab.yaml && ssh srv1 rm k3s.yaml
sed -i 's#https://127.0.0.1:6443#https://<srv1-ip>:6443#; s/: default$/: homelab/' ~/.kube/homelab.yaml
cp ~/.kube/config ~/.kube/config.bak
KUBECONFIG=~/.kube/config:~/.kube/homelab.yaml kubectl config view --flatten > /tmp/kc && mv /tmp/kc ~/.kube/config
chmod 600 ~/.kube/config ~/.kube/homelab.yaml

kubectl config use-context homelab
kubectl get nodes -o wide
```

## Result

```
NAME          STATUS   ROLES           VERSION        OS-IMAGE             KERNEL-VERSION             CONTAINER-RUNTIME
srv1          Ready    control-plane   v1.36.5+k3s1   Ubuntu 26.04.1 LTS   7.0.0-38-generic (amd64)   containerd://2.3.4-k3s1.36
srvpi01   Ready    <none>          v1.36.5+k3s1   Ubuntu 24.04.5 LTS   6.8.0-1065-raspi (arm64)   containerd://2.3.4-k3s1.36
```

The bundled system pods (CoreDNS, Traefik, local-path-provisioner, metrics-server) run on srv1, and a ServiceLB pod runs on each node, which confirms scheduling and networking work across both.

## Lessons learned

- A literal `<token>` placeholder in a shell command is read as input redirection (`-bash: token: No such file or directory`). Put secrets in a variable instead.
- The node token and `k3s.yaml` are credentials. Neither belongs in Git.
- With two network interfaces on the same subnet, k3s may pick the wrong node IP. One wired interface (or `--node-ip` and `--flannel-iface`) avoids that.

## Maintenance log

### 2026-10-23: App volumes switched to Retain

**Why:** every app volume (Linkding's data, Audiobookshelf's config, metadata, audiobooks and podcasts) uses k3s's `local-path` class, whose reclaim policy is `Delete`: if a PersistentVolumeClaim is deleted, k3s deletes the folder on srv1 with it. Flux already can't prune these claims (`prune: disabled`), but a mistaken `kubectl delete pvc` or `kubectl delete namespace` would still wipe the data.

**Change:** each PersistentVolume was patched in place, with no restarts:

```bash
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

Linkding's volume went first and was checked, then the four Audiobookshelf volumes. All five now show `Retain` and `Bound`, and both apps kept running.

**What it means:** deleting a claim now leaves the PersistentVolume in a `Released` state with its data still on srv1. Getting it back means clearing the volume's old `claimRef` so a new claim can bind, or copying the folder out; cleaning up means deleting the PV and then the folder by hand. The PVs aren't in Git (k3s creates them), so Flux doesn't undo the patch. New claims still start as `Delete` until there is a `Retain` StorageClass.

**Still true:** the volumes are pinned to srv1, so these apps can't fail over to the Pi. That changes only with network or replicated storage (a Synology NAS over iSCSI, or Longhorn), which is on the roadmap.

### 2026-10-22: Pi WiFi stall, watchdog, and rename to srvpi01

**What happened:** the Pi went `NotReady` for about three hours. Its WiFi stopped passing traffic (k3s logged `connect: no route to host` to the server, and sysstat showed `wlan0` falling from about 1,500 to under 1 packet per second), but the interface never reported a disconnect, so nothing tried to reconnect. The OS kept running. Kubernetes rescheduled the Pi's pods (the cloudflared replicas, the Prometheus operator) onto srv1, and the public apps stayed up throughout. A power cycle brought it back.

**Fix (until it can be wired):** WiFi power saving was on, a common cause of stalls with the Pi's built-in WiFi. A small watchdog now runs every minute from a systemd timer (`/usr/local/sbin/wifi-watchdog`, `wifi-watchdog.service` + `.timer`):

1. turns power saving off (it doesn't persist across reboots or reconnects);
2. pings the default gateway;
3. on failure, recovers in steps: restart the WiFi supplicant at about 2 minutes, reload the `brcmfmac` driver at about 4 minutes, reboot at about 10 minutes (only if up for more than an hour, so a router outage can't cause a reboot loop).

Everything it does is logged: `journalctl -t wifi-watchdog`. The real fix is Ethernet, which is on the roadmap.

**Rename:** `ubuntusrvpi` became `srvpi01` (numbered, in case more Pis join as control planes later). Steps: drain the node, set the hostname in **both** `/etc/hostname` (`hostnamectl`) and the cloud-init seed on the boot partition (`/boot/firmware/user-data`, which otherwise rewrites `/etc/hosts` with the old name on every boot), add `preserve_hostname: true`, reboot. k3s registered the Pi as a new node `srvpi01`; the old node object and its `ubuntusrvpi.node-password.k3s` secret were deleted.

**Also noticed:** ufw logs IPv6 router solicitations between pods on the `cni0` bridge as `[UFW BLOCK]` (about 27,000 lines in one boot). Harmless, but noisy on an SD card; to be cleaned up.

