#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a kubeadm Kubernetes cluster on a Chameleon Cloud bare-metal host.
# Target OS: Ubuntu/Debian images with systemd and apt.

SCRIPT_NAME="$(basename "$0")"
ORIG_PWD="${ORIG_PWD:-$PWD}"

K8S_MINOR="${K8S_MINOR:-}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
NODE_IP="${NODE_IP:-}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
APISERVER_CERT_EXTRA_SANS="${APISERVER_CERT_EXTRA_SANS:-}"
CNI="${CNI:-flannel}"
CNI_MANIFEST_URL_WAS_SET="${CNI_MANIFEST_URL+x}"
CNI_MANIFEST_URL="${CNI_MANIFEST_URL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"
ALLOW_SCHEDULE_ON_CONTROL_PLANE="${ALLOW_SCHEDULE_ON_CONTROL_PLANE:-true}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-auto}"
JOIN_COMMAND_PATH="${JOIN_COMMAND_PATH:-${ORIG_PWD}/join-command.sh}"
KUBE_USER="${KUBE_USER:-${SUDO_USER:-${USER:-}}}"

usage() {
  cat <<EOF_HELP
Usage:
  ./${SCRIPT_NAME} [options]

Creates a single-control-plane Kubernetes cluster on this Chameleon bare-metal
machine using containerd, kubeadm, kubectl, and Flannel.

Options:
  --node-ip IP
      Node/control-plane advertise IP. Defaults to the source IP used for the
      default route.

  --control-plane-endpoint HOST[:PORT]
      Optional stable API endpoint, such as a Chameleon floating IP/DNS name.
      Useful if you will add nodes later or use kubectl from outside the host.

  --pod-cidr CIDR
      Pod network CIDR. Default: ${POD_CIDR}. The default Flannel manifest is
      patched automatically when this value is not 10.244.0.0/16.

  --service-cidr CIDR
      Kubernetes service CIDR. Default: ${SERVICE_CIDR}.

  --k8s-minor vX.Y
      Kubernetes minor repo to install, for example v1.36. If omitted, the
      script reads https://dl.k8s.io/release/stable.txt and uses its minor.

  --cni-manifest-url URL
      CNI manifest to apply. Default: Flannel latest release manifest.

  --no-control-plane-workloads
      Keep the default control-plane taint, so normal Pods do not schedule on
      this single node.

  --configure-firewall
      If firewalld is active, open Kubernetes and Flannel ports. Default: auto.

  --skip-firewall
      Do not modify firewalld even if it is active.

  --join-command-path PATH
      Where to write a worker join command. Default: ${JOIN_COMMAND_PATH}.

  --help
      Show this help.

Environment variables with the same uppercase names can also be used.

Examples:
  ./${SCRIPT_NAME}
  CONTROL_PLANE_ENDPOINT=203.0.113.10:6443 ./${SCRIPT_NAME}
  NODE_IP=10.52.0.8 K8S_MINOR=v1.36 ./${SCRIPT_NAME}
EOF_HELP
}

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

warn() {
  printf '\n[warn] %s\n' "$*" >&2
}

die() {
  printf '\n[error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --node-ip)
        [[ $# -ge 2 ]] || die "--node-ip requires a value"
        NODE_IP="$2"
        shift 2
        ;;
      --control-plane-endpoint)
        [[ $# -ge 2 ]] || die "--control-plane-endpoint requires a value"
        CONTROL_PLANE_ENDPOINT="$2"
        shift 2
        ;;
      --pod-cidr)
        [[ $# -ge 2 ]] || die "--pod-cidr requires a value"
        POD_CIDR="$2"
        shift 2
        ;;
      --service-cidr)
        [[ $# -ge 2 ]] || die "--service-cidr requires a value"
        SERVICE_CIDR="$2"
        shift 2
        ;;
      --k8s-minor)
        [[ $# -ge 2 ]] || die "--k8s-minor requires a value"
        K8S_MINOR="$2"
        shift 2
        ;;
      --cni-manifest-url)
        [[ $# -ge 2 ]] || die "--cni-manifest-url requires a value"
        CNI_MANIFEST_URL="$2"
        CNI_MANIFEST_URL_WAS_SET=1
        shift 2
        ;;
      --no-control-plane-workloads)
        ALLOW_SCHEDULE_ON_CONTROL_PLANE=false
        shift
        ;;
      --configure-firewall)
        CONFIGURE_FIREWALL=true
        shift
        ;;
      --skip-firewall)
        CONFIGURE_FIREWALL=false
        shift
        ;;
      --join-command-path)
        [[ $# -ge 2 ]] || die "--join-command-path requires a value"
        JOIN_COMMAND_PATH="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

as_bool() {
  case "${1,,}" in
    true|yes|y|1|on) return 0 ;;
    false|no|n|0|off) return 1 ;;
    *) die "Invalid boolean value: $1" ;;
  esac
}

normalize_cidr_var() {
  local name="$1"
  local value="${!name}"
  local normalized

  normalized="$(printf '%s' "${value}" | tr -d '[:space:]')"
  if [[ "${normalized}" == \[*\] ]]; then
    normalized="${normalized#\[}"
    normalized="${normalized%\]}"
  fi

  [[ -n "${normalized}" ]] || die "${name} cannot be empty"
  if [[ ! "${normalized}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    die "${name} must be an IPv4 CIDR like 10.244.0.0/16, got: ${value}"
  fi

  printf -v "${name}" '%s' "${normalized}"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E env ORIG_PWD="$PWD" bash "$0" "$@"
  fi
}

detect_node_ip() {
  if [[ -n "${NODE_IP}" ]]; then
    return
  fi

  NODE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
  [[ -n "${NODE_IP}" ]] || die "Could not detect NODE_IP. Re-run with --node-ip <IP>."
}

detect_k8s_minor() {
  if [[ -n "${K8S_MINOR}" ]]; then
    [[ "${K8S_MINOR}" =~ ^v[0-9]+\.[0-9]+$ ]] || die "K8S_MINOR must look like v1.36, got: ${K8S_MINOR}"
    return
  fi

  local stable
  stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  K8S_MINOR="$(sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/' <<<"${stable}")"
  [[ "${K8S_MINOR}" =~ ^v[0-9]+\.[0-9]+$ ]] || die "Could not derive Kubernetes minor from stable release: ${stable}"
}

check_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing; this script expects Ubuntu/Debian."
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID_LIKE:-} ${ID:-}" in
    *debian*|*ubuntu*) ;;
    *) die "Unsupported OS '${PRETTY_NAME:-unknown}'. This script expects Ubuntu/Debian with apt." ;;
  esac

  need_cmd apt-get
  need_cmd systemctl
  need_cmd awk
  need_cmd sed
}

install_base_packages() {
  log "Installing base packages"
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gpg iproute2
}

configure_kernel() {
  log "Configuring kernel modules and sysctl settings"

  cat >/etc/modules-load.d/k8s.conf <<'EOF_MODULES'
overlay
br_netfilter
EOF_MODULES

  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF_SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF_SYSCTL

  sysctl --system >/dev/null
}

configure_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld; then
    return
  fi

  case "${CONFIGURE_FIREWALL,,}" in
    false|no|n|0|off)
      warn "firewalld is active; leaving it unchanged because CONFIGURE_FIREWALL=${CONFIGURE_FIREWALL}"
      return
      ;;
    true|yes|y|1|on|auto) ;;
    *) die "Invalid CONFIGURE_FIREWALL value: ${CONFIGURE_FIREWALL}" ;;
  esac

  log "Opening Kubernetes ports in firewalld"
  local ports=(6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp)
  if [[ "${CNI}" == "flannel" ]]; then
    ports+=(8472/udp)
  fi

  local port
  for port in "${ports[@]}"; do
    firewall-cmd --permanent --add-port="${port}"
  done
  firewall-cmd --permanent --add-masquerade
  firewall-cmd --reload
}

disable_swap() {
  log "Disabling swap"

  swapoff -a || true

  if grep -Eq '^[^#].+[[:space:]]swap[[:space:]]' /etc/fstab; then
    local backup="/etc/fstab.pre-k8s.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "${backup}"
    sed -ri '/^[^#].+[[:space:]]swap[[:space:]]/s/^/# k8s disabled swap /' /etc/fstab
    log "Backed up /etc/fstab to ${backup}"
  fi
}

install_containerd() {
  log "Installing and configuring containerd"

  apt-get install -y containerd
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml

  if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
  elif ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    cat >>/etc/containerd/config.toml <<'EOF_CONTAINERD'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF_CONTAINERD
  fi

  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart containerd
}

install_kubernetes_packages() {
  detect_k8s_minor
  log "Installing Kubernetes packages from ${K8S_MINOR}"

  mkdir -p -m 755 /etc/apt/keyrings
  local key_tmp
  key_tmp="$(mktemp)"
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" -o "${key_tmp}"
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${key_tmp}"
  rm -f "${key_tmp}"

  cat >/etc/apt/sources.list.d/kubernetes.list <<EOF_APT
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF_APT

  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl

  cat >/etc/default/kubelet <<EOF_KUBELET
KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}
EOF_KUBELET

  systemctl daemon-reload
  systemctl enable --now kubelet || true
}

build_sans_arg() {
  local sans=("${NODE_IP}")

  if [[ -n "${CONTROL_PLANE_ENDPOINT}" ]]; then
    sans+=("${CONTROL_PLANE_ENDPOINT%%:*}")
  fi

  if [[ -n "${APISERVER_CERT_EXTRA_SANS}" ]]; then
    IFS=',' read -r -a extra_sans <<<"${APISERVER_CERT_EXTRA_SANS}"
    sans+=("${extra_sans[@]}")
  fi

  local joined
  joined="$(IFS=,; printf '%s' "${sans[*]}")"
  printf '%s' "${joined}"
}

init_cluster() {
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "Cluster already appears initialized; skipping kubeadm init"
    return
  fi

  log "Initializing Kubernetes control plane on ${NODE_IP}"

  local init_args=(
    --apiserver-advertise-address "${NODE_IP}"
    --apiserver-cert-extra-sans "$(build_sans_arg)"
    --pod-network-cidr "${POD_CIDR}"
    --service-cidr "${SERVICE_CIDR}"
    --cri-socket unix:///run/containerd/containerd.sock
  )

  if [[ -n "${CONTROL_PLANE_ENDPOINT}" ]]; then
    init_args+=(--control-plane-endpoint "${CONTROL_PLANE_ENDPOINT}")
  fi

  kubeadm init "${init_args[@]}"
}

configure_kubeconfig() {
  log "Configuring kubeconfig"

  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [[ -n "${KUBE_USER}" ]] && id "${KUBE_USER}" >/dev/null 2>&1; then
    local kube_home
    kube_home="$(getent passwd "${KUBE_USER}" | cut -d: -f6)"
    if [[ -n "${kube_home}" && -d "${kube_home}" ]]; then
      mkdir -p "${kube_home}/.kube"
      cp -f /etc/kubernetes/admin.conf "${kube_home}/.kube/config"
      chown -R "${KUBE_USER}:$(id -gn "${KUBE_USER}")" "${kube_home}/.kube"
      chmod 600 "${kube_home}/.kube/config"
      log "Wrote kubeconfig for ${KUBE_USER}: ${kube_home}/.kube/config"
    fi
  fi
}

install_cni() {
  if [[ "${CNI}" == "none" ]]; then
    warn "Skipping CNI install because CNI=none. CoreDNS will not become Ready until a CNI is installed."
    return
  fi

  if [[ "${CNI}" == "flannel" && "${POD_CIDR}" != "10.244.0.0/16" && -z "${CNI_MANIFEST_URL_WAS_SET}" ]]; then
    log "Installing Flannel with patched POD_CIDR=${POD_CIDR}"
    local manifest
    manifest="$(mktemp)"
    curl -fsSL "${CNI_MANIFEST_URL}" -o "${manifest}"
    sed -i "s#\"Network\": \"10.244.0.0/16\"#\"Network\": \"${POD_CIDR}\"#" "${manifest}"

    if ! grep -Fq "\"Network\": \"${POD_CIDR}\"" "${manifest}"; then
      rm -f "${manifest}"
      die "Could not patch Flannel manifest to use POD_CIDR=${POD_CIDR}. Re-run with --pod-cidr 10.244.0.0/16 or pass --cni-manifest-url for a matching manifest."
    fi

    kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f "${manifest}"
    rm -f "${manifest}"
    return
  fi

  log "Installing CNI from ${CNI_MANIFEST_URL}"
  kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f "${CNI_MANIFEST_URL}"
}

allow_single_node_workloads() {
  if as_bool "${ALLOW_SCHEDULE_ON_CONTROL_PLANE}"; then
    log "Allowing workloads on the control-plane node"
    kubectl --kubeconfig /etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- || true
  fi
}

write_join_command() {
  log "Writing worker join command to ${JOIN_COMMAND_PATH}"

  mkdir -p "$(dirname "${JOIN_COMMAND_PATH}")"
  kubeadm token create --print-join-command >"${JOIN_COMMAND_PATH}"
  chmod 600 "${JOIN_COMMAND_PATH}"

  if [[ -n "${KUBE_USER}" ]] && id "${KUBE_USER}" >/dev/null 2>&1; then
    chown "${KUBE_USER}:$(id -gn "${KUBE_USER}")" "${JOIN_COMMAND_PATH}" || true
  fi
}

wait_for_ready() {
  log "Waiting for node readiness"

  if kubectl --kubeconfig /etc/kubernetes/admin.conf wait --for=condition=Ready node --all --timeout=5m; then
    kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
    kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A
  else
    warn "Timed out waiting for all nodes to become Ready. Check 'kubectl get pods -A' and 'journalctl -u kubelet'."
  fi
}

main() {
  parse_args "$@"
  require_root "$@"
  check_os
  install_base_packages
  detect_node_ip

  normalize_cidr_var POD_CIDR
  normalize_cidr_var SERVICE_CIDR

  log "Using NODE_IP=${NODE_IP}"
  log "Using POD_CIDR=${POD_CIDR}"
  log "Using SERVICE_CIDR=${SERVICE_CIDR}"

  local node_a node_b node_c _ pod_network
  IFS=. read -r node_a node_b node_c _ <<<"${NODE_IP}"
  pod_network="${POD_CIDR%%/*}"
  if [[ "${pod_network}" == "${node_a}.${node_b}.${node_c}."* || "${POD_CIDR}" == "${node_a}.${node_b}.0.0/16" || "${POD_CIDR}" == "${node_a}.0.0.0/8" ]]; then
    die "POD_CIDR=${POD_CIDR} appears to overlap NODE_IP=${NODE_IP}. Unset POD_CIDR or use a separate range like 10.244.0.0/16."
  fi
  [[ -n "${CONTROL_PLANE_ENDPOINT}" ]] && log "Using CONTROL_PLANE_ENDPOINT=${CONTROL_PLANE_ENDPOINT}"

  configure_kernel
  configure_firewall
  disable_swap
  install_containerd
  install_kubernetes_packages
  init_cluster
  configure_kubeconfig
  install_cni
  allow_single_node_workloads
  write_join_command
  wait_for_ready

  log "Done. Try: kubectl get nodes -o wide"
}

main "$@"
