{
  description = "Isolated NixOS microVM for AI Agents (standalone, non-NixOS host)";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs"; # dedupe evaluation, not an extra trust boundary
    nixpkgs-opencode.url =
      "github:NixOS/nixpkgs/99b76fd9b396189197d2ecce519ab6d7cd522ab5";
  };

  outputs =
    {
      self,
      nixpkgs,
      microvm,
      nixpkgs-opencode,
    } @ inputs:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # --- The guest itself ----------------------------------------------
      # microvm.nixosModules.microvm (not .host!) is the module that makes a
      # nixosConfiguration buildable/runnable as a standalone package rather
      # than a systemd service managed by a NixOS host.
      nixosConfigurations.ai-agent = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs;
        };
        modules = [
          microvm.nixosModules.microvm
          ./vm.nix
        ];
      };

      packages.${system} = {
        # The VM's own runner (qemu + kernel + disk args), no daemons started.
        ai-agent = self.nixosConfigurations.ai-agent.config.microvm.declaredRunner;
        # `nix run .#run-ai-agent` (or plain `nix run`, see apps below):
        # starts the two virtiofsd daemons this VM's shares depend on — each
        # forced read-only at the daemon level, not just via a guest-side
        # mount option a guest-root could remount rw — waits for their
        # sockets, then boots the VM.
        run-ai-agent = pkgs.writeShellApplication {
          name = "run-ai-agent";
          runtimeInputs = [
            pkgs.virtiofsd
            pkgs.coreutils
          ];

          text = ''
            runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ai-agent-microvm"
            mkdir -p "$runtime_dir"
            chmod 700 "$runtime_dir"
            cd "$runtime_dir"

            cleanup() {
              jobs -p | xargs -r kill 2>/dev/null || true
            }
            trap cleanup EXIT

            echo "Starting virtiofsd: read-only /nix/store..."
            virtiofsd \
              --socket-path="$runtime_dir/ro-store.sock" \
              --shared-dir="/nix/store" \
              --readonly &

            echo "Starting virtiofsd: read-only workspace..."
            virtiofsd \
              --socket-path="$runtime_dir/host-ro.sock" \
              --shared-dir="/home/vi/images/llm-jail/shared" \
              --readonly &

            for sock in ro-store.sock host-ro.sock; do
              for _ in $(seq 1 50); do
                [ -S "$runtime_dir/$sock" ] && break
                sleep 0.1
              done

              if [ ! -S "$runtime_dir/$sock" ]; then
                echo "error: virtiofsd socket did not appear: $sock" >&2
                exit 1
              fi
            done

            runner="${self.packages.${system}.ai-agent}/bin/microvm-run"

            if [ ! -x "$runner" ]; then
              echo "error: VM runner is not executable: $runner" >&2
              exit 1
            fi

            echo "Starting ai-agent microVM..."
            exec "$runner"
          '';
        };

      };
      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.run-ai-agent}/bin/run-ai-agent";
      };
    };
}
