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
          system,
          ...
        }:
        {
          formatter = pkgs.nixfmt-tree;

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
