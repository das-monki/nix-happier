# nix-happier — Agent Guidelines

This file provides guidance for AI coding agents (Claude Code, Copilot, Codex, etc.) working in this repo.

## What this repo is

A Nix flake that builds and deploys [Happier](https://github.com/happier-dev/happier) Server and CLI. It does **not** contain application source code — the happier monorepo is fetched as a flake input. This repo only has Nix expressions, NixOS modules, and supporting config.

## Repo layout

```
flake.nix                        # Flake entrypoint (inputs, systems, imports)
packages.nix                     # happier-server + happier-cli derivations
checks.nix                       # deadnix, statix, NixOS VM integration test
devshell.nix                     # Dev shell (fmt, update commands)
modules/nixos/happier-server.nix # NixOS service module
packages/prisma-engines-prebuilt.nix # Prebuilt Prisma engine binaries
examples/happier-server-tailscale.nix # Recommended production setup (Tailscale + TLS)
examples/happier-server-light.nix    # Minimal config (used by CI VM test)
```

## Language and tooling

- **All code is Nix.** There is no TypeScript, Python, or other source code here.
- **Formatter**: `nixfmt-tree` (the flake's `formatter`). Run `nix fmt` to format.
- **Linters**: `deadnix` (unused bindings) and `statix` (anti-patterns). Both run via `nix flake check`.
- **statix config**: `statix.toml` disables `repeated_keys` (W20) — NixOS modules idiomatically use separate top-level assignments with `lib.mkIf` guards.

## Nix style conventions

- Use `nixfmt-tree` style (the RFC-style formatter). Do not manually reformat — run `nix fmt`.
- Prefer `lib.mkIf` / `lib.mkOption` / `lib.optional` over raw `if-then-else` in NixOS modules.
- Use `let ... in` for local bindings. Keep `let` blocks close to where they're used.
- Avoid `with pkgs;` at module scope — use it only in narrow scopes (e.g. inside `buildInputs` lists).
- `flake-parts` is used for per-system logic. New per-system outputs go in dedicated `.nix` files imported by `flake.nix`.
- Comments should explain *why*, not *what*. Nix expressions are usually self-documenting.

## Key patterns

### Flake structure

The flake uses [flake-parts](https://github.com/hercules-ci/flake-parts). Per-system outputs (packages, checks, devshell, apps) are split into separate files and imported in `flake.nix`. Flake-level outputs (`nixosModules`) are defined in the `flake = { ... }` attrset.

### NixOS module

`modules/nixos/happier-server.nix` defines `services.happier-server` options. It supports two modes:
- **full**: PostgreSQL + Redis + MinIO (production stack)
- **light**: SQLite-only, no external deps

The module provisions supporting services (PostgreSQL, Redis, MinIO) when `createLocally = true` and handles migrations, WAL mode, and secret loading via `systemd` `LoadCredential`.

Both modes require an `environmentFile` containing `HANDY_MASTER_SECRET` for production use. The only exception is the CI VM test, which omits it.

### Package builds

Both `happier-server` and `happier-cli` are built from the happier monorepo source (`inputs.happier`). Prisma engines come from `packages/prisma-engines-prebuilt.nix` which fetches prebuilt binaries by hash.

### Updating dependencies

When the happier monorepo updates `@prisma/client`, the engine hashes here must also be updated:

```sh
nix run .#update          # updates flake inputs + Prisma hashes
nix run .#update-prisma-hashes  # updates only Prisma hashes
```

## Verification

Always verify changes with:

```sh
nix fmt                   # format
nix flake check           # lint (deadnix, statix) + VM integration test (Linux)
nix build .#happier-server  # build the server package
```

`nix flake check` runs the NixOS VM integration test on Linux — it boots a VM with the light-mode example and verifies the server starts and responds on port 3005.

## Do's and don'ts

- **Do** run `nix fmt` after every change.
- **Do** run `nix flake check` before considering work done (or at minimum `nix build`).
- **Do** keep the NixOS module options in sync with the README's "Module options" table.
- **Do** add examples to `examples/` for new configurations and reference them in checks if testable.
- **Don't** modify `flake.lock` by hand — use `nix flake update` or `nix run .#update`.
- **Don't** add packages, commands, or dependencies that belong in the happier monorepo, not here.
- **Don't** introduce `with pkgs;` at module or file scope.
- **Don't** create migrations or modify Prisma schemas — that happens in the happier monorepo.
