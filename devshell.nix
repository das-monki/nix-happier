_:

{
  perSystem =
    {
      pkgs,
      ...
    }:
    {
      devshells = {
        default = {
          packages = [
            pkgs.git
            pkgs.nixfmt-rfc-style
            pkgs.hcloud # Hetzner Cloud CLI for build-happier-remote.sh
            pkgs.awscli2 # AWS CLI for build-happier-remote.sh --provider aws
            pkgs.jq # used by build-happier-remote.sh
          ];

          env = [
            {
              name = "LANG";
              value = "en_US.UTF-8";
            }
          ];

          commands = [
            {
              name = "fmt";
              help = "Format Nix files";
              command = ''
                find . -name "*.nix" -type f -print0 | xargs -0 nixfmt
              '';
            }
            {
              name = "update";
              help = "Update all flake inputs and refresh Prisma engine hashes";
              command = ''
                nix run .#update
              '';
            }
            {
              name = "build-remote";
              help = "Build happier packages on a temporary big aarch64 Hetzner box";
              command = ''
                exec ./scripts/build-happier-remote.sh "$@"
              '';
            }
          ];
        };
      };
    };
}
