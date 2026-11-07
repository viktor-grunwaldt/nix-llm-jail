{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
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
    mem = 8192;

    volumes = [
      {
        # Reuse the existing disk containing OpenCode sessions and OAuth state.
        # Keep this absolute: the launcher runs from XDG_RUNTIME_DIR.
        image = "/home/vi/images/llm-jail/shared/nix/opencode-state.img";
        # A missing state disk must fail startup, not silently create empty state.
        autoCreate = false;
        # OpenCode writes its database and logs here; keep the state disk writable.
        readOnly = false;
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

    # Keep host store paths immutable while allowing ephemeral guest builds.
    writableStoreOverlay = "/nix/.rw-store";
  };

  # --- Guest software ---------------------------------------------------
  environment.systemPackages = [
    pkgs.tmux
    pkgs.helix
    pkgs.ripgrep
    pkgs.git
    pkgs.pi-coding-agent
  ];

  # Forward application OSC 52 writes through SSH to the host terminal.
  environment.etc."tmux.conf".text = ''
    set -g set-clipboard on
    # OpenCode v2 wraps OSC 52 clipboard writes in tmux DCS passthrough.
    set -g allow-passthrough on
  '';

  # The host checkout is already enforced read-only by virtiofsd.
  environment.etc."opencode/opencode.json".text = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";
    permissions = [
      {
        action = "external_directory";
        resource = "/mnt/host/**";
        effect = "allow";
      }
    ];
    # Provider-side cache keep-alives: every 4 idle minutes, for 30 minutes.
    warming = true;
  };

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

  # Keep OpenCode state, authentication and user config on the dedicated volume.
  systemd.services.setup-opencode-state = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "sshd.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/opencode" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.util-linux}/bin/mountpoint -q /var/lib/opencode

      # Accept the intended link on repeat runs, but never replace another path.
      link_directory() {
        local target="$1" link="$2"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
          return
        fi
        if [ -e "$link" ] || [ -L "$link" ]; then
          echo "Refusing to replace existing path: $link" >&2
          return 1
        fi
        ln -sT "$target" "$link"
      }

      install -d -m 0700 -o ${user} -g users /var/lib/opencode
      install -d -m 0700 -o ${user} -g users /var/lib/opencode/.local-state
      install -d -m 0755 -o ${user} -g users \
        /home/${user}/.local \
        /home/${user}/.local/share \
        /home/${user}/.local/state
      install -d -m 0755 -o ${user} -g users /home/${user}/.config
      config=/home/${user}/.config/opencode
      persistent=/var/lib/opencode/.config
      if [ -L "$persistent" ] || { [ -e "$persistent" ] && [ ! -d "$persistent" ]; }; then
        echo "Persistent config must be a real directory" >&2
        exit 1
      fi
      if [ -d "$config" ] && [ ! -L "$config" ]; then
        # An empty home directory is safe to replace, even with saved config.
        if ! rmdir "$config" 2>/dev/null; then
          if [ -e "$persistent" ] || [ -e "$config.pre-persistence" ] || [ -L "$config.pre-persistence" ]; then
            echo "Config migration conflict; preserve and reconcile both directories before retrying" >&2
            exit 1
          fi
          # Copy metadata and symlinks without dereferencing them. Keep the
          # original until the next boot; a failed copy never removes it.
          cp -aT "$config" "$persistent"
          mv -T "$config" "$config.pre-persistence"
        fi
      fi
      install -d -m 0700 -o ${user} -g users "$persistent"
      link_directory "$persistent" "$config"
      link_directory /var/lib/opencode /home/${user}/.local/share/opencode
      link_directory /var/lib/opencode/.local-state /home/${user}/.local/state/opencode
      link_directory /mnt/host/AGENTS.md "$config/AGENTS.md"
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
