# Building the k3s Cluster

How the two-node cluster was built (October 2026), following the KubeCraft Kubernetes Homelab course and adapted for two nodes and host firewalls. IP addresses are shown as placeholders.

## Nodes

| Node | Role | Arch | OS |
|------|------|------|----|
| srv1 | server (control plane) | amd64 | Ubuntu Server 26.04 LTS |
| ubuntusrvpi | agent (worker) | arm64 | Ubuntu Server 24.04 LTS |

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

# ubuntusrvpi
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
ubuntusrvpi   Ready    <none>          v1.36.5+k3s1   Ubuntu 24.04.5 LTS   6.8.0-1065-raspi (arm64)   containerd://2.3.4-k3s1.36
```

The bundled system pods (CoreDNS, Traefik, local-path-provisioner, metrics-server) run on srv1, and a ServiceLB pod runs on each node, which confirms scheduling and networking work across both.

## Lessons learned

- A literal `<token>` placeholder in a shell command is read as input redirection (`-bash: token: No such file or directory`). Put secrets in a variable instead.
- The node token and `k3s.yaml` are credentials. Neither belongs in Git.
- With two network interfaces on the same subnet, k3s may pick the wrong node IP. One wired interface (or `--node-ip` and `--flannel-iface`) avoids that.
