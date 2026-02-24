# Fetch prebuilt Prisma engine binaries instead of compiling from source.
#
# The engine commit hash is auto-derived from @prisma/engines-version in yarn.lock.
# Only the binary download hashes below need manual updating when Prisma is bumped.
#
# When @prisma/client is bumped and yarn.lock changes:
#   1. nix build will fail with a hash mismatch (the engine hash changed → new URL)
#   2. Run: ./nix/scripts/update-prisma-hashes.sh
#   3. Commit the updated hashes
{
  pkgs,
  lib,
  yarnLock,
}:
let
  # Auto-derive engine commit hash and version from yarn.lock
  yarnLockContent = builtins.readFile yarnLock;
  lines = builtins.filter builtins.isString (builtins.split "\n" yarnLockContent);

  engineVersionLines = builtins.filter (
    l: builtins.match ".*@prisma/engines-version.*" l != null
  ) lines;
  engineHash = builtins.elemAt (builtins.match ".*\\.([a-f0-9]+).*" (builtins.head engineVersionLines)) 0;

  prismaVersionLines = builtins.filter (l: builtins.match "\"@prisma/engines@.*" l != null) lines;
  version = builtins.elemAt (builtins.match "\"@prisma/engines@([^\"]+)\".*" (builtins.head prismaVersionLines)) 0;

  baseUrl = "https://binaries.prisma.sh/all_commits/${engineHash}";

  # Platform-specific binary config
  # Update these hashes after bumping Prisma: ./nix/update-prisma-hashes.sh
  platformConfig = {
    "aarch64-linux" = {
      platform = "linux-arm64-openssl-3.0.x";
      queryEngineFile = "libquery_engine.so.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "1bkp5a5m8jmq2l3slc4lfaaji1z54zc7rg65rv9jyh6pz94mqv7l";
      schemaEngineHash = "09pxr9djichrpi9dxmr4q02l7qayl0cbx274zak66vda97g546rg";
    };
    "aarch64-darwin" = {
      platform = "darwin-arm64";
      queryEngineFile = "libquery_engine.dylib.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "0kl0g4y84qy2krlh4djr1i9cjzkxv9aqmf8m1x5knb31n4fba544";
      schemaEngineHash = "0wypyw9djpqwizk90f2xlj458p8ywcgah8kqpx2y251jv00bcld9";
    };
    "x86_64-linux" = {
      platform = "debian-openssl-3.0.x";
      queryEngineFile = "libquery_engine.so.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "046nqra0rvdiazmnphyxa6yzpjsg1w0dqjdjxg310wx1r0n8g06k";
      schemaEngineHash = "12ixm3mhrr6advyb800cklybvqa744av68gxi2q8g12k6kzgs7bc";
    };
  };

  cfg =
    platformConfig.${pkgs.system}
      or (throw "prisma-engines-prebuilt: unsupported system ${pkgs.system}");

  queryEngineSrc = pkgs.fetchurl {
    url = "${baseUrl}/${cfg.platform}/${cfg.queryEngineFile}";
    sha256 = cfg.queryEngineHash;
  };

  schemaEngineSrc = pkgs.fetchurl {
    url = "${baseUrl}/${cfg.platform}/${cfg.schemaEngineFile}";
    sha256 = cfg.schemaEngineHash;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "prisma-engines";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.gzip
    pkgs.autoPatchelfHook
  ];

  # Runtime libraries needed by the prebuilt binaries
  buildInputs = [
    pkgs.openssl
    pkgs.stdenv.cc.cc.lib # libstdc++/libgcc
    pkgs.zlib
  ];

  installPhase = ''
    mkdir -p $out/lib $out/bin

    # Query engine (shared library loaded by @prisma/client)
    gzip -dc ${queryEngineSrc} > $out/lib/libquery_engine.node
    chmod 755 $out/lib/libquery_engine.node

    # Schema engine (binary used by prisma migrate)
    gzip -dc ${schemaEngineSrc} > $out/bin/schema-engine
    chmod 755 $out/bin/schema-engine
  '';

  meta = {
    description = "Prisma engines (prebuilt binaries)";
    homepage = "https://github.com/prisma/prisma-engines";
    license = lib.licenses.asl20;
  };
}
