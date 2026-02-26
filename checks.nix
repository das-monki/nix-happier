# Flake checks: linting (deadnix, statix) and NixOS VM integration test
{
  self,
  ...
}:
{
  perSystem =
    {
      pkgs,
      lib,
      config,
      ...
    }:
    {
      checks = {
        # Detect unused Nix bindings
        deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
          deadnix --fail ${self}
          touch $out
        '';

        # Detect Nix anti-patterns
        statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
          cd ${self} && statix check .
          touch $out
        '';
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        # NixOS VM integration test — light mode (SQLite-only, no external deps)
        nixos-happier-server-light = pkgs.testers.runNixOSTest {
          name = "happier-server-light";

          nodes.server =
            { ... }:
            {
              imports = [ self.nixosModules.happier-server ];

              services.happier-server = {
                enable = true;
                package = config.packages.happier-server;
                mode = "light";
              };

              virtualisation.memorySize = 2048;
            };

          testScript = ''
            server.wait_for_unit("happier-server-migrate.service")
            server.wait_for_unit("happier-server-sqlite-wal.service")
            server.wait_for_unit("happier-server.service")
            server.wait_for_open_port(3005)

            # Verify server responds (any HTTP response = service is up)
            server.succeed("curl -sf http://localhost:3005/ || curl -sf -o /dev/null -w '%{http_code}' http://localhost:3005/ | grep -qE '^[0-9]'")
          '';
        };
      };
    };
}
