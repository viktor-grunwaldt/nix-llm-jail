{ config, lib, pkgs, ... }:
let
  user = "agent";
in
{
  networking.hostName = "ai-agent";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
    "pipe-operators"
  ];

  # --- microvm.nix ------------------------------------------------------
  microvm = {
    hypervisor = "qemu";
    vcpu = 4;
    mem = 8192; # MB. Also bounds the tmpfs root/overlay size — see note below.

    # No block-device volumes on purpose: the root filesystem is a
    # read-only squashfs/erofs plus a tmpfs overlay for writes, both gone
    # the moment the VM exits. That's what gives you a jail that resets
    # itself every run instead of accumulating state. If some agent
    # workload needs more scratch space than `mem` comfortably allows,
    # add a `volumes = [ { image = "scratch.img"; mountPoint = "/tmp"; size = ...; } ];`
    # entry — just know that reintroduces state you have to manage.
    volumes = [ ];

    interfaces = [{
      type = "user"; # qemu SLIRP networking — no host-side tap/bridge setup needed
      id = "eth0";
      mac = "02:00:00:00:00:01";
    }];

    forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
    ];

    # Both shares are exported read-only from the host side, by the
    # virtiofsd instances the `run-ai-agent` wrapper in flake.nix starts
    # with `--readonly`. The `source` field below is informational only
    # in this standalone setup (no host module reads it to spawn
    # virtiofsd for you) — the wrapper's `--shared-dir` is what actually
    # controls what gets exported. Keep them pointing at the same path.
    shares = [
      {
        tag = "ro-store";
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        proto = "virtiofs";
        socket = "ro-store.sock";
      }
      {
        tag = "host-ro";
        source = "/home/vi/images/llm-jail/shared";
        mountPoint = "/mnt/host";
        proto = "virtiofs";
        socket = "host-ro.sock";
      }
    ];

    # Keep /nix/store genuinely read-only in the guest (no writable
    # overlay). If the agent needs to `nix build` inside the VM, this has
    # to become a path plus a matching `volumes` entry for the upper
    # layer — 9p/virtiofs can't be the overlay's writable side.
    writableStoreOverlay = null;
  };

  # --- SSH access & user setup -------------------------------------------
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;

  users.users.${user} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = [ (builtins.readFile ./id_ed25519.pub) ];
  };

  security.sudo.wheelNeedsPassword = false;

  # --- Network isolation from the host ------------------------------------
  networking.firewall.enable = true;
  networking.nftables.enable = true;
  networking.nftables.tables."isolate-vm" = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        # Allow replies to connections initiated by the host (like SSH)
        ct state established,related accept
        # Block the agent from initiating NEW connections to the host gateway
        ip daddr 10.0.2.2 drop
      }
    '';
  };

  system.stateVersion = "24.11";
}
