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
          ];
        };
      };
    };
}
