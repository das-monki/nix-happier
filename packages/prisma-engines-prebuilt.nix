# Fetch prebuilt Prisma engine binaries instead of compiling from source.
#
# The engine commit hash is auto-derived from @prisma/engines-version in yarn.lock.
# Only the binary download hashes below need manual updating when Prisma is bumped.
#
# When @prisma/client is bumped and yarn.lock changes:
#   1. nix build will fail with a hash mismatch (the engine hash changed → new URL)
#   2. Run: ./scripts/update-prisma-hashes.sh
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
  # Update these hashes after bumping Prisma: ./scripts/update-prisma-hashes.sh
  platformConfig = {
    "aarch64-linux" = {
      platform = "linux-arm64-openssl-3.0.x";
      queryEngineFile = "libquery_engine.so.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "sha256-9GxcSfrXQC/TzsW8fNgn5YcolXKUMKoHFbhKVIsqd64=";
      schemaEngineHash = "sha256-LxtS3kmqbWOm+uSIvhigXuFDBcAk195SvBmyKFvK/SY=";
    };
    "aarch64-darwin" = {
      platform = "darwin-arm64";
      queryEngineFile = "libquery_engine.dylib.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "sha256-hBS1HLFhLDtLDxW5ilXafX7JUgxZNgJpnsJjgjx5gE4=";
      schemaEngineHash = "sha256-qVG2ANgyFOFFv3giqB7jHl1UiKRdOJDmjxxf2RL313M=";
    };
    "x86_64-linux" = {
      platform = "debian-openssl-3.0.x";
      queryEngineFile = "libquery_engine.so.node.gz";
      schemaEngineFile = "schema-engine.gz";
      queryEngineHash = "sha256-04CHLMihcxDG67JJ3AAPT8v7vVHdw2vrV7HtDFTG1hA=";
      schemaEngineHash = "sha256-bB39/jRThIewiP0hsxUhR+G9PJ0MALT8bsrkDOuoPYo=";
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
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.autoPatchelfHook
  ];

  # Runtime libraries needed by the prebuilt Linux binaries.
  # On darwin the Mach-O binaries are self-contained.
  buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
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
