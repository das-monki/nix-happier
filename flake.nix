{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    devshell = {
      url = "github:numtide/devshell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.url = "github:hercules-ci/flake-parts";

    # The happier monorepo source (fetched as a plain source tree, not evaluated as a flake)
    happier = {
      url = "github:happier-dev/happier";
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
          lib,
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt-tree;

          apps.update-prisma-hashes = {
            type = "app";
            meta.description = "Update Prisma engine binary hashes in prisma-engines-prebuilt.nix";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "update-prisma-hashes";
                runtimeInputs = with pkgs; [
                  jq
                  gnugrep
                  gnused
                  coreutils
                ];
                text = ''
                  NIX_FILE="./packages/prisma-engines-prebuilt.nix"
                  YARN_LOCK="${inputs.happier}/yarn.lock"

                  if [ ! -f "$NIX_FILE" ]; then
                    echo "ERROR: $NIX_FILE not found — run from the nix-happier repo root" >&2
                    exit 1
                  fi

                  # Extract engine hash from yarn.lock
                  ENGINE_HASH=$(grep '@prisma/engines-version' "$YARN_LOCK" | head -1 | grep -oE '[a-f0-9]{40}')

                  if [ -z "$ENGINE_HASH" ]; then
                    echo "ERROR: Could not find @prisma/engines-version in yarn.lock" >&2
                    exit 1
                  fi

                  echo "Engine commit hash: $ENGINE_HASH"

                  BASE_URL="https://binaries.prisma.sh/all_commits/$ENGINE_HASH"

                  # Platform configs: system prisma-platform queryEngineFile schemaEngineFile
                  PLATFORMS=(
                    "aarch64-linux linux-arm64-openssl-3.0.x libquery_engine.so.node.gz schema-engine.gz"
                    "aarch64-darwin darwin-arm64 libquery_engine.dylib.node.gz schema-engine.gz"
                    "x86_64-linux debian-openssl-3.0.x libquery_engine.so.node.gz schema-engine.gz"
                  )

                  declare -A NEW_HASHES

                  for entry in "''${PLATFORMS[@]}"; do
                    read -r sys plat qe_file se_file <<< "$entry"
                    echo ""
                    echo "Prefetching $sys binaries..."

                    qe_url="$BASE_URL/$plat/$qe_file"
                    se_url="$BASE_URL/$plat/$se_file"

                    echo "  Fetching: $qe_url"
                    qe_hash=$(nix store prefetch-file --json --hash-type sha256 "$qe_url" | jq -r .hash)
                    echo "  -> $qe_hash"

                    echo "  Fetching: $se_url"
                    se_hash=$(nix store prefetch-file --json --hash-type sha256 "$se_url" | jq -r .hash)
                    echo "  -> $se_hash"

                    NEW_HASHES["''${sys}_qe"]="$qe_hash"
                    NEW_HASHES["''${sys}_se"]="$se_hash"
                  done

                  echo ""
                  echo "Updating hashes in $NIX_FILE..."

                  # Read current hashes in order of appearance
                  mapfile -t CURRENT_HASHES < <(grep -oP 'Hash = "\K[^"]+' "$NIX_FILE")

                  # Order must match nix file: aarch64-linux QE, SE, aarch64-darwin QE, SE, x86_64-linux QE, SE
                  ORDERED_NEW=(
                    "''${NEW_HASHES[aarch64-linux_qe]}"
                    "''${NEW_HASHES[aarch64-linux_se]}"
                    "''${NEW_HASHES[aarch64-darwin_qe]}"
                    "''${NEW_HASHES[aarch64-darwin_se]}"
                    "''${NEW_HASHES[x86_64-linux_qe]}"
                    "''${NEW_HASHES[x86_64-linux_se]}"
                  )

                  for i in "''${!CURRENT_HASHES[@]}"; do
                    old="''${CURRENT_HASHES[$i]}"
                    new="''${ORDERED_NEW[$i]}"
                    if [ "$old" != "$new" ]; then
                      sed -i "s|$old|$new|g" "$NIX_FILE"
                      echo "  Updated: $old -> $new"
                    else
                      echo "  Unchanged: $old"
                    fi
                  done

                  echo ""
                  echo "Done! Verify with: nix build .#happier-server"
                '';
              }
            );
          };

          apps.update = {
            type = "app";
            meta.description = "Update all flake inputs and refresh Prisma engine hashes";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "update";
                text = ''
                  echo "Updating flake inputs..."
                  nix flake update

                  echo ""
                  echo "Updating Prisma engine hashes..."
                  nix run .#update-prisma-hashes
                '';
              }
            );
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
