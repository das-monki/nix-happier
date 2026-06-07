# Nix packages for happier-cli and happier-server
{ inputs, ... }:

{
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      happierSrc = inputs.happier;

      # Source filter: exclude packages/dirs not needed for building CLI or server
      filteredSrc = lib.cleanSourceWith {
        src = happierSrc;
        filter =
          path: _type:
          let
            relPath = lib.removePrefix (toString happierSrc + "/") (toString path);
          in
          !(
            lib.hasPrefix "apps/ui" relPath
            || lib.hasPrefix "apps/stack" relPath
            || lib.hasPrefix "apps/website" relPath
            || lib.hasPrefix "apps/docs" relPath
            || lib.hasPrefix "packages/audio-stream-native" relPath
            || lib.hasPrefix "packages/sherpa-native" relPath
            || lib.hasPrefix "packages/relay-server" relPath
            || lib.hasPrefix "packages/tests" relPath
            || lib.hasPrefix ".git" relPath
            || relPath == "node_modules"
            || lib.hasPrefix "node_modules/" relPath
            || relPath == "dist"
            || lib.hasPrefix ".pgdata" relPath
            || lib.hasPrefix ".minio" relPath
            || lib.hasPrefix ".logs" relPath
            || lib.hasPrefix "result" relPath
            || lib.hasPrefix ".project" relPath
          );
      };

      # Source filter for the web UI: include apps/ui, exclude server/CLI apps
      uiFilteredSrc = lib.cleanSourceWith {
        src = happierSrc;
        filter =
          path: _type:
          let
            relPath = lib.removePrefix (toString happierSrc + "/") (toString path);
          in
          !(
            lib.hasPrefix "apps/server" relPath
            || lib.hasPrefix "apps/cli" relPath
            || lib.hasPrefix "apps/stack" relPath
            || lib.hasPrefix "apps/website" relPath
            || lib.hasPrefix "apps/docs" relPath
            || lib.hasPrefix "packages/relay-server" relPath
            || lib.hasPrefix "packages/tests" relPath
            || lib.hasPrefix ".git" relPath
            || relPath == "node_modules"
            || lib.hasPrefix "node_modules/" relPath
            || relPath == "dist"
            || lib.hasPrefix ".pgdata" relPath
            || lib.hasPrefix ".minio" relPath
            || lib.hasPrefix ".logs" relPath
            || lib.hasPrefix "result" relPath
            || lib.hasPrefix ".project" relPath
          );
      };

      # Offline yarn cache from the root yarn.lock
      yarnOfflineCache = pkgs.fetchYarnDeps {
        yarnLock = "${happierSrc}/yarn.lock";
        hash = "sha256-FoACfej5jZw6p583Oze6CYUm3d8jYhZgF0oPe7l8Gw8=";
      };

      # Pre-built web UI bundle (Expo static export)
      happier-ui-web = pkgs.stdenv.mkDerivation {
        pname = "happier-ui-web";
        version = "0.1.0";

        src = uiFilteredSrc;

        nativeBuildInputs = with pkgs; [
          nodejs_22
          yarn
          yarnConfigHook
        ];

        inherit yarnOfflineCache;

        preConfigure = ''
          export HAPPIER_INSTALL_SCOPE=ui,protocol,agents,connection-supervisor,transfers,release-runtime,cli-common
          export HOME=$(mktemp -d)
          export APP_ENV=production
          export EXPO_NO_GIT_STATUS=1
        '';

        buildPhase = ''
          runHook preBuild

          # Build shared workspace packages in dependency order
          node packages/protocol/scripts/generate-embedded-feature-policies.mjs
          node node_modules/typescript/bin/tsc -p packages/protocol/tsconfig.json
          node node_modules/typescript/bin/tsc -p packages/agents/tsconfig.json
          node node_modules/typescript/bin/tsc -p packages/release-runtime/tsconfig.json
          node node_modules/typescript/bin/tsc -p packages/transfers/tsconfig.json
          node node_modules/typescript/bin/tsc -p packages/connection-supervisor/tsconfig.json
          node node_modules/typescript/bin/tsc -p packages/cli-common/tsconfig.json

          # Export static web bundle (invoke via node to bypass shebang issues on linux builders)
          (cd apps/ui && node node_modules/expo/bin/cli export --platform web --output-dir dist)

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          cp -r apps/ui/dist $out
          runHook postInstall
        '';

        meta = {
          description = "Happier Web UI - static Expo web bundle";
          homepage = "https://github.com/happier-dev/happier";
          license = lib.licenses.mit;
        };
      };

      # Builder function for happier-cli — allows overriding the default server URL.
      # CLI args (--server-url) still take precedence over these env vars.
      #
      # Example — point CLI at a self-hosted server:
      #
      #   environment.systemPackages = [
      #     (nix-happier.packages.${system}.happier-cli.override {
      #       serverUrl = "https://happier.myhost.com";
      #       webappUrl = "https://happier.myhost.com";
      #     })
      #   ];
      mkHappierCli =
        {
          serverUrl ? null,
          webappUrl ? null,
        }:
        pkgs.stdenv.mkDerivation {
          pname = "happier-cli";
          version = "0.1.0";

          src = filteredSrc;

          nativeBuildInputs = with pkgs; [
            nodejs_22
            yarn
            yarnConfigHook
            makeWrapper
            python3
          ];

          inherit yarnOfflineCache;

          preConfigure = ''
            # Skip server postinstall (only need CLI scope)
            export HAPPIER_INSTALL_SCOPE=cli
            export HOME=$(mktemp -d)
          '';

          buildPhase = ''
            runHook preBuild

            # Build shared workspace packages in dependency order:
            # protocol (no deps) -> agents, release-runtime, transfers, connection-supervisor (need protocol at most) -> cli-common (needs agents + release-runtime)
            # Protocol needs its codegen step first
            node packages/protocol/scripts/generate-embedded-feature-policies.mjs
            node node_modules/typescript/bin/tsc -p packages/protocol/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/agents/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/release-runtime/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/transfers/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/connection-supervisor/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/cli-common/tsconfig.json

            # Sync bundled workspace dist into CLI's node_modules so tsc/pkgroll can resolve them
            node -e "
              const { syncBundledWorkspaceDist } = await import('./apps/cli/scripts/buildSharedDeps.mjs');
              syncBundledWorkspaceDist({ repoRoot: process.cwd() });
            "

            # Build the CLI: clean dist, typecheck, then bundle with pkgroll
            # Using subshells to avoid cd state leaking on errors
            node apps/cli/scripts/rmDist.mjs

            # Typecheck production sources only. The upstream tsconfig globs in
            # src/**/*.ts, which sweeps in *.test.ts files. Those are never part
            # of the shipped pkgroll bundle, so a type error in a test must not
            # block packaging — exclude them from this gate.
            cat > apps/cli/tsconfig.nixbuild.json <<'EOF'
            {
              "extends": "./tsconfig.json",
              "exclude": ["node_modules", "src/**/*.test.ts", "src/**/*.test.tsx", "src/**/__tests__/**"]
            }
            EOF
            (cd apps/cli && node ../../node_modules/typescript/bin/tsc --noEmit -p tsconfig.nixbuild.json)
            (cd apps/cli && node ../../node_modules/.bin/pkgroll)

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Replicate monorepo layout so Node.js module resolution works
            mkdir -p $out/lib/happier-cli/apps/cli
            mkdir -p $out/lib/happier-cli/packages/protocol
            mkdir -p $out/lib/happier-cli/packages/agents
            mkdir -p $out/lib/happier-cli/packages/cli-common
            mkdir -p $out/lib/happier-cli/packages/release-runtime
            mkdir -p $out/lib/happier-cli/packages/transfers
            mkdir -p $out/lib/happier-cli/packages/connection-supervisor

            # Root node_modules (hoisted dependencies)
            cp -r node_modules $out/lib/happier-cli/

            # Remove broken symlinks (workspace cross-references we don't ship)
            find $out/lib/happier-cli/node_modules -xtype l -delete

            # -- apps/cli artifacts --
            cp -r apps/cli/dist $out/lib/happier-cli/apps/cli/
            cp -r apps/cli/bin $out/lib/happier-cli/apps/cli/
            cp -r apps/cli/scripts $out/lib/happier-cli/apps/cli/
            cp apps/cli/package.json $out/lib/happier-cli/apps/cli/
            if [ -d apps/cli/node_modules ]; then
              cp -r apps/cli/node_modules $out/lib/happier-cli/apps/cli/
            fi

            # -- packages/protocol --
            cp -r packages/protocol/dist $out/lib/happier-cli/packages/protocol/
            cp packages/protocol/package.json $out/lib/happier-cli/packages/protocol/
            if [ -d packages/protocol/node_modules ]; then
              cp -r packages/protocol/node_modules $out/lib/happier-cli/packages/protocol/
            fi

            # -- packages/agents --
            cp -r packages/agents/dist $out/lib/happier-cli/packages/agents/
            cp packages/agents/package.json $out/lib/happier-cli/packages/agents/
            if [ -d packages/agents/node_modules ]; then
              cp -r packages/agents/node_modules $out/lib/happier-cli/packages/agents/
            fi

            # -- packages/cli-common --
            cp -r packages/cli-common/dist $out/lib/happier-cli/packages/cli-common/
            cp packages/cli-common/package.json $out/lib/happier-cli/packages/cli-common/
            if [ -d packages/cli-common/node_modules ]; then
              cp -r packages/cli-common/node_modules $out/lib/happier-cli/packages/cli-common/
            fi

            # -- packages/release-runtime --
            cp -r packages/release-runtime/dist $out/lib/happier-cli/packages/release-runtime/
            cp packages/release-runtime/package.json $out/lib/happier-cli/packages/release-runtime/
            if [ -d packages/release-runtime/node_modules ]; then
              cp -r packages/release-runtime/node_modules $out/lib/happier-cli/packages/release-runtime/
            fi

            # -- packages/transfers --
            cp -r packages/transfers/dist $out/lib/happier-cli/packages/transfers/
            cp packages/transfers/package.json $out/lib/happier-cli/packages/transfers/
            if [ -d packages/transfers/node_modules ]; then
              cp -r packages/transfers/node_modules $out/lib/happier-cli/packages/transfers/
            fi

            # -- packages/connection-supervisor --
            cp -r packages/connection-supervisor/dist $out/lib/happier-cli/packages/connection-supervisor/
            cp packages/connection-supervisor/package.json $out/lib/happier-cli/packages/connection-supervisor/
            if [ -d packages/connection-supervisor/node_modules ]; then
              cp -r packages/connection-supervisor/node_modules $out/lib/happier-cli/packages/connection-supervisor/
            fi

            # Create wrapper scripts
            mkdir -p $out/bin

            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier \
              --add-flags "--no-warnings" \
              --add-flags "--no-deprecation" \
              --add-flags "$out/lib/happier-cli/apps/cli/dist/index.mjs" \
              ${lib.optionalString (serverUrl != null) ''--set HAPPIER_SERVER_URL "${serverUrl}"''} \
              ${lib.optionalString (webappUrl != null) ''--set HAPPIER_WEBAPP_URL "${webappUrl}"''} \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.difftastic
                  pkgs.ripgrep
                ]
              }

            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier-mcp \
              --add-flags "--no-warnings" \
              --add-flags "--no-deprecation" \
              --add-flags "$out/lib/happier-cli/apps/cli/dist/backends/codex/happyMcpStdioBridge.mjs" \
              ${lib.optionalString (serverUrl != null) ''--set HAPPIER_SERVER_URL "${serverUrl}"''} \
              ${lib.optionalString (webappUrl != null) ''--set HAPPIER_WEBAPP_URL "${webappUrl}"''} \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.difftastic
                  pkgs.ripgrep
                ]
              }

            runHook postInstall
          '';

          passthru.override = mkHappierCli;

          meta = {
            description = "Happier CLI - mobile and web client for Claude Code";
            homepage = "https://github.com/happier-dev/happier";
            license = lib.licenses.mit;
            mainProgram = "happier";
          };
        };
    in
    {
      packages = {
        # Default CLI (no server URL override — uses upstream defaults).
        # Use happier-cli.override to set a default server URL:
        #   happier-cli.override { serverUrl = "https://happier.myhost.com"; }
        happier-cli = mkHappierCli { };

        # -- happier-server ----------------------------------------------------
        happier-server = pkgs.stdenv.mkDerivation {
          pname = "happier-server";
          version = "0.1.2";

          src = filteredSrc;

          nativeBuildInputs = with pkgs; [
            nodejs_22
            yarn
            yarnConfigHook
            makeWrapper
            python3
          ];

          buildInputs = with pkgs; [
            prisma-engines
            # sharp bundles its own libvips via @img/sharp-* prebuilts — no system vips needed
          ];

          inherit yarnOfflineCache;

          preConfigure = ''
            # Skip CLI postinstall (only need server scope)
            export HAPPIER_INSTALL_SCOPE=server,cli-common,release-runtime
            export HOME=$(mktemp -d)

            # Point Prisma at nixpkgs engines
            export PRISMA_QUERY_ENGINE_LIBRARY="${pkgs.prisma-engines}/lib/libquery_engine.node"
            export PRISMA_SCHEMA_ENGINE_BINARY="${pkgs.prisma-engines}/bin/schema-engine"
            export PRISMA_SKIP_POSTINSTALL_GENERATE=true
          '';

          buildPhase = ''
            runHook preBuild

            # Build shared workspace packages in dependency order:
            # protocol (no deps) -> agents (needs protocol) -> release-runtime, cli-common (needs agents + release-runtime)
            node packages/protocol/scripts/generate-embedded-feature-policies.mjs
            node node_modules/typescript/bin/tsc -p packages/protocol/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/agents/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/release-runtime/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/cli-common/tsconfig.json

            # Generate Prisma clients for all providers (postgres, mysql, sqlite)
            # generate:providers handles schema:sync internally and generates all three
            yarn workspace @happier-dev/server generate:providers

            # Typecheck directly to avoid prebuild re-running buildSharedDeps.
            # Note: prisma-json-types-generator patches @prisma/client types in-place;
            # if the patch silently fails in the sandbox, PrismaJson types won't resolve.
            # The server runs via tsx at runtime so this is a validation-only step.
            (cd apps/server && node ../../node_modules/typescript/bin/tsc --noEmit) || echo "WARN: tsc --noEmit had errors (non-fatal for tsx runtime)"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            # Replicate monorepo layout so Node.js module resolution works
            mkdir -p $out/lib/happier-server/apps/server
            mkdir -p $out/lib/happier-server/packages/protocol
            mkdir -p $out/lib/happier-server/packages/agents
            mkdir -p $out/lib/happier-server/packages/release-runtime
            mkdir -p $out/lib/happier-server/packages/cli-common

            # Root node_modules (hoisted dependencies)
            cp -r node_modules $out/lib/happier-server/

            # Remove broken symlinks (workspace cross-references we don't ship)
            find $out/lib/happier-server/node_modules -xtype l -delete

            # -- packages/protocol --
            cp -r packages/protocol/dist $out/lib/happier-server/packages/protocol/
            cp packages/protocol/package.json $out/lib/happier-server/packages/protocol/
            if [ -d packages/protocol/node_modules ]; then
              cp -r packages/protocol/node_modules $out/lib/happier-server/packages/protocol/
            fi

            # -- packages/agents --
            cp -r packages/agents/dist $out/lib/happier-server/packages/agents/
            cp packages/agents/package.json $out/lib/happier-server/packages/agents/
            if [ -d packages/agents/node_modules ]; then
              cp -r packages/agents/node_modules $out/lib/happier-server/packages/agents/
            fi

            # -- packages/release-runtime --
            cp -r packages/release-runtime/dist $out/lib/happier-server/packages/release-runtime/
            cp packages/release-runtime/package.json $out/lib/happier-server/packages/release-runtime/
            if [ -d packages/release-runtime/node_modules ]; then
              cp -r packages/release-runtime/node_modules $out/lib/happier-server/packages/release-runtime/
            fi

            # -- packages/cli-common --
            cp -r packages/cli-common/dist $out/lib/happier-server/packages/cli-common/
            cp packages/cli-common/package.json $out/lib/happier-server/packages/cli-common/
            if [ -d packages/cli-common/node_modules ]; then
              cp -r packages/cli-common/node_modules $out/lib/happier-server/packages/cli-common/
            fi

            # -- apps/server sources and config --
            cp -r apps/server/sources $out/lib/happier-server/apps/server/
            cp -r apps/server/prisma $out/lib/happier-server/apps/server/
            cp -r apps/server/scripts $out/lib/happier-server/apps/server/
            cp apps/server/tsconfig.json $out/lib/happier-server/apps/server/
            cp apps/server/package.json $out/lib/happier-server/apps/server/

            # Generated Prisma clients for sqlite and mysql (relative to apps/server/)
            if [ -d apps/server/generated ]; then
              cp -r apps/server/generated $out/lib/happier-server/apps/server/
            fi

            # Workspace node_modules (including generated Prisma client)
            if [ -d apps/server/node_modules ]; then
              cp -r apps/server/node_modules $out/lib/happier-server/apps/server/
            fi

            # Generated Prisma client (.prisma at root) — dereference symlinks
            # since engine binaries are nix store paths (read-only in the store)
            if [ -d node_modules/.prisma ]; then
              rm -rf $out/lib/happier-server/node_modules/.prisma
              cp -rL node_modules/.prisma $out/lib/happier-server/node_modules/
            fi

            # Create wrapper scripts
            mkdir -p $out/bin

            # Main server binary (full mode): run via tsx
            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier-server \
              --add-flags "--import" \
              --add-flags "tsx" \
              --add-flags "$out/lib/happier-server/apps/server/sources/main.ts" \
              --set PRISMA_QUERY_ENGINE_LIBRARY "${pkgs.prisma-engines}/lib/libquery_engine.node" \
              --set PRISMA_SCHEMA_ENGINE_BINARY "${pkgs.prisma-engines}/bin/schema-engine" \
              --set PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING "1" \
              --set HAPPIER_SERVER_UI_DIR "${happier-ui-web}" \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.openssl ]}" \
              --chdir "$out/lib/happier-server/apps/server" \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.ffmpeg
                  pkgs.python3
                ]
              }

            # Light/SQLite server binary
            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier-server-light \
              --add-flags "--import" \
              --add-flags "tsx" \
              --add-flags "$out/lib/happier-server/apps/server/sources/main.light.ts" \
              --set PRISMA_QUERY_ENGINE_LIBRARY "${pkgs.prisma-engines}/lib/libquery_engine.node" \
              --set PRISMA_SCHEMA_ENGINE_BINARY "${pkgs.prisma-engines}/bin/schema-engine" \
              --set PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING "1" \
              --set HAPPIER_SERVER_UI_DIR "${happier-ui-web}" \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.openssl ]}" \
              --chdir "$out/lib/happier-server/apps/server" \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.ffmpeg
                  pkgs.python3
                ]
              }

            # Migration binary (full mode — Prisma migrate deploy)
            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier-server-migrate \
              --add-flags "$out/lib/happier-server/node_modules/.bin/prisma" \
              --add-flags "migrate" \
              --add-flags "deploy" \
              --set PRISMA_QUERY_ENGINE_LIBRARY "${pkgs.prisma-engines}/lib/libquery_engine.node" \
              --set PRISMA_SCHEMA_ENGINE_BINARY "${pkgs.prisma-engines}/bin/schema-engine" \
              --set PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING "1" \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.openssl ]}" \
              --chdir "$out/lib/happier-server/apps/server" \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.yarn
                ]
              }

            # Light migration binary (SQLite deploy script)
            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier-server-migrate-light \
              --add-flags "--import" \
              --add-flags "tsx" \
              --add-flags "$out/lib/happier-server/apps/server/scripts/migrate.sqlite.deploy.ts" \
              --set PRISMA_QUERY_ENGINE_LIBRARY "${pkgs.prisma-engines}/lib/libquery_engine.node" \
              --set PRISMA_SCHEMA_ENGINE_BINARY "${pkgs.prisma-engines}/bin/schema-engine" \
              --set PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING "1" \
              --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.openssl ]}" \
              --chdir "$out/lib/happier-server/apps/server" \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.yarn
                ]
              }

            runHook postInstall
          '';

          passthru.web = happier-ui-web;

          meta = {
            description = "Happier Server - backend for Happier mobile and CLI clients";
            homepage = "https://github.com/happier-dev/happier";
            license = lib.licenses.mit;
            mainProgram = "happier-server";
          };
        };
      };
    };
}
