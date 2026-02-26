# Minimal Happier Server config — light mode (SQLite, no external dependencies).
#
# Used by the CI integration test (nix flake check). The consumer must set
# services.happier-server.package externally.
#
# For a production-ready setup with TLS and Tailscale, see:
#   examples/happier-server-tailscale.nix
{
  services.happier-server = {
    enable = true;
    mode = "light";
  };
}
