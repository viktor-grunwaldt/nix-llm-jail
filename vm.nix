{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  user = "agent";
  opencodePkgs = import inputs.nixpkgs-opencode {
    system = pkgs.system;
  };
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
    mem = 8192;

    volumes = [
      {
        image = "/home/vi/images/llm-jail/shared/opencode-state.img";
        mountPoint = "/var/lib/opencode";
        size = 2048;
      }
    ];

    interfaces = [
      {
        type = "user";
        id = "eth0";
        mac = "02:00:00:00:00:01";
      }
    ];

    forwardPorts = [
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
    ];

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

    writableStoreOverlay = null;
  };

  # --- Guest software ---------------------------------------------------
  environment.systemPackages = [
    pkgs.codex
    pkgs.tmux
    pkgs.helix
    pkgs.ripgrep
    pkgs.git
    opencodePkgs.opencode
  ];

  # --- SSH access & user setup ------------------------------------------
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

  # Keep OpenCode state, including authentication, on the dedicated volume.
  systemd.services.setup-opencode-state = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "sshd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 -o ${user} -g users /var/lib/opencode
      mkdir -p /home/${user}/.local/share
      ln -s /var/lib/opencode /home/${user}/.local/share/opencode
    '';
  };

  security.sudo.wheelNeedsPassword = false;

  # --- Network isolation from the host ----------------------------------
  networking.firewall.enable = true;
  networking.nftables.enable = true;

  networking.nftables.tables."isolate-vm" = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy drop;

        # Existing connections.
        ct state established,related accept

        # Loopback.
        oifname "lo" accept

        # QEMU SLIRP DNS.
        ip daddr 10.0.2.3 udp dport 53 accept
        ip daddr 10.0.2.3 tcp dport 53 accept

        # Block access to host/private networks.
        ip daddr 10.0.0.0/8 drop
        ip daddr 172.16.0.0/12 drop
        ip daddr 192.168.0.0/16 drop
        ip daddr 169.254.0.0/16 drop

        # Provider/API traffic.
        tcp dport { 80, 443 } accept
        udp dport 443 accept
      }
    '';
  };

  system.stateVersion = "24.11";
}
