{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";

    # The happier monorepo source (fetched as a plain source tree, not evaluated as a flake)
    # Pinned to a stack release tag; updated automatically by update-happier.yml
    happier = {
      url = "github:happier-dev/happier/stack-v0.1.0-preview.1771759103.67820";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        inputs.devshell.flakeModule
        ./devshell.nix
        ./packages.nix
        ./checks.nix
      ];

      flake = {
        nixosModules.happier-server = ./modules/nixos/happier-server.nix;
        nixosModules.default = self.nixosModules.happier-server;
      };

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt-tree;

          # nix run .#update-happier — update the happier input to the latest stack release tag
          apps.update-happier =
            let
              script = pkgs.writeShellApplication {
                name = "update-happier";
                meta.description = "Update the happier flake input to the latest stack release tag";
                runtimeInputs = with pkgs; [
                  gh
                  gnused
                  gnugrep
                  coreutils
                ];
                text = ''
                  FLAKE_NIX="$(pwd)/flake.nix"
                  if [[ ! -f "$FLAKE_NIX" ]]; then
                    echo "error: flake.nix not found in current directory" >&2
                    exit 1
                  fi

                  # Get latest stack-v* release tag from happier repo
                  LATEST_TAG=$(gh release list -R happier-dev/happier \
                    --json tagName -q '.[].tagName' | grep '^stack-v' | head -1 || true)

                  if [[ -z "$LATEST_TAG" ]]; then
                    echo "error: no stack-v* release tags found" >&2
                    exit 1
                  fi

                  # Extract current tag from flake.nix
                  CURRENT_TAG=$(grep 'github:happier-dev/happier/' "$FLAKE_NIX" \
                    | sed 's|.*github:happier-dev/happier/||;s|".*||')

                  echo "Current: $CURRENT_TAG"
                  echo "Latest:  $LATEST_TAG"

                  if [[ "$CURRENT_TAG" == "$LATEST_TAG" ]]; then
                    echo "Already up to date."
                    exit 0
                  fi

                  # Update tag in flake.nix
                  sed -i "s|github:happier-dev/happier/[^\"]*|github:happier-dev/happier/$LATEST_TAG|" "$FLAKE_NIX"

                  # Update the lockfile to match
                  nix flake update happier

                  echo "Updated happier: $CURRENT_TAG -> $LATEST_TAG"
                '';
              };
            in
            {
              type = "app";
              program = pkgs.lib.getExe script;
              meta.description = "Update the happier flake input to the latest stack release tag";
            };

          _module.args.pkgs = import self.inputs.nixpkgs {
            inherit system;
            overlays = [
              # Prebuilt Prisma engines — version auto-derived from yarn.lock.
              # When @prisma/client is bumped, run: ./scripts/update-prisma-hashes.sh
              (final: _prev: {
                prisma-engines = import ./packages/prisma-engines-prebuilt.nix {
                  pkgs = final;
                  inherit (final) lib;
                  yarnLock = "${inputs.happier}/yarn.lock";
                };
              })
            ];
          };
        };
    };
}
