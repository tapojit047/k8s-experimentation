#!/usr/bin/env bash
set -Eeuo pipefail

# Install a simple dynamic local PersistentVolume provisioner for single-node
# kubeadm clusters. This is useful on Chameleon bare metal, where there is
# often no cloud StorageClass available.

SCRIPT_NAME="$(basename "$0")"

NAMESPACE="${NAMESPACE:-local-path-storage}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"
LOCAL_PATH="${LOCAL_PATH:-/opt/local-path-provisioner}"
SET_DEFAULT="${SET_DEFAULT:-true}"
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml}"

usage() {
  cat <<EOF_HELP
Usage:
  ./${SCRIPT_NAME} [options]

Installs Rancher local-path-provisioner into the host Kubernetes cluster and,
by default, marks its StorageClass as the cluster default. vCluster PVCs then
sync to the host cluster and can bind dynamically.

Options:
  --namespace NAME
      Namespace for the provisioner. Default: ${NAMESPACE}.

  --storage-class NAME
      StorageClass name to create/use. Default: ${STORAGE_CLASS}.

  --path PATH
      Host directory used for local PV data. Default: ${LOCAL_PATH}.

  --no-default
      Install the StorageClass but do not mark it as default.

  --manifest-url URL
      local-path-provisioner manifest URL. Default: ${MANIFEST_URL}.

  --help
      Show this help.

Examples:
  ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} --path /mnt/local-path-provisioner
EOF_HELP
}

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  printf '\n[error] %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

as_bool() {
  case "${1,,}" in
    true|yes|y|1|on) return 0 ;;
    false|no|n|0|off) return 1 ;;
    *) die "Invalid boolean value: $1" ;;
  esac
}

parse_args() {
  while (($#)); do
    case "$1" in
      --namespace)
        [[ $# -ge 2 ]] || die "--namespace requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --storage-class)
        [[ $# -ge 2 ]] || die "--storage-class requires a value"
        STORAGE_CLASS="$2"
        shift 2
        ;;
      --path)
        [[ $# -ge 2 ]] || die "--path requires a value"
        LOCAL_PATH="$2"
        shift 2
        ;;
      --no-default)
        SET_DEFAULT=false
        shift
        ;;
      --manifest-url)
        [[ $# -ge 2 ]] || die "--manifest-url requires a value"
        MANIFEST_URL="$2"
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

install_provisioner() {
  local manifest
  manifest="$(mktemp)"
  trap '[[ -n "${manifest:-}" ]] && rm -f "${manifest}"' EXIT

  log "Downloading local-path-provisioner manifest"
  curl -fsSL "${MANIFEST_URL}" -o "${manifest}"
  sed -i "s/local-path-storage/${NAMESPACE}/g" "${manifest}"

  log "Applying local-path-provisioner"
  kubectl apply -f "${manifest}"

  log "Configuring local PV path ${LOCAL_PATH}"
  kubectl -n "${NAMESPACE}" patch configmap local-path-config --type merge -p "$(cat <<EOF_CONFIG
{
  "data": {
    "config.json": "{\n  \"nodePathMap\": [\n    {\n      \"node\": \"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\n      \"paths\": [\"${LOCAL_PATH}\"]\n    }\n  ]\n}"
  }
}
EOF_CONFIG
)"

  log "Configuring StorageClass ${STORAGE_CLASS}"
  kubectl apply -f - <<EOF_SC
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF_SC

  if as_bool "${SET_DEFAULT}"; then
    log "Marking ${STORAGE_CLASS} as the default StorageClass"
    local sc
    while read -r sc; do
      [[ -n "${sc}" && "${sc}" != "${STORAGE_CLASS}" ]] || continue
      kubectl annotate storageclass "${sc}" storageclass.kubernetes.io/is-default-class- --overwrite >/dev/null || true
    done < <(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

    kubectl annotate storageclass "${STORAGE_CLASS}" storageclass.kubernetes.io/is-default-class=true --overwrite
  fi

  log "Waiting for provisioner deployment"
  kubectl -n "${NAMESPACE}" rollout status deploy/local-path-provisioner --timeout=2m

  log "StorageClasses"
  kubectl get storageclass
}

main() {
  parse_args "$@"
  need_cmd curl
  need_cmd kubectl

  kubectl cluster-info >/dev/null
  install_provisioner

  cat <<EOF_NEXT

Done. Existing Pending PVCs may bind automatically after the default
StorageClass appears. If an old vCluster PVC stays Pending, recreate that
workload/release so Kubernetes creates a fresh PVC.

Check host PVCs:
  kubectl get pvc -A
EOF_NEXT
}

main "$@"
