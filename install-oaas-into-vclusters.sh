#!/usr/bin/env bash
set -Eeuo pipefail

# Install OaaS-IoT into each participant vCluster.
# This runs kubectl/helm locally through `vcluster connect`, so installs land
# inside the virtual cluster rather than the host cluster.

ACTION="${ACTION:-install}"
COUNT="${COUNT:-3}"
PREFIX="${PREFIX:-participant}"
START_INDEX="${START_INDEX:-1}"
NAMES_CSV="${NAMES:-}"
VCLUSTER_NAMESPACE_PREFIX="${VCLUSTER_NAMESPACE_PREFIX:-}"
OAAS_DIR="${OAAS_DIR:-$(pwd)/OaaS-IoT}"

PM_NS="${PM_NS:-oaas}"
PM_RELEASE="${PM_RELEASE:-oaas-pm}"
CRM_COUNT="${CRM_COUNT:-1}"
CRM_NS_PREFIX="${CRM_NS_PREFIX:-oaas}"
CRM_RELEASE_PREFIX="${CRM_RELEASE_PREFIX:-oaas-crm}"
COMPILER_ENABLED="${COMPILER_ENABLED:-false}"
COMPILER_RELEASE="${COMPILER_RELEASE:-oaas-compiler}"
PM_STORAGE="${PM_STORAGE:-memory}"
PURGE_NAMESPACES="${PURGE_NAMESPACES:-false}"

REGISTRY_PREFIX="${REGISTRY_PREFIX:-}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

VCLUSTER_NAMES=()

usage() {
  cat <<EOF_HELP
Usage:
  ./install-oaas-into-vclusters.sh [install|status|uninstall] [options]

Installs OaaS-IoT into participant vClusters using the local OaaS-IoT Helm
charts. Commands are executed through vcluster connect, so resources are created
inside each virtual cluster.

Options:
  --count N
      Number of generated participant clusters. Default: ${COUNT}.

  --prefix NAME
      Generated vCluster name prefix. Default: ${PREFIX}.

  --start-index N
      First numeric suffix. Default: ${START_INDEX}.

  --names a,b,c
      Explicit comma-separated vCluster names. Overrides --count.

  --vcluster-namespace-prefix PREFIX
      Prefix for host namespaces containing vClusters. Default is empty, so
      namespace == vCluster name.

  --oaas-dir PATH
      Path to OaaS-IoT repo. Default: ${OAAS_DIR}.

  --crm-count N
      Number of CRM releases to install inside each vCluster. Default: ${CRM_COUNT}.

  --compiler
      Install the OaaS compiler service too. Default: disabled to keep participant
      clusters lightweight.

  --pm-storage memory|etcd
      PM storage backend. Default: memory, so participant clusters do not need PVC storage.

  --no-compiler
      Skip the compiler service.

  --registry-prefix PREFIX
      Override image registry prefix, for example localhost:5000 or myuser.
      This maps images to PREFIX/{pm,crm,router,gateway,odgm,compiler}:TAG.

  --tag TAG
      Image tag when --registry-prefix is used. Default: ${IMAGE_TAG}.

  --purge-namespaces
      On uninstall, delete OaaS namespaces inside each vCluster too.

  --help
      Show this help.

Examples:
  ./install-oaas-into-vclusters.sh install --count 3
  ./install-oaas-into-vclusters.sh status --count 3
  ./install-oaas-into-vclusters.sh uninstall --count 3 --purge-namespaces

After install, check one participant:
  vcluster connect participant-1 --namespace participant-1 -- kubectl get pods -A
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
  if (($#)) && [[ "$1" =~ ^(install|deploy|status|uninstall|undeploy|delete)$ ]]; then
    ACTION="$1"
    shift
  fi

  case "${ACTION}" in
    deploy) ACTION=install ;;
    undeploy|delete) ACTION=uninstall ;;
  esac

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
      --vcluster-namespace-prefix)
        [[ $# -ge 2 ]] || die "--vcluster-namespace-prefix requires a value"
        VCLUSTER_NAMESPACE_PREFIX="$2"
        shift 2
        ;;
      --oaas-dir)
        [[ $# -ge 2 ]] || die "--oaas-dir requires a value"
        OAAS_DIR="$2"
        shift 2
        ;;
      --crm-count)
        [[ $# -ge 2 ]] || die "--crm-count requires a value"
        CRM_COUNT="$2"
        shift 2
        ;;
      --compiler)
        COMPILER_ENABLED=true
        shift
        ;;
      --pm-storage)
        [[ $# -ge 2 ]] || die "--pm-storage requires a value"
        PM_STORAGE="$2"
        shift 2
        ;;
      --no-compiler)
        COMPILER_ENABLED=false
        shift
        ;;
      --registry-prefix)
        [[ $# -ge 2 ]] || die "--registry-prefix requires a value"
        REGISTRY_PREFIX="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || die "--tag requires a value"
        IMAGE_TAG="$2"
        shift 2
        ;;
      --purge-namespaces)
        PURGE_NAMESPACES=true
        shift
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

validate_dns_label() {
  local kind="$1"
  local value="$2"

  [[ ${#value} -le 63 ]] || die "${kind} '${value}' is longer than 63 characters"
  if [[ ! "${value}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    die "${kind} '${value}' must be a DNS label: lowercase letters, digits, and hyphens only"
  fi
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
  [[ "${START_INDEX}" =~ ^[0-9]+$ ]] || die "--start-index must be a positive integer"
  [[ "${COUNT}" -gt 0 ]] || die "--count must be greater than zero"

  local i last name
  last=$((START_INDEX + COUNT - 1))
  for ((i = START_INDEX; i <= last; i++)); do
    name="${PREFIX}-${i}"
    validate_dns_label "vCluster name" "${name}"
    VCLUSTER_NAMES+=("${name}")
  done
}

check_prereqs() {
  need_cmd kubectl
  need_cmd vcluster

  if ! command -v helm >/dev/null 2>&1; then
    die "helm is not installed. Install it first, then rerun. On Ubuntu, one option is: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  fi

  [[ -d "${OAAS_DIR}" ]] || die "OaaS-IoT directory not found: ${OAAS_DIR}"
  [[ -f "${OAAS_DIR}/k8s/crds/classruntimes.gen.yaml" ]] || die "Missing generated CRD: ${OAAS_DIR}/k8s/crds/classruntimes.gen.yaml"
  [[ -d "${OAAS_DIR}/k8s/charts/oprc-pm" ]] || die "Missing PM chart under ${OAAS_DIR}/k8s/charts"
  [[ -d "${OAAS_DIR}/k8s/charts/oprc-crm" ]] || die "Missing CRM chart under ${OAAS_DIR}/k8s/charts"
  [[ "${CRM_COUNT}" =~ ^[0-9]+$ && "${CRM_COUNT}" -gt 0 ]] || die "--crm-count must be a positive integer"
  case "${PM_STORAGE}" in memory|etcd) ;; *) die "--pm-storage must be memory or etcd" ;; esac
}

vcluster_namespace() {
  local name="$1"
  printf '%s%s' "${VCLUSTER_NAMESPACE_PREFIX}" "${name}"
}

run_in_vcluster() {
  local name="$1"
  shift
  local namespace
  namespace="$(vcluster_namespace "${name}")"
  vcluster --silent connect "${name}" --namespace "${namespace}" -- "$@"
}

crm_release_name() {
  local i="$1"
  printf '%s-%s' "${CRM_RELEASE_PREFIX}" "${i}"
}

crm_namespace() {
  local i="$1"
  printf '%s-%s' "${CRM_NS_PREFIX}" "${i}"
}

registry_args_for_crm() {
  [[ -n "${REGISTRY_PREFIX}" ]] || return 0
  printf '%s\n' \
    --set "image.repository=${REGISTRY_PREFIX}/crm" \
    --set "image.tag=${IMAGE_TAG}" \
    --set "router.image.repository=${REGISTRY_PREFIX}/router" \
    --set "router.image.tag=${IMAGE_TAG}" \
    --set "gateway.image.repository=${REGISTRY_PREFIX}/gateway" \
    --set "gateway.image.tag=${IMAGE_TAG}" \
    --set "config.templates.odgmImageOverride=${REGISTRY_PREFIX}/odgm:${IMAGE_TAG}"
}

registry_args_for_pm() {
  [[ -n "${REGISTRY_PREFIX}" ]] || return 0
  printf '%s\n' \
    --set "image.repository=${REGISTRY_PREFIX}/pm" \
    --set "image.tag=${IMAGE_TAG}"
}

registry_args_for_compiler() {
  [[ -n "${REGISTRY_PREFIX}" ]] || return 0
  printf '%s\n' \
    --set "image.repository=${REGISTRY_PREFIX}/compiler" \
    --set "image.tag=${IMAGE_TAG}"
}

install_one() {
  local vc="$1"
  local charts_dir="${OAAS_DIR}/k8s/charts"

  log "Installing OaaS-IoT into ${vc}"
  run_in_vcluster "${vc}" kubectl apply -f "${OAAS_DIR}/k8s/crds/classruntimes.gen.yaml"

  local i crm_rel crm_ns crm_values
  for ((i = 1; i <= CRM_COUNT; i++)); do
    crm_rel="$(crm_release_name "${i}")"
    crm_ns="$(crm_namespace "${i}")"
    crm_values="${charts_dir}/examples/crm-${i}.yaml"
    [[ -f "${crm_values}" ]] || crm_values="${charts_dir}/examples/crm-1.yaml"

    log "Installing CRM ${crm_rel} in ${vc}/${crm_ns}"
    mapfile -t crm_registry_args < <(registry_args_for_crm)
    run_in_vcluster "${vc}" helm upgrade --install "${crm_rel}" "${charts_dir}/oprc-crm" \
      --namespace "${crm_ns}" --create-namespace \
      --values "${crm_values}" \
      --set crd.create=false \
      --set config.namespace="${crm_ns}" \
      "${crm_registry_args[@]}"
  done

  if as_bool "${COMPILER_ENABLED}"; then
    log "Installing compiler in ${vc}/${PM_NS}"
    mapfile -t compiler_registry_args < <(registry_args_for_compiler)
    run_in_vcluster "${vc}" helm upgrade --install "${COMPILER_RELEASE}" "${charts_dir}/oprc-compiler" \
      --namespace "${PM_NS}" --create-namespace \
      --values "${charts_dir}/examples/compiler.yaml" \
      "${compiler_registry_args[@]}"
  fi

  local crm1_url pm_values artifact_base_url compiler_url
  crm1_url="http://$(crm_release_name 1)-oprc-crm.$(crm_namespace 1).svc.cluster.local:8088"
  pm_values="${charts_dir}/examples/pm.yaml"
  artifact_base_url="http://${PM_RELEASE}-oprc-pm.${PM_NS}.svc.cluster.local:8080/api/v1/artifacts"
  compiler_url="http://${COMPILER_RELEASE}-oprc-compiler.${PM_NS}.svc.cluster.local:3000"

  log "Installing PM ${PM_RELEASE} in ${vc}/${PM_NS}"
  mapfile -t pm_registry_args < <(registry_args_for_pm)
  pm_args=(
    helm upgrade --install "${PM_RELEASE}" "${charts_dir}/oprc-pm"
    --namespace "${PM_NS}" --create-namespace
    --values "${pm_values}"
    --set-string "config.crm.default.url=${crm1_url}"
    --set-string "config.artifact.baseUrl=${artifact_base_url}"
    --set "config.storage.type=${PM_STORAGE}"
  )
  if [[ "${PM_STORAGE}" == "memory" ]]; then
    pm_args+=(--set embeddedEtcd.enabled=false)
  fi

  if as_bool "${COMPILER_ENABLED}"; then
    pm_args+=(--set-string "config.compiler.url=${compiler_url}")
  fi
  pm_args+=("${pm_registry_args[@]}")
  run_in_vcluster "${vc}" "${pm_args[@]}"

  log "Waiting for OaaS-IoT Pods in ${vc}"
  run_in_vcluster "${vc}" kubectl wait --for=condition=Ready pod --all -n "${PM_NS}" --timeout=5m || true
  for ((i = 1; i <= CRM_COUNT; i++)); do
    run_in_vcluster "${vc}" kubectl wait --for=condition=Ready pod --all -n "$(crm_namespace "${i}")" --timeout=5m || true
  done
}

status_one() {
  local vc="$1"
  log "Status for ${vc}"
  run_in_vcluster "${vc}" helm list --all-namespaces || true
  run_in_vcluster "${vc}" kubectl get pods,svc -n "${PM_NS}" || true
  local i
  for ((i = 1; i <= CRM_COUNT; i++)); do
    run_in_vcluster "${vc}" kubectl get pods,svc -n "$(crm_namespace "${i}")" || true
  done
}

uninstall_one() {
  local vc="$1"
  log "Uninstalling OaaS-IoT from ${vc}"
  run_in_vcluster "${vc}" kubectl delete classruntimes --all --all-namespaces --ignore-not-found --wait=true || true
  run_in_vcluster "${vc}" kubectl delete crd classruntimes.oaas.io --ignore-not-found || true
  run_in_vcluster "${vc}" helm uninstall "${PM_RELEASE}" -n "${PM_NS}" || true
  run_in_vcluster "${vc}" helm uninstall "${COMPILER_RELEASE}" -n "${PM_NS}" || true

  local i
  for ((i = CRM_COUNT; i >= 1; i--)); do
    run_in_vcluster "${vc}" helm uninstall "$(crm_release_name "${i}")" -n "$(crm_namespace "${i}")" || true
  done

  if as_bool "${PURGE_NAMESPACES}"; then
    run_in_vcluster "${vc}" kubectl delete namespace "${PM_NS}" --ignore-not-found || true
    for ((i = CRM_COUNT; i >= 1; i--)); do
      run_in_vcluster "${vc}" kubectl delete namespace "$(crm_namespace "${i}")" --ignore-not-found || true
    done
  fi
}

main() {
  parse_args "$@"
  case "${ACTION}" in
    install|status|uninstall) ;;
    *) die "Unknown action: ${ACTION}" ;;
  esac

  build_names
  check_prereqs

  log "Target vClusters: ${VCLUSTER_NAMES[*]}"
  log "OaaS-IoT directory: ${OAAS_DIR}"
  log "CRM count inside each vCluster: ${CRM_COUNT}"
  log "Compiler enabled: ${COMPILER_ENABLED}"
  log "PM storage backend: ${PM_STORAGE}"

  local vc
  for vc in "${VCLUSTER_NAMES[@]}"; do
    case "${ACTION}" in
      install) install_one "${vc}" ;;
      status) status_one "${vc}" ;;
      uninstall) uninstall_one "${vc}" ;;
    esac
  done

  if [[ "${ACTION}" == "install" ]]; then
    cat <<EOF_NEXT

Done. Check one virtual cluster with:
  ./install-oaas-into-vclusters.sh status --names ${VCLUSTER_NAMES[0]}

Access PM from one virtual cluster with port-forward:
  vcluster connect ${VCLUSTER_NAMES[0]} --namespace $(vcluster_namespace "${VCLUSTER_NAMES[0]}") -- kubectl -n ${PM_NS} port-forward svc/${PM_RELEASE}-oprc-pm 8080:8080
EOF_NEXT
  fi
}

main "$@"
