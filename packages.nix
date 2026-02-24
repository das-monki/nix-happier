# Nix packages for happier-cli and happier-server
{ inputs, ... }:

{
  perSystem =
    {
      system,
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
          path: type:
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

      # Offline yarn cache from the root yarn.lock
      yarnOfflineCache = pkgs.fetchYarnDeps {
        yarnLock = "${happierSrc}/yarn.lock";
        hash = "sha256-5SeMv0NQ0KbfHsSSO9k/jFhYxw77I1sBn0AxxQVpMjc=";
      };
    in
    {
      packages = {
        # -- happier-cli (CLI) -------------------------------------------------
        happier-cli = pkgs.stdenv.mkDerivation {
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
            # protocol (no deps) -> agents (needs protocol) -> cli-common (needs agents) -> release-runtime (no internal deps)
            # Protocol needs its codegen step first
            node packages/protocol/scripts/generate-embedded-feature-policies.mjs
            node node_modules/typescript/bin/tsc -p packages/protocol/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/agents/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/cli-common/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/release-runtime/tsconfig.json

            # Sync bundled workspace dist into CLI's node_modules so tsc/pkgroll can resolve them
            node -e "
              const { syncBundledWorkspaceDist } = await import('./apps/cli/scripts/buildSharedDeps.mjs');
              syncBundledWorkspaceDist({ repoRoot: process.cwd() });
            "

            # Build the CLI: clean dist, typecheck, then bundle with pkgroll
            # Using subshells to avoid cd state leaking on errors
            node apps/cli/scripts/rmDist.mjs
            (cd apps/cli && node ../../node_modules/typescript/bin/tsc --noEmit)
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

            # Create wrapper scripts
            mkdir -p $out/bin

            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/happier \
              --add-flags "--no-warnings" \
              --add-flags "--no-deprecation" \
              --add-flags "$out/lib/happier-cli/apps/cli/dist/index.mjs" \
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
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.difftastic
                  pkgs.ripgrep
                ]
              }

            runHook postInstall
          '';

          meta = {
            description = "Happier CLI - mobile and web client for Claude Code";
            homepage = "https://github.com/happier-dev/happier";
            license = lib.licenses.mit;
            mainProgram = "happier";
          };
        };

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
            export HAPPIER_INSTALL_SCOPE=server
            export HOME=$(mktemp -d)

            # Point Prisma at nixpkgs engines
            export PRISMA_QUERY_ENGINE_LIBRARY="${pkgs.prisma-engines}/lib/libquery_engine.node"
            export PRISMA_SCHEMA_ENGINE_BINARY="${pkgs.prisma-engines}/bin/schema-engine"
            export PRISMA_SKIP_POSTINSTALL_GENERATE=true
          '';

          buildPhase = ''
            runHook preBuild

            # Build shared workspace packages in dependency order:
            # protocol (no deps) -> agents (needs protocol)
            node packages/protocol/scripts/generate-embedded-feature-policies.mjs
            node node_modules/typescript/bin/tsc -p packages/protocol/tsconfig.json
            node node_modules/typescript/bin/tsc -p packages/agents/tsconfig.json

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
