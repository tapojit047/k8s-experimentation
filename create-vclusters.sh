#!/usr/bin/env bash
set -Eeuo pipefail

# Create multiple vCluster virtual Kubernetes clusters inside the current host cluster.
# Run this after bootstrap-k8s-chameleon.sh has produced a working kubectl context.

COUNT="${COUNT:-2}"
PREFIX="${PREFIX:-participant}"
START_INDEX="${START_INDEX:-}"
NAMES_CSV="${NAMES:-}"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-}"
INSTALL_VCLUSTER_CLI="${INSTALL_VCLUSTER_CLI:-true}"
CONNECT_AFTER_CREATE="${CONNECT_AFTER_CREATE:-false}"
DRIVER="${DRIVER:-helm}"
VCLUSTER_REPO="${VCLUSTER_REPO:-https://charts.loft.sh}"
PERSISTENCE="${PERSISTENCE:-false}"
INSTALL_OAAS="${INSTALL_OAAS:-false}"
OAAS_INSTALL_SCRIPT="${OAAS_INSTALL_SCRIPT:-$(dirname "$0")/install-oaas-into-vclusters.sh}"

VCLUSTER_EXTRA_ARGS=()

usage() {
  cat <<EOF_HELP
Usage:
  ./create-vclusters.sh [options] [-- extra vcluster create args]

Creates multiple virtual Kubernetes clusters in the current host Kubernetes
cluster using vCluster. Each virtual cluster gets its own host namespace.

Options:
  --count N
      Number of virtual clusters to create. Default: ${COUNT}.

  --prefix NAME
      Name prefix when --names is not used. Default: ${PREFIX}.
      Example with --count 3: participant-1, participant-2, participant-3.

  --start-index N
      First numeric suffix for generated names. By default, this is one after
      the highest existing ${PREFIX}-N vCluster namespace, or 1 if none exist.

  --names a,b,c
      Explicit comma-separated virtual cluster names. Overrides --count.

  --namespace-prefix PREFIX
      Optional prefix for host namespaces. By default namespace == vCluster name.
      Example: --namespace-prefix vc- creates namespaces vc-participant-1, vc-participant-2.

  --no-install-cli
      Require vcluster to already be installed instead of downloading it.

  --connect-after-create
      Let vcluster connect to each virtual cluster after creating it. Default is
      false so your host kube context stays stable.

  --driver DRIVER
      vCluster driver to use. Default: ${DRIVER}.

  --repo URL
      vCluster Helm chart repo. Default: ${VCLUSTER_REPO}.

  --persistent
      Use vCluster PVC-backed control-plane storage. Requires a StorageClass or matching PersistentVolume.

  --ephemeral
      Disable vCluster control-plane PVCs. This is the default for this Chameleon helper.

  --install-oaas
      Install OaaS-IoT into the created vClusters after creation by running
      ${OAAS_INSTALL_SCRIPT}.

  --no-install-oaas
      Do not install OaaS-IoT after creating vClusters. This is the default.

  --help
      Show this help.

Examples:
  ./create-vclusters.sh --count 3
  ./create-vclusters.sh --count 3 --install-oaas
  ./create-vclusters.sh --names dev,staging,prod
  ./create-vclusters.sh --count 2 -- --set controlPlane.resources.requests.cpu=100m

Connect to a virtual cluster after creation:
  vcluster connect participant-1 --namespace participant-1 -- kubectl get namespaces
  vcluster connect participant-1 --namespace participant-1 -- bash
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
      --count)
        [[ $# -ge 2 ]] || die "--count requires a value"
        COUNT="$2"
        shift 2
        ;;
      --prefix)
        [[ $# -ge 2 ]] || die "--prefix requires a value"
        PREFIX="$2"
        shift 2
        ;;
      --start-index)
        [[ $# -ge 2 ]] || die "--start-index requires a value"
        START_INDEX="$2"
        shift 2
        ;;
      --names)
        [[ $# -ge 2 ]] || die "--names requires a value"
        NAMES_CSV="$2"
        shift 2
        ;;
      --namespace-prefix)
        [[ $# -ge 2 ]] || die "--namespace-prefix requires a value"
        NAMESPACE_PREFIX="$2"
        shift 2
        ;;
      --no-install-cli)
        INSTALL_VCLUSTER_CLI=false
        shift
        ;;
      --connect-after-create)
        CONNECT_AFTER_CREATE=true
        shift
        ;;
      --driver)
        [[ $# -ge 2 ]] || die "--driver requires a value"
        DRIVER="$2"
        shift 2
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a value"
        VCLUSTER_REPO="$2"
        shift 2
        ;;
      --persistent)
        PERSISTENCE=true
        shift
        ;;
      --ephemeral)
        PERSISTENCE=false
        shift
        ;;
      --install-oaas)
        INSTALL_OAAS=true
        shift
        ;;
      --no-install-oaas)
        INSTALL_OAAS=false
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        VCLUSTER_EXTRA_ARGS+=("$@")
        break
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

validate_dns_label() {
  local kind="$1"
  local value="$2"

  [[ ${#value} -le 63 ]] || die "${kind} '${value}' is longer than 63 characters"
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    die "${kind} '${value}' must be a DNS label: lowercase letters, digits, and hyphens only"
  fi
}

install_vcluster_cli() {
  if command -v vcluster >/dev/null 2>&1; then
    return
  fi

  if ! as_bool "${INSTALL_VCLUSTER_CLI}"; then
    die "vcluster CLI is not installed. Install it or rerun without --no-install-cli."
  fi

  need_cmd curl
  need_cmd install
  need_cmd uname

  local arch tmp install_dir
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Unsupported CPU architecture for automatic vcluster install: $(uname -m)" ;;
  esac

  log "Installing vcluster CLI"
  tmp="$(mktemp)"
  curl -fsSL "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-${arch}" -o "${tmp}"

  if [[ "${EUID}" -eq 0 ]]; then
    install -c -m 0755 "${tmp}" /usr/local/bin/vcluster
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -c -m 0755 "${tmp}" /usr/local/bin/vcluster
  else
    install_dir="${HOME}/.local/bin"
    mkdir -p "${install_dir}"
    install -c -m 0755 "${tmp}" "${install_dir}/vcluster"
    warn "Installed vcluster to ${install_dir}. Add it to PATH if your shell cannot find it."
  fi

  rm -f "${tmp}"
}

check_host_cluster() {
  need_cmd kubectl
  kubectl cluster-info >/dev/null
  kubectl auth can-i create namespaces >/dev/null || die "Current kubectl user cannot create namespaces in the host cluster"
}

has_default_storageclass() {
  kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | grep -q .
}

next_available_start_index() {
  local max=0
  local ns suffix

  while IFS= read -r ns; do
    if [[ -n "${NAMESPACE_PREFIX}" ]]; then
      [[ "${ns}" == "${NAMESPACE_PREFIX}${PREFIX}-"* ]] || continue
      suffix="${ns#"${NAMESPACE_PREFIX}${PREFIX}-"}"
    else
      [[ "${ns}" == "${PREFIX}-"* ]] || continue
      suffix="${ns#"${PREFIX}-"}"
    fi

    if [[ "${suffix}" =~ ^[0-9]+$ && "${suffix}" -gt "${max}" ]]; then
      max="${suffix}"
    fi
  done < <(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

  printf '%s\n' "$((max + 1))"
}

build_names() {
  VCLUSTER_NAMES=()

  if [[ -n "${NAMES_CSV}" ]]; then
    local raw name
    IFS=',' read -r -a raw <<<"${NAMES_CSV}"
    for name in "${raw[@]}"; do
      name="${name//[[:space:]]/}"
      [[ -n "${name}" ]] || continue
      validate_dns_label "vCluster name" "${name}"
      VCLUSTER_NAMES+=("${name}")
    done
    [[ ${#VCLUSTER_NAMES[@]} -gt 0 ]] || die "--names did not contain any valid names"
    return
  fi

  [[ "${COUNT}" =~ ^[0-9]+$ ]] || die "--count must be a positive integer"
  if [[ -z "${START_INDEX}" ]]; then
    START_INDEX="$(next_available_start_index)"
  fi
  [[ "${START_INDEX}" =~ ^[0-9]+$ ]] || die "--start-index must be a positive integer"
  [[ "${COUNT}" -gt 0 ]] || die "--count must be greater than zero"

  local i name last
  last=$((START_INDEX + COUNT - 1))
  for ((i = START_INDEX; i <= last; i++)); do
    name="${PREFIX}-${i}"
    validate_dns_label "vCluster name" "${name}"
    VCLUSTER_NAMES+=("${name}")
  done
}

create_one_vcluster() {
  local name="$1"
  local namespace="${NAMESPACE_PREFIX}${name}"

  validate_dns_label "namespace" "${namespace}"

  log "Creating vCluster ${name} in host namespace ${namespace}"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -

  local args=(
    create "${name}"
    --namespace "${namespace}"
    --create-namespace
    --upgrade
    --driver "${DRIVER}"
    --chart-repo "${VCLUSTER_REPO}"
    --connect=false
  )

  if as_bool "${CONNECT_AFTER_CREATE}"; then
    args=(
      create "${name}"
      --namespace "${namespace}"
      --create-namespace
      --upgrade
      --driver "${DRIVER}"
      --chart-repo "${VCLUSTER_REPO}"
      --connect=true
    )
  fi

  if ! as_bool "${PERSISTENCE}"; then
    args+=(--set controlPlane.statefulSet.persistence.volumeClaim.enabled=false)
  fi

  vcluster "${args[@]}" "${VCLUSTER_EXTRA_ARGS[@]}"
}

install_oaas_into_created_vclusters() {
  as_bool "${INSTALL_OAAS}" || return

  [[ -x "${OAAS_INSTALL_SCRIPT}" ]] || die "OaaS installer not found or not executable: ${OAAS_INSTALL_SCRIPT}"

  local names_csv
  names_csv="$(IFS=,; printf '%s' "${VCLUSTER_NAMES[*]}")"

  log "Installing OaaS-IoT into created vClusters"
  "${OAAS_INSTALL_SCRIPT}" install \
    --names "${names_csv}" \
    --vcluster-namespace-prefix "${NAMESPACE_PREFIX}"
}

print_next_steps() {
  cat <<EOF_NEXT

Created ${#VCLUSTER_NAMES[@]} virtual cluster(s).

Host cluster view:
  kubectl get pods --all-namespaces | grep vcluster

Connect examples:
EOF_NEXT

  local name namespace
  for name in "${VCLUSTER_NAMES[@]}"; do
    namespace="${NAMESPACE_PREFIX}${name}"
    printf '  vcluster connect %s --namespace %s -- kubectl get namespaces\n' "${name}" "${namespace}"
    printf '  vcluster connect %s --namespace %s -- bash\n' "${name}" "${namespace}"
  done

  cat <<EOF_NEXT

Delete example:
  vcluster delete ${VCLUSTER_NAMES[0]} --namespace ${NAMESPACE_PREFIX}${VCLUSTER_NAMES[0]}
EOF_NEXT
}

main() {
  parse_args "$@"
  install_vcluster_cli
  check_host_cluster
  build_names

  log "Using host context: $(kubectl config current-context)"
  log "Creating ${#VCLUSTER_NAMES[@]} virtual cluster(s)"
  if as_bool "${PERSISTENCE}"; then
    if ! has_default_storageclass; then
      die "--persistent needs a default StorageClass. Run ./install-local-path-storage.sh first, or pass vCluster storage settings after --."
    fi
    log "Using persistent vCluster control-plane storage"
  elif has_default_storageclass; then
    log "Using ephemeral vCluster control-plane storage. Pass --persistent to store vCluster control planes on PVCs."
  else
    log "Using ephemeral vCluster control-plane storage. Run ./install-local-path-storage.sh before creating PVC-backed workloads."
  fi

  local name
  for name in "${VCLUSTER_NAMES[@]}"; do
    create_one_vcluster "${name}"
  done

  install_oaas_into_created_vclusters
  print_next_steps
}

main "$@"
