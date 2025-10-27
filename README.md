# Sandbox VM Helper

This repo ships a `sandbox-vm.sh` helper that provisions and manages a lightweight Ubuntu 24.04 virtual machine on a host running Ubuntu 24.04. It is tuned for running untrusted or experimental scripts safely. The VM is CPU-only and automatically exposes the host's self-hosted LLM server (listening on `127.0.0.1:8000`) to guests via a libvirt NAT bridge.

## Quick start

1. Review the script so you understand what it will do: `less sandbox-vm.sh`.
2. Run the initial setup (installs KVM/libvirt, downloads the Ubuntu cloud image, creates the VM, and enables the LLM proxy):
   ```bash
   ./sandbox-vm.sh setup
   ```
3. Start the VM whenever you need it:
   ```bash
   ./sandbox-vm.sh start
   ```
4. Attach to the console with `./sandbox-vm.sh console` or SSH to `sandbox@<vm-ip>` (default password: `sandbox`). If your host has an SSH public key at `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`, it is injected automatically.
5. Inside the VM, reach your host LLM at `http://192.168.122.1:8000/` (the address matches libvirt's default gateway). The helper keeps a `socat` systemd service running on the host so that the guest can reach the loopback-only service safely.
6. Shut the VM down when you are done:
   ```bash
   ./sandbox-vm.sh stop
   ```

The first boot can take a minute while cloud-init configures the guest and installs the QEMU guest agent.

## Command reference

```
./sandbox-vm.sh setup        # one-time provisioning (idempotent)
./sandbox-vm.sh start        # boot the VM
./sandbox-vm.sh stop         # graceful shutdown (force if needed)
./sandbox-vm.sh status       # show libvirt info for the VM
./sandbox-vm.sh console      # attach to serial console (Ctrl+] to exit)
./sandbox-vm.sh reset        # rebuild from the clean base image
./sandbox-vm.sh destroy      # remove VM overlay + cloud-init state
./sandbox-vm.sh proxy-service status|restart|disable
```

`reset` is the fastest way to return to a pristine state before running another untrusted workload—it destroys and recreates the overlay disk but keeps the cached base image.

## Customisation

Override behaviour with environment variables:

| Variable           | Description (defaults in parentheses)                                |
|--------------------|----------------------------------------------------------------------|
| `VM_NAME`          | libvirt domain name (`sandbox-vm`)                                   |
| `VM_VCPUS`         | number of virtual CPUs (`2`)                                         |
| `VM_MEMORY_MB`     | memory in megabytes (`4096`)                                         |
| `VM_DISK_SIZE_GB`  | overlay disk size (`30`)                                             |
| `VM_NETWORK`       | libvirt network (`default`)                                          |
| `BASE_IMAGE_URL`   | URL for the Ubuntu 24.04 cloud image                                 |
| `SSH_PUBLIC_KEY`   | path to a public key to inject (auto-detects common defaults)        |
| `LLM_HOST`         | host address for the LLM proxy (`127.0.0.1`)                         |
| `LLM_PORT`         | TCP port forwarded into the libvirt network (`8000`)                 |

Examples:

```bash
VM_VCPUS=4 VM_MEMORY_MB=8192 ./sandbox-vm.sh reset
LLM_PORT=9000 ./sandbox-vm.sh proxy-service restart
```

If you change the LLM port or host binding, the helper updates `/etc/systemd/system/sandbox-llm-proxy.service` and restarts it automatically.

## Networking details

* The setup assumes the libvirt `default` NAT network (`virbr0`). If it is missing, `setup` recreates it. When using a custom network, create it ahead of time and export `VM_NETWORK`.
* Guests reach host-only services through the proxy at the network gateway IP (determined from libvirt). You can confirm the address with `./sandbox-vm.sh proxy-service status`.
* The proxy binds only to the libvirt bridge and forwards traffic to the host loopback address, keeping the LLM server inaccessible from other machines.

## Resetting and cleanup

* `./sandbox-vm.sh reset` stops the VM, removes the overlay, rebuilds it from the pristine cloud image, re-runs cloud-init, and leaves the VM defined (but powered off).
* `./sandbox-vm.sh destroy` removes the overlay and cloud-init seed but keeps the cached base image and the LLM proxy. Run `setup` again to recreate the guest.
* To uninstall everything, stop the VM, run `./sandbox-vm.sh destroy`, disable the proxy (`./sandbox-vm.sh proxy-service disable`), and remove `/var/lib/libvirt/images/ubuntu-24.04-base.qcow2` if you no longer need the cached base image.

## Security notes

* KVM/libvirt provides strong isolation for CPU-bound workloads, but no virtualisation boundary is perfect. Do not run scripts that you believe can exploit the kernel or escape the hypervisor.
* The guest user `sandbox` has passwordless sudo inside the VM for convenience. Treat the VM as disposable and never store secrets inside it.
* The host's LLM port forward is restricted to the internal libvirt network. If you expose other host services to the same network, review their security posture.

## Troubleshooting tips

* If `setup` fails with a permission error when launching the VM, ensure virtualisation is enabled in firmware and that `/dev/kvm` is accessible (membership in the `kvm` group is enough). Re-login after running `sudo usermod -aG kvm $(whoami)`.
* Cloud-init logs live at `/var/log/cloud-init.log` inside the guest. Use the console to inspect them if the first boot hangs.
* If the guest cannot reach the LLM, verify the proxy is running (`./sandbox-vm.sh proxy-service status`) and that the host service is listening on `${LLM_HOST}:${LLM_PORT}`.
* For brute-force resets, destroy and recreate: `./sandbox-vm.sh destroy && ./sandbox-vm.sh setup`.

