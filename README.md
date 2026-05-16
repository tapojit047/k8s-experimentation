# k8s-experimentation

## Bootstrap Kubernetes on Chameleon bare metal

From the Chameleon bare-metal machine:

```bash
chmod +x bootstrap-k8s-chameleon.sh
./bootstrap-k8s-chameleon.sh
```

The script creates a single-node kubeadm cluster with containerd and Flannel. If you set a custom `POD_CIDR`, it patches the default Flannel manifest to match.
It writes a worker join command to `join-command.sh`; that file is ignored by git because it contains a kubeadm token.

Do not set `POD_CIDR` to the Chameleon private subnet. The Pod network must not overlap the node network. CIDR overrides should be bare values like `10.96.0.0/12`, not bracketed lists like `[10.96.0.0/12]`.

Useful overrides:

```bash
NODE_IP=10.52.0.8 ./bootstrap-k8s-chameleon.sh
CONTROL_PLANE_ENDPOINT=<floating-ip>:6443 ./bootstrap-k8s-chameleon.sh
K8S_MINOR=v1.36 ./bootstrap-k8s-chameleon.sh
./bootstrap-k8s-chameleon.sh --skip-firewall
```

## Create virtual clusters inside the host cluster

This repo uses [vCluster](https://www.vcluster.com/) for virtual Kubernetes clusters.
By default, each virtual cluster gets its own Kubernetes API server and host
namespace, while workloads still run on the same Chameleon host cluster nodes.

Create three virtual clusters:

```bash
./create-vclusters.sh --count 3
```

If `participant-1` and `participant-2` already exist, the helper automatically
starts the next generated names at `participant-3` unless you pass
`--start-index`.

Create virtual clusters and immediately install OaaS-IoT into the ones just
created:

```bash
./create-vclusters.sh --count 3 --install-oaas
```

Create named virtual clusters:

```bash
./create-vclusters.sh --names dev,staging,prod
```

Run a command inside one virtual cluster without switching your host context:

```bash
vcluster connect participant-1 --namespace participant-1 -- kubectl get namespaces
```

Open a shell scoped to one virtual cluster:

```bash
vcluster connect participant-1 --namespace participant-1 -- bash
```

Back on the host cluster, see the vCluster control-plane Pods:

```bash
kubectl get pods --all-namespaces | grep vcluster
```

Delete a virtual cluster:

```bash
vcluster delete participant-1 --namespace participant-1
```

### If `vcluster connect` hangs

On this bare-metal kubeadm cluster there may be no default `StorageClass`. If a
vCluster was created with PVC-backed storage, its control-plane Pod can stay
`Pending`, and `vcluster connect ... -- kubectl ...` will wait for the virtual
API server forever.

Check it from the host cluster:

```bash
kubectl get pods,pvc -n participant-1
kubectl get events -n participant-1 --sort-by=.lastTimestamp
kubectl get storageclass
```

This helper defaults to ephemeral vCluster control-plane storage so new virtual
clusters do not need PVCs. To recreate stuck clusters:

```bash
for n in 1 2 3; do
  vcluster delete participant-$n --namespace participant-$n --ignore-not-found
  kubectl delete namespace participant-$n --ignore-not-found
done

./create-vclusters.sh --count 3
```

Install a simple local-path dynamic provisioner on the host cluster:

```bash
./install-local-path-storage.sh
kubectl get storageclass,pvc -A
```

This marks `local-path` as the default `StorageClass`. vCluster PVCs are synced
back to the host cluster, so workloads inside each participant can then create
PVCs normally. On a single Chameleon bare-metal node, the backing data lives on
that node under `/opt/local-path-provisioner` by default.

Use `./create-vclusters.sh --persistent` after installing a default
`StorageClass` if you also want the vCluster control planes themselves to use
PVC-backed storage.

## Install OaaS-IoT into each participant vCluster

OaaS-IoT uses Helm charts, so install Helm on the Chameleon machine first:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Then install OaaS-IoT into `participant-1`, `participant-2`, and `participant-3`:

```bash
./install-oaas-into-vclusters.sh install --count 3
```

By default the helper uses PM memory storage, which avoids PVCs and is easiest
for short experiments. After `./install-local-path-storage.sh` is installed, you
can use OaaS PM's embedded etcd with persistent storage:

```bash
./install-oaas-into-vclusters.sh install --count 3 --pm-storage etcd
```

The helper installs one OaaS CRM per participant by default to keep the lab
lightweight. It skips the compiler service by default. To include the compiler:

```bash
./install-oaas-into-vclusters.sh install --count 3 --compiler
```

Check all participant installs:

```bash
./install-oaas-into-vclusters.sh status --count 3
```

Check one participant directly:

```bash
vcluster connect participant-1 --namespace participant-1 -- kubectl get pods -A
```

Access the PM API in one participant with port-forwarding:

```bash
vcluster connect participant-1 --namespace participant-1 -- \
  kubectl -n oaas port-forward svc/oaas-pm-oprc-pm 8080:8080
```

Then from another terminal on the same machine:

```bash
curl http://localhost:8080/health
```

Remove OaaS-IoT from each participant:

```bash
./install-oaas-into-vclusters.sh uninstall --count 3 --purge-namespaces
```
