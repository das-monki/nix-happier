# nix-happier

Nix flake for building and deploying [Happier](https://github.com/happier-dev/happier) Server and CLI.

> **Pre-release notice:** The `happier` flake input currently tracks the `main` branch. This will be pinned to tagged releases once Happier reaches a stable version. Updates to this flake are made manually for now — run `nix run .#update` to pull the latest.

## Flake outputs

| Output | Description |
|--------|-------------|
| `packages.happier-server` | Happier Server (full + light mode binaries) |
| `packages.happier-cli` | Happier CLI |
| `nixosModules.happier-server` | NixOS module for running Happier Server as a systemd service |
| `checks.deadnix` | Unused binding detection |
| `checks.statix` | Nix anti-pattern linting |
| `checks.nixos-happier-server-light` | NixOS VM integration test (Linux only) |
| `apps.update-prisma-hashes` | Update Prisma engine binary hashes |
| `apps.update` | Update all flake inputs + Prisma hashes |
| `devShells.default` | Dev shell with git and nixfmt |

Supported systems: `aarch64-darwin`, `aarch64-linux`, `x86_64-linux`

## Quick start

Add the flake input to your NixOS configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nix-happier.url = "github:happier-dev/nix-happier";
  };

  outputs = { nixpkgs, nix-happier, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-happier.nixosModules.happier-server
        {
          services.happier-server = {
            enable = true;
            package = nix-happier.packages.x86_64-linux.happier-server;
            mode = "light"; # or "full"
          };
        }
      ];
    };
  };
}
```

### Light mode (SQLite, no external deps)

See [`examples/happier-server-light.nix`](examples/happier-server-light.nix) for a minimal configuration. Light mode uses SQLite with WAL enabled automatically — no PostgreSQL, Redis, or MinIO required.

### Full mode (PostgreSQL + Redis + MinIO)

```nix
{
  services.happier-server = {
    enable = true;
    package = nix-happier.packages.x86_64-linux.happier-server;
    mode = "full";
    port = 3005;
    environmentFile = "/run/secrets/happier-env"; # must contain HANDY_MASTER_SECRET

    database = {
      name = "happier";
      user = "happier";
      createLocally = true; # provisions PostgreSQL 15
    };

    redis.createLocally = true;

    minio = {
      createLocally = true;
      bucket = "happier";
      rootCredentialsFile = "/run/secrets/minio-creds"; # MINIO_ROOT_USER + MINIO_ROOT_PASSWORD
    };
  };
}
```

## Module options

### Core

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable Happier Server |
| `package` | package | — | The `happier-server` package to use |
| `port` | port | `3005` | Port to listen on |
| `mode` | `"full"` \| `"light"` | `"full"` | `full` = PostgreSQL + Redis + MinIO; `light` = SQLite only |
| `environmentFile` | path \| null | `null` | Secrets file (`KEY=value`). Should contain `HANDY_MASTER_SECRET` |

### Database (full mode)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `database.name` | string | `"happier"` | PostgreSQL database name |
| `database.user` | string | `"happier"` | PostgreSQL user |
| `database.createLocally` | bool | `true` | Provision PostgreSQL locally |

### Redis (full mode)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `redis.createLocally` | bool | `true` | Provision Redis locally |

### MinIO (full mode)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `minio.createLocally` | bool | `true` | Provision MinIO locally for S3-compatible storage |
| `minio.bucket` | string | `"happier"` | MinIO bucket name |
| `minio.rootCredentialsFile` | path \| null | `null` | File with `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` |

## Examples

The [`examples/`](examples/) directory contains ready-to-use NixOS configurations. These examples are tested in CI via `nix flake check` (the light-mode example runs as a NixOS VM integration test on Linux).

## Development

Enter the dev shell:

```sh
nix develop
```

Available commands inside the shell:

| Command | Description |
|---------|-------------|
| `fmt` | Format Nix files |
| `update` | Update flake inputs + Prisma hashes |

Run linting and integration tests:

```sh
nix flake check
```

Update all inputs and refresh Prisma engine hashes:

```sh
nix run .#update
```

## Repo structure

```
.
├── flake.nix                          # Flake entrypoint
├── flake.lock
├── packages.nix                       # happier-server + happier-cli derivations
├── checks.nix                         # deadnix, statix, NixOS VM test
├── devshell.nix                       # Dev shell with commands
├── modules/
│   └── nixos/
│       └── happier-server.nix         # NixOS module
├── packages/
│   └── prisma-engines-prebuilt.nix    # Prebuilt Prisma engine binaries
├── examples/
│   └── happier-server-light.nix       # Light mode example config
└── .github/
    └── workflows/
        └── nix-build.yml              # CI workflow
```
