#!/usr/bin/env bash

set -euo pipefail

COMMAND=${1:-}

if [[ -z "${COMMAND}" ]]; then
  cat <<'EOF'
Usage: sandbox-vm.sh <command>

Commands:
  setup           Install dependencies and provision the sandbox VM
  start           Start the sandbox VM
  stop            Attempt a graceful shutdown of the VM (force after timeout)
  status          Show libvirt status for the VM
  console         Attach to the serial console (Ctrl+] to exit)
  reset           Destroy the VM and recreate it from the clean base image
  destroy         Remove the VM and all associated state (keeps base image)
  proxy-service   Manage the LLM port proxy (subcommands: status|restart|disable)

Environment overrides:
  VM_NAME             (default: sandbox-vm)
  VM_VCPUS            (default: 126)
  VM_MEMORY_MB        (default: 32768)
  VM_DISK_SIZE_GB     (default: 30)
  VM_NETWORK          (default: default)
  VM_HOSTNAME         (default: sandbox)
  VM_MAC              (default: 52:54:00:ab:cd:01)
  VM_IP               (default: 192.168.122.50)
  BASE_IMAGE_URL      (default: ubuntu 24.04 cloud image)
  SSH_PUBLIC_KEY      (path to public key to inject into the guest)
  LLM_HOST            (default: 127.0.0.1)
  LLM_PORT            (default: 8000)

Examples:
  ./sandbox-vm.sh setup
  ./sandbox-vm.sh start
  VM_VCPUS=4 VM_MEMORY_MB=8192 ./sandbox-vm.sh reset
EOF
  exit 1
fi

VM_NAME=${VM_NAME:-sandbox-vm}
VM_VCPUS=${VM_VCPUS:-126}
VM_MEMORY_MB=${VM_MEMORY_MB:-32768}
VM_DISK_SIZE_GB=${VM_DISK_SIZE_GB:-30}
VM_NETWORK=${VM_NETWORK:-default}
VM_HOSTNAME=${VM_HOSTNAME:-sandbox}
VM_MAC=${VM_MAC:-52:54:00:ab:cd:01}
VM_IP=${VM_IP:-192.168.122.50}
BASE_IMAGE_URL=${BASE_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}
SSH_PUBLIC_KEY_PATH=${SSH_PUBLIC_KEY:-}
LLM_HOST=${LLM_HOST:-127.0.0.1}
LLM_PORT=${LLM_PORT:-8000}

if [[ -n "${SUDO_USER:-}" ]]; then
  INVOKING_USER="${SUDO_USER}"
elif [[ -n "${LOGNAME:-}" ]]; then
  INVOKING_USER="${LOGNAME}"
elif [[ -n "${USER:-}" ]]; then
  INVOKING_USER="${USER}"
else
  INVOKING_USER=$(id -un)
fi

INVOKING_USER_HOME=$(getent passwd "${INVOKING_USER}" | cut -d: -f6 2>/dev/null || true)
if [[ -z "${INVOKING_USER_HOME}" ]]; then
  INVOKING_USER_HOME=$(eval echo "~${INVOKING_USER}" 2>/dev/null || true)
fi
if [[ -z "${INVOKING_USER_HOME}" ]]; then
  INVOKING_USER_HOME="${HOME:-}"
fi

SANDBOX_USERNAME=${SANDBOX_USERNAME:-sandbox}
if [[ "${SANDBOX_USERNAME}" == "root" ]]; then
  SANDBOX_USER_HOME="/root"
else
  SANDBOX_USER_HOME="/home/${SANDBOX_USERNAME}"
fi

INVOKING_USER_GROUP=$(id -gn "${INVOKING_USER}" 2>/dev/null || true)
if [[ -z "${INVOKING_USER_GROUP}" ]]; then
  INVOKING_USER_GROUP=$(id -g "${INVOKING_USER}" 2>/dev/null || true)
fi
if [[ -z "${INVOKING_USER_GROUP}" ]]; then
  INVOKING_USER_GROUP="${INVOKING_USER}"
fi
DETECTED_PUBKEY_PATH=""

SUDO=sudo
if [[ "${EUID}" -eq 0 ]]; then
  SUDO=
fi

LIBVIRT_IMAGE_DIR=/var/lib/libvirt/images
SANDBOX_DIR="${LIBVIRT_IMAGE_DIR}/${VM_NAME}"
BASE_IMAGE="${LIBVIRT_IMAGE_DIR}/ubuntu-24.04-base.qcow2"
OVERLAY_IMAGE="${SANDBOX_DIR}/disk.qcow2"
SEED_IMAGE="${SANDBOX_DIR}/seed.iso"
CLOUD_INIT_DIR="${SANDBOX_DIR}/cloud-init"
USER_DATA_FILE="${CLOUD_INIT_DIR}/user-data.yaml"
META_DATA_FILE="${CLOUD_INIT_DIR}/meta-data.yaml"
SOCAT_SERVICE=/etc/systemd/system/sandbox-llm-proxy.service

# SHA-512 hash for the fallback sandbox user password "sandbox"
SANDBOX_PASSWORD_HASH='$6$VOX0KkCjb6wYYhs5$VAaVnXRdBQ4VMqU.ETpntF89BMYSkomscUqJxvVSE9aB/8A6XmfvQNay26KRkD6HEGzWzBK74.xhhyWgEFYaq.'

log() {
  echo "[sandbox-vm] $*"
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log "Missing required command '${cmd}'. Install it and retry."
    exit 1
  fi
}

detect_pubkey() {
  local candidates=()
  if [[ -n "${SSH_PUBLIC_KEY_PATH}" ]]; then
    candidates+=("${SSH_PUBLIC_KEY_PATH}")
  fi
  if [[ -n "${INVOKING_USER_HOME:-}" ]]; then
    candidates+=("${INVOKING_USER_HOME}/.ssh/id_ed25519.pub" "${INVOKING_USER_HOME}/.ssh/id_rsa.pub")
  fi
  if [[ -n "${HOME:-}" && "${HOME:-}" != "${INVOKING_USER_HOME:-}" ]]; then
    candidates+=("${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub")
  fi

  local path
  for path in "${candidates[@]}"; do
    if [[ -f "${path}" ]]; then
      DETECTED_PUBKEY_PATH="${path}"
      cat "${path}"
      return 0
    fi
  done

  return 1
}

ensure_packages() {
  require_command apt-get

  log "Installing virtualization prerequisites (this can take a minute)..."
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    cloud-image-utils \
    qemu-utils \
    dnsmasq-base \
    bridge-utils \
    socat
}

ensure_libvirtd() {
  log "Ensuring libvirtd service is active..."
  ${SUDO} systemctl enable --now libvirtd
}

validate_virtualization() {
  if [[ -r /proc/cpuinfo ]] && ! grep -Eq '(vmx|svm)' /proc/cpuinfo; then
    log "WARNING: CPU virtualization extensions not detected (vmx/svm missing)."
    log "KVM performance may be degraded or unavailable."
  fi
}

ensure_network() {
  log "Ensuring libvirt network '${VM_NETWORK}' is available..."
  if ! ${SUDO} virsh net-info "${VM_NETWORK}" >/dev/null 2>&1; then
    if [[ "${VM_NETWORK}" != "default" ]]; then
      log "ERROR: libvirt network '${VM_NETWORK}' is missing. Create it manually or rerun with VM_NETWORK=default."
      exit 1
    fi
    log "Default network '${VM_NETWORK}' not found. Creating a NAT network."
    local tmpfile
    tmpfile=$(mktemp)
    cat <<EOF >"${tmpfile}"
<network>
  <name>${VM_NETWORK}</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='2'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
    ${SUDO} virsh net-define "${tmpfile}"
    rm -f "${tmpfile}"
  fi
  ${SUDO} virsh net-autostart "${VM_NETWORK}" >/dev/null
  if ${SUDO} virsh net-info "${VM_NETWORK}" | grep -q "Active:.*yes"; then
    log "Libvirt network '${VM_NETWORK}' already active."
    ensure_dhcp_host
    return
  fi

  log "Starting libvirt network '${VM_NETWORK}'..."
  local start_output
  if ! start_output=$(${SUDO} virsh net-start "${VM_NETWORK}" 2>&1); then
    if ${SUDO} virsh net-info "${VM_NETWORK}" | grep -q "Active:.*yes"; then
      log "Libvirt network '${VM_NETWORK}' already active."
      return
    fi
    if grep -qi "network is already active" <<<"${start_output}"; then
      log "Libvirt network '${VM_NETWORK}' already active."
      return
    fi
    log "ERROR: Failed to start libvirt network '${VM_NETWORK}': ${start_output}"
    exit 1
  fi
  log "Libvirt network '${VM_NETWORK}' started."

  ensure_dhcp_host
}

ensure_dhcp_host() {
  local net_xml
  net_xml=$(${SUDO} virsh net-dumpxml "${VM_NETWORK}")
  if grep -q "<host[^>]*mac='${VM_MAC}'" <<<"${net_xml}"; then
    if grep -q "<host[^>]*mac='${VM_MAC}'[^>]*ip='${VM_IP}'" <<<"${net_xml}" && grep -q "<host[^>]*mac='${VM_MAC}'[^>]*name='${VM_HOSTNAME}'" <<<"${net_xml}"; then
      return
    fi
    log "Updating DHCP reservation for '${VM_HOSTNAME}' (${VM_MAC} -> ${VM_IP})."
    ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host mac='${VM_MAC}'/>" --config >/dev/null 2>&1 || true
    ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host name='${VM_HOSTNAME}'/>" --config >/dev/null 2>&1 || true
    if ${SUDO} virsh net-info "${VM_NETWORK}" | grep -q "Active:.*yes"; then
      ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host mac='${VM_MAC}'/>" --live >/dev/null 2>&1 || true
      ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host name='${VM_HOSTNAME}'/>" --live >/dev/null 2>&1 || true
    fi
  else
    log "Adding DHCP reservation for '${VM_HOSTNAME}' (${VM_MAC} -> ${VM_IP})."
  fi

  local host_entry="<host mac='${VM_MAC}' name='${VM_HOSTNAME}' ip='${VM_IP}'/>"
  if ! ${SUDO} virsh net-update "${VM_NETWORK}" add-last ip-dhcp-host "${host_entry}" --config >/dev/null 2>&1; then
    log "WARNING: Failed to persist DHCP reservation for '${VM_HOSTNAME}'."
  fi

  if ${SUDO} virsh net-info "${VM_NETWORK}" | grep -q "Active:.*yes"; then
    if ! ${SUDO} virsh net-update "${VM_NETWORK}" add-last ip-dhcp-host "${host_entry}" --live >/dev/null 2>&1; then
      log "WARNING: Failed to apply DHCP reservation live for '${VM_HOSTNAME}'. It will apply on next network restart."
    fi
  fi
}

remove_dhcp_host() {
  if ! ${SUDO} virsh net-info "${VM_NETWORK}" >/dev/null 2>&1; then
    return
  fi

  local net_xml
  net_xml=$(${SUDO} virsh net-dumpxml "${VM_NETWORK}")
  if ! grep -q "<host[^>]*mac='${VM_MAC}'" <<<"${net_xml}"; then
    return
  fi

  log "Removing DHCP reservation for '${VM_HOSTNAME}'."
  local host_entry="<host mac='${VM_MAC}' name='${VM_HOSTNAME}' ip='${VM_IP}'/>"
  ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "${host_entry}" --config >/dev/null 2>&1 || true
  ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host mac='${VM_MAC}'/>" --config >/dev/null 2>&1 || true
  ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host name='${VM_HOSTNAME}'/>" --config >/dev/null 2>&1 || true

  if ${SUDO} virsh net-info "${VM_NETWORK}" | grep -q "Active:.*yes"; then
    ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "${host_entry}" --live >/dev/null 2>&1 || true
    ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host mac='${VM_MAC}'/>" --live >/dev/null 2>&1 || true
    ${SUDO} virsh net-update "${VM_NETWORK}" delete ip-dhcp-host "<host name='${VM_HOSTNAME}'/>" --live >/dev/null 2>&1 || true
  fi
}

libvirt_owner() {
  if id libvirt-qemu >/dev/null 2>&1 && getent group kvm >/dev/null 2>&1; then
    echo "libvirt-qemu:kvm"
  else
    ${SUDO} stat -c '%U:%G' "${LIBVIRT_IMAGE_DIR}"
  fi
}

download_base_image() {
  require_command curl
  ${SUDO} mkdir -p "${LIBVIRT_IMAGE_DIR}"
  if [[ -f "${BASE_IMAGE}" ]]; then
    log "Base image already present at ${BASE_IMAGE}"
    return
  fi

  local tmp
  tmp=$(mktemp)
  log "Downloading Ubuntu 24.04 cloud image..."
  curl -L "${BASE_IMAGE_URL}" -o "${tmp}"
  ${SUDO} mv "${tmp}" "${BASE_IMAGE}"
  ${SUDO} chown "$(libvirt_owner)" "${BASE_IMAGE}"
}

create_overlay_disk() {
  ${SUDO} mkdir -p "${SANDBOX_DIR}"
  if [[ -f "${OVERLAY_IMAGE}" ]]; then
    log "Overlay disk already exists at ${OVERLAY_IMAGE}"
    return
  fi

  log "Creating ${VM_DISK_SIZE_GB}G QCOW2 overlay for the sandbox VM..."
  ${SUDO} qemu-img create -f qcow2 -F qcow2 \
    -b "${BASE_IMAGE}" \
    "${OVERLAY_IMAGE}" \
    "${VM_DISK_SIZE_GB}G" >/dev/null
  ${SUDO} chown "$(libvirt_owner)" "${OVERLAY_IMAGE}"
}

generate_cloud_init() {
  require_command cloud-localds
  ${SUDO} mkdir -p "${CLOUD_INIT_DIR}"

  local pubkey=""
  if pubkey=$(detect_pubkey); then
    if [[ -n "${DETECTED_PUBKEY_PATH}" ]]; then
      log "Using SSH public key for user '${SANDBOX_USERNAME}' from ${DETECTED_PUBKEY_PATH}."
    else
      log "Using SSH public key for user '${SANDBOX_USERNAME}'."
    fi
  else
    log "WARNING: No SSH public key found for user '${SANDBOX_USERNAME}'. Password auth will remain enabled (password: sandbox)."
    pubkey=""
  fi

  log "Creating cloud-init configuration for user '${SANDBOX_USERNAME}'."
  local sandbox_home="${SANDBOX_USER_HOME}"
  {
    cat <<EOF
#cloud-config
hostname: ${VM_HOSTNAME}
manage_etc_hosts: true
ssh_pwauth: true
users:
  - name: ${SANDBOX_USERNAME}
    groups: [sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
    passwd: ${SANDBOX_PASSWORD_HASH}
EOF
    if [[ -n "${pubkey}" ]]; then
      cat <<EOF
    ssh_authorized_keys:
      - ${pubkey}
EOF
    fi
    cat <<EOF
package_update: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
write_files:
  - path: /etc/profile.d/sandbox-banner.sh
    permissions: '0644'
    owner: root:root
    content: |
      echo "You are inside the sandbox VM (${VM_NAME})."
      echo "Hostname: ${VM_HOSTNAME}"
      echo "Home directory: ${sandbox_home}"
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sed, -i, 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/', /etc/ssh/sshd_config ]
  - [ systemctl, restart, ssh ]
EOF
  } | ${SUDO} tee "${USER_DATA_FILE}" >/dev/null

  ${SUDO} tee "${META_DATA_FILE}" >/dev/null <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_HOSTNAME}
EOF

  local tmp
  tmp=$(mktemp)
  cloud-localds "${tmp}" "${USER_DATA_FILE}" "${META_DATA_FILE}"
  ${SUDO} mv "${tmp}" "${SEED_IMAGE}"
  ${SUDO} chown "$(libvirt_owner)" "${SEED_IMAGE}"
}

ensure_proxy_service() {
  local host_ip
  host_ip=$(get_network_gateway_ip)

  if [[ -z "${host_ip}" ]]; then
    log "ERROR: Unable to determine libvirt host IP for network '${VM_NETWORK}'."
    exit 1
  fi

  log "Configuring LLM proxy service (binds ${host_ip}:${LLM_PORT} -> ${LLM_HOST}:${LLM_PORT})..."
  ${SUDO} tee "${SOCAT_SERVICE}" >/dev/null <<EOF
[Unit]
Description=Expose host LLM service to libvirt guests
After=libvirtd.service network-online.target
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP-LISTEN:${LLM_PORT},bind=${host_ip},reuseaddr,fork TCP:${LLM_HOST}:${LLM_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl enable --now sandbox-llm-proxy.service
}

get_network_gateway_ip() {
  local ip
  ip=$(${SUDO} virsh net-dumpxml "${VM_NETWORK}" 2>/dev/null | awk -F"'" '/ip address=/ {print $2; exit}')
  if [[ -n "${ip}" ]]; then
    echo "${ip}"
    return
  fi
  if ip=$(/sbin/ip -4 addr show dev virbr0 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1); then
    echo "${ip}"
    return
  fi
  return 1
}

define_vm() {
  if ${SUDO} virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    log "VM '${VM_NAME}' already defined. Skipping virt-install."
    return
  fi

  log "Defining sandbox VM '${VM_NAME}'..."
  ${SUDO} virt-install \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY_MB}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --import \
    --os-variant ubuntu24.04 \
    --disk path="${OVERLAY_IMAGE}",format=qcow2,discard=unmap \
    --disk path="${SEED_IMAGE}",device=cdrom \
    --graphics none \
    --network network="${VM_NETWORK}",model=virtio,mac="${VM_MAC}" \
    --rng /dev/urandom \
    --channel unix,target.type=virtio,name=org.qemu.guest_agent.0 \
    --noautoconsole \
    --wait 0 \
    --check path_in_use=off

  log "VM '${VM_NAME}' created. First boot may take a minute while cloud-init runs."
}

ensure_hosts_entry() {
  local hosts_line="${VM_IP} ${VM_HOSTNAME}"
  local tmp
  tmp=$(mktemp)

  if [[ -f /etc/hosts ]]; then
    ${SUDO} awk -v host="${VM_HOSTNAME}" -v ip="${VM_IP}" '
      BEGIN {
        host_pattern = "(^|[^[:alnum:]_-])" host "([^[:alnum:]_-]|$)";
      }
      {
        if ($0 ~ "^[[:space:]]*" ip "[[:space:]]") next;
        if ($0 ~ host_pattern) next;
        print
      }
    ' /etc/hosts >"${tmp}"
  fi

  printf "%s\n" "${hosts_line}" >>"${tmp}"
  ${SUDO} install -m 0644 "${tmp}" /etc/hosts
  ${SUDO} chown root:root /etc/hosts
  rm -f "${tmp}"

  log "Ensured '${VM_HOSTNAME}' entry in /etc/hosts (${VM_IP})."
}

clear_known_hosts_entry() {
  if [[ -z "${INVOKING_USER_HOME:-}" || -z "${INVOKING_USER:-}" ]]; then
    return
  fi

  local ssh_dir="${INVOKING_USER_HOME}/.ssh"
  local known_hosts="${ssh_dir}/known_hosts"

  if [[ ! -f "${known_hosts}" ]]; then
    return
  fi

  local targets=("${VM_HOSTNAME}" "${VM_IP}")
  local target
  for target in "${targets[@]}"; do
    if [[ -z "${target}" ]]; then
      continue
    fi
    if [[ "${EUID}" -eq 0 ]]; then
      ssh-keygen -f "${known_hosts}" -R "${target}" >/dev/null 2>&1 || true
    else
      ssh-keygen -f "${known_hosts}" -R "${target}" >/dev/null 2>&1 || true
    fi
  done

  if [[ "${EUID}" -eq 0 ]]; then
    chown "${INVOKING_USER}:${INVOKING_USER_GROUP}" "${known_hosts}" 2>/dev/null || true
  fi
}

ensure_ssh_config_entry() {
  if [[ -z "${INVOKING_USER_HOME:-}" || -z "${INVOKING_USER:-}" ]]; then
    return
  fi

  local ssh_dir="${INVOKING_USER_HOME}/.ssh"
  local config_file="${ssh_dir}/config"
  local tmp
  tmp=$(mktemp)

  if [[ "${EUID}" -eq 0 ]]; then
    mkdir -p "${ssh_dir}"
    chown "${INVOKING_USER}:${INVOKING_USER_GROUP}" "${ssh_dir}"
    chmod 700 "${ssh_dir}"
  else
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
  fi

  clear_known_hosts_entry

  if [[ -f "${config_file}" ]]; then
    awk -v host="${VM_HOSTNAME}" '
      function host_matches() {
        for (i = 2; i <= NF; ++i) {
          if ($i == host) {
            return 1
          }
        }
        return 0
      }
      /^[Hh]ost[ \t]/ {
        if (host_matches()) {
          skip = 1
          next
        }
        skip = 0
      }
      skip { next }
      { print }
    ' "${config_file}" >"${tmp}"
  fi

  cat <<EOF >>"${tmp}"
Host ${VM_HOSTNAME}
  HostName ${VM_IP}
  User ${SANDBOX_USERNAME}
EOF

  if [[ "${EUID}" -eq 0 ]]; then
    install -m 0600 "${tmp}" "${config_file}"
    chown "${INVOKING_USER}:${INVOKING_USER_GROUP}" "${config_file}"
  else
    install -m 0600 "${tmp}" "${config_file}"
  fi

  rm -f "${tmp}"
  log "Ensured SSH config entry for '${VM_HOSTNAME}' with user '${SANDBOX_USERNAME}' at ${config_file}."
}

remove_hosts_entry() {
  if [[ ! -f /etc/hosts ]]; then
    return
  fi
  if ! grep -E "\\b${VM_HOSTNAME}\\b" /etc/hosts >/dev/null 2>&1 && ! grep -E "^[[:space:]]*${VM_IP}[[:space:]]" /etc/hosts >/dev/null 2>&1; then
    return
  fi

  log "Removing '${VM_HOSTNAME}' entry from /etc/hosts."
  local tmp
  tmp=$(mktemp)
  ${SUDO} awk -v host="${VM_HOSTNAME}" -v ip="${VM_IP}" '
    BEGIN {
      host_pattern = "(^|[^[:alnum:]_-])" host "([^[:alnum:]_-]|$)";
    }
    {
      if ($0 ~ "^[[:space:]]*" ip "[[:space:]]") next;
      if ($0 ~ host_pattern) next;
      print
    }
  ' /etc/hosts >"${tmp}"
  ${SUDO} sh -c "cat '${tmp}' > /etc/hosts"
  rm -f "${tmp}"
}

remove_ssh_config_entry() {
  if [[ -z "${INVOKING_USER_HOME:-}" || -z "${INVOKING_USER:-}" ]]; then
    return
  fi

  local config_file="${INVOKING_USER_HOME}/.ssh/config"
  if [[ ! -f "${config_file}" ]]; then
    return
  fi

  clear_known_hosts_entry

  local tmp
  tmp=$(mktemp)
  awk -v host="${VM_HOSTNAME}" '
    function host_matches() {
      for (i = 2; i <= NF; ++i) {
        if ($i == host) {
          return 1
        }
      }
      return 0
    }
    /^[Hh]ost[ \t]/ {
      if (host_matches()) {
        skip = 1
        next
      }
      skip = 0
    }
    skip { next }
    { print }
  ' "${config_file}" >"${tmp}"

  if cmp -s "${tmp}" "${config_file}"; then
    rm -f "${tmp}"
    return
  fi

  if [[ "${EUID}" -eq 0 ]]; then
    install -m 0600 "${tmp}" "${config_file}"
    chown "${INVOKING_USER}:${INVOKING_USER_GROUP}" "${config_file}"
  else
    install -m 0600 "${tmp}" "${config_file}"
  fi
  rm -f "${tmp}"

  log "Removed SSH config entry for '${VM_HOSTNAME}' from ${config_file}."
}

start_vm() {
  if ${SUDO} virsh domstate "${VM_NAME}" 2>/dev/null | grep -q running; then
    log "VM '${VM_NAME}' is already running."
    ensure_hosts_entry
    ensure_ssh_config_entry
    return
  fi
  ${SUDO} virsh start "${VM_NAME}"
  ensure_hosts_entry
  ensure_ssh_config_entry
}

stop_vm() {
  if ! ${SUDO} virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    log "VM '${VM_NAME}' is not defined."
    return
  fi

  if ! ${SUDO} virsh domstate "${VM_NAME}" | grep -q running; then
    log "VM '${VM_NAME}' is not running."
    return
  fi

  log "Requesting graceful shutdown..."
  ${SUDO} virsh shutdown "${VM_NAME}"
  for _ in {1..20}; do
    sleep 1
    if ! ${SUDO} virsh domstate "${VM_NAME}" | grep -q running; then
      log "VM '${VM_NAME}' stopped."
      return
    fi
  done

  log "Graceful shutdown timed out; forcing power off."
  ${SUDO} virsh destroy "${VM_NAME}"
}

vm_status() {
  if ! ${SUDO} virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    log "VM '${VM_NAME}' is not defined."
    return
  fi
  ${SUDO} virsh dominfo "${VM_NAME}"
}

vm_console() {
  log "Attaching to console. Use Ctrl+] to exit."
  ${SUDO} virsh console "${VM_NAME}" || true
}

destroy_vm() {
  if ${SUDO} virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
    log "Destroying VM '${VM_NAME}'..."
    ${SUDO} virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
    ${SUDO} virsh undefine "${VM_NAME}" --nvram >/dev/null 2>&1 || true
  fi

  log "Removing overlay and cloud-init state..."
  ${SUDO} rm -rf "${SANDBOX_DIR}"

  remove_dhcp_host
  remove_hosts_entry
  remove_ssh_config_entry
}

reset_vm() {
  log "Resetting VM '${VM_NAME}' to a clean snapshot..."
  stop_vm || true
  destroy_vm
  ensure_network
  create_overlay_disk
  generate_cloud_init
  define_vm
}

proxy_service_status() {
  ${SUDO} systemctl status sandbox-llm-proxy.service || true
}

proxy_service_restart() {
  ${SUDO} systemctl restart sandbox-llm-proxy.service
}

proxy_service_disable() {
  ${SUDO} systemctl disable --now sandbox-llm-proxy.service
}

command_setup() {
  validate_virtualization
  ensure_packages
  ensure_libvirtd
  ensure_network
  download_base_image
  create_overlay_disk
  generate_cloud_init
  ensure_proxy_service
  define_vm
  ensure_hosts_entry
  ensure_ssh_config_entry

  log "Setup complete."
  log "Next steps:"
  log "  - Run './sandbox-vm.sh start' to boot the VM."
  log "  - Use 'virsh console ${VM_NAME}' or 'ssh ${VM_HOSTNAME}' (user: ${SANDBOX_USERNAME}, password: sandbox)."
  log "  - Access host LLM from guest at http://$(get_network_gateway_ip):${LLM_PORT}/"
}

case "${COMMAND}" in
  setup)
    command_setup
    ;;
  start)
    start_vm
    ;;
  stop)
    stop_vm
    ;;
  status)
    vm_status
    ;;
  console)
    vm_console
    ;;
  reset)
    reset_vm
    ;;
  destroy)
    destroy_vm
    ;;
  proxy-service)
    shift || true
    subcmd=${1:-status}
    case "${subcmd}" in
      status) proxy_service_status ;;
      restart) proxy_service_restart ;;
      disable) proxy_service_disable ;;
      *)
        log "Unknown proxy-service subcommand '${subcmd}' (expected status|restart|disable)."
        exit 1
        ;;
    esac
    ;;
  *)
    log "Unknown command '${COMMAND}'."
    exit 1
    ;;
esac
