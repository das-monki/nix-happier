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
            pkgs.nodejs_22
            pkgs.yarn
            pkgs.python3
            pkgs.ffmpeg
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
              name = "dev";
              help = "Run a workspace in dev mode: dev <cli|server|app|website|docs>";
              command = ''
                workspace="''${1:-}"
                case "$workspace" in
                  cli)     yarn workspace @happier-dev/cli dev ;;
                  server)  yarn workspace @happier-dev/server dev ;;
                  app)     yarn workspace @happier-dev/ui start ;;
                  website) yarn workspace @happier-dev/website dev ;;
                  docs)    yarn workspace @happier-dev/docs dev ;;
                  *)
                    echo "Usage: dev <cli|server|app|website|docs>"
                    exit 1
                    ;;
                esac
              '';
            }
            {
              name = "build";
              help = "Build a workspace: build <cli|server|app|website|all>";
              command = ''
                workspace="''${1:-all}"
                case "$workspace" in
                  cli)     yarn workspace @happier-dev/cli build ;;
                  server)  yarn workspace @happier-dev/server build ;;
                  app)     yarn workspace @happier-dev/ui build ;;
                  website) yarn workspace @happier-dev/website build ;;
                  all)     yarn workspaces run build ;;
                  *)
                    echo "Usage: build <cli|server|app|website|all>"
                    exit 1
                    ;;
                esac
              '';
            }
            {
              name = "test";
              help = "Run tests for a workspace: test <cli|server|protocol|all>";
              command = ''
                workspace="''${1:-all}"
                case "$workspace" in
                  cli)      yarn workspace @happier-dev/cli test ;;
                  server)   yarn workspace @happier-dev/server test ;;
                  protocol) yarn workspace @happier-dev/protocol test ;;
                  all)      yarn workspaces run test ;;
                  *)
                    echo "Usage: test <cli|server|protocol|all>"
                    exit 1
                    ;;
                esac
              '';
            }
            {
              name = "format";
              help = "Format code";
              command = ''
                yarn workspaces run format 2>/dev/null || true
              '';
            }
            {
              name = "lint";
              help = "Lint code";
              command = ''
                yarn workspaces run lint 2>/dev/null || true
              '';
            }
            {
              name = "db";
              help = "Run database commands for happier-server: db <start|migrate|seed|studio>";
              command = ''
                cmd="''${1:-start}"
                case "$cmd" in
                  start)   yarn workspace @happier-dev/server db ;;
                  migrate) yarn workspace @happier-dev/server prisma migrate dev ;;
                  seed)    yarn workspace @happier-dev/server prisma db seed ;;
                  studio)  yarn workspace @happier-dev/server prisma studio ;;
                  *)
                    echo "Usage: db <start|migrate|seed|studio>"
                    exit 1
                    ;;
                esac
              '';
            }
            {
              name = "nix-fmt";
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
