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
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      # Add additional package names here
      "claude-code"
    ];
  # --- microvm.nix ------------------------------------------------------
  microvm = {
    hypervisor = "qemu";
    vcpu = 4;
    mem = 8192;

    # Keep image paths absolute: the launcher runs from XDG_RUNTIME_DIR.
    volumes = [
      {
        # Agent state: Claude Code and pi logins/sessions, SSH host keys.
        # Holds credentials; never use it for project files. Kept outside the
        # shared directory so the guest cannot read it through /mnt/host.
        image = "/home/vi/images/llm-jail/agent-state.img";
        # Created empty on first start; losing it only means logging in again.
        autoCreate = true;
        label = "agent-state";
        mountPoint = "/var/lib/agent-state";
        size = 2048;
      }
      {
        # Agent working copies. The host pulls from them with `git fetch` over
        # SSH; never loop-mount this guest-written image on the host.
        image = "/home/vi/images/llm-jail/work.img";
        # Created empty (sparse) on first start.
        autoCreate = true;
        label = "agent-work";
        mountPoint = "/home/${user}/work";
        size = 32768;
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
        # Loopback only; an empty address would expose SSH on every host interface.
        host.address = "127.0.0.1";
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
    pkgs.pi-coding-agent
    pkgs.claude-code
  ];

  # Commits made in the VM are recognisably the agent's when the host fetches them.
  programs.git = {
    enable = true;
    config.user = {
      name = "ai-agent";
      email = "agent@ai-agent.invalid";
    };
  };

  # Forward application OSC 52 writes through SSH to the host terminal.
  environment.etc."tmux.conf".text = ''
    set -g set-clipboard on
    # Some TUIs wrap OSC 52 clipboard writes in tmux DCS passthrough.
    set -g allow-passthrough on
    # Forward terminal focus in/out events to applications (e.g. editor autoread).
    set -g focus-events on
  '';

  # Keep all Claude Code state, including .claude.json (login, onboarding) and
  # .credentials.json, in one directory on the persistent volume; see below.
  environment.variables.CLAUDE_CONFIG_DIR = "/home/${user}/.claude";
  # Disable crap consentually
  environment.variables.DISABLE_TELEMETRY = "1";
  environment.variables.DISABLE_ERROR_REPORTING = "1";
  environment.variables.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1";
  environment.variables.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
  # pi keeps auth.json, sessions, settings and trust decisions here.
  environment.variables.PI_CODING_AGENT_DIR = "/var/lib/agent-state/pi";

  # --- SSH access & user setup ------------------------------------------
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = false;
  # Stable host keys, so the host can pin them (HostKeyAlias ai-agent) once.
  services.openssh.hostKeys = [
    {
      type = "ed25519";
      path = "/var/lib/agent-state/ssh/ssh_host_ed25519_key";
    }
    {
      type = "mldsa44-ed25519";
      path = "/var/lib/agent-state/ssh/ssh_host_mldsa44_ed25519_key";
    }
  ];
  systemd.services.sshd-keygen.unitConfig.RequiresMountsFor = [ "/var/lib/agent-state" ];

  users.users.${user} = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    openssh.authorizedKeys.keys = [ (builtins.readFile ./id_ed25519.pub) ];
  };

  # Wire the persistent volumes into the ephemeral home directory and give
  # every agent the VM instructions from the host share.
  systemd.services.setup-agent-state = {
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "sshd.service" ];
    unitConfig.RequiresMountsFor = [
      "/var/lib/agent-state"
      "/home/${user}/work"
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.util-linux}/bin/mountpoint -q /var/lib/agent-state
      ${pkgs.util-linux}/bin/mountpoint -q /home/${user}/work

      # Accept the intended link on repeat runs, but never replace another path.
      ensure_link() {
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

      install -d -m 0700 -o ${user} -g users \
        /var/lib/agent-state \
        /var/lib/agent-state/.claude \
        /var/lib/agent-state/pi
      install -d -m 0755 -o ${user} -g users /home/${user}/work
      ensure_link /var/lib/agent-state/.claude /home/${user}/.claude
      ensure_link /mnt/host/AGENTS.md /var/lib/agent-state/.claude/CLAUDE.md
      ensure_link /mnt/host/AGENTS.md /var/lib/agent-state/pi/AGENTS.md
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
