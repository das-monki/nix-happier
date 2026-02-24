# Happier Server NixOS module
# Provides happier-server as a native systemd service with PostgreSQL, Redis, and MinIO
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.happier-server;
  isFullMode = cfg.mode == "full";
in
{
  options.services.happier-server = {
    enable = lib.mkEnableOption "Happier Server";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The happier-server package to use";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3005;
      description = "Port to listen on";
    };

    mode = lib.mkOption {
      type = lib.types.enum [
        "full"
        "light"
      ];
      default = "full";
      description = ''
        Server mode.
        - "full": PostgreSQL + Redis + MinIO (production stack)
        - "light": SQLite-only, no external service dependencies
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Environment file with secrets in KEY=value format.
        Should contain at minimum HANDY_MASTER_SECRET for encryption.
      '';
    };

    database = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "happier";
        description = "PostgreSQL database name (full mode only)";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "happier";
        description = "PostgreSQL user (full mode only)";
      };

      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create database and user locally (full mode only)";
      };
    };

    redis = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create Redis instance locally (full mode only)";
      };
    };

    minio = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create MinIO instance locally for S3-compatible storage (full mode only)";
      };

      bucket = lib.mkOption {
        type = lib.types.str;
        default = "happier";
        description = "MinIO bucket name";
      };

      rootCredentialsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing MINIO_ROOT_USER and MINIO_ROOT_PASSWORD";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL configuration (full mode only)
    services.postgresql = lib.mkIf (isFullMode && cfg.database.createLocally) {
      enable = true;
      package = pkgs.postgresql_15;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkForce ''
        local all all trust
        host all all 127.0.0.1/32 trust
        host all all ::1/128 trust
      '';
    };

    # Redis configuration (full mode only)
    services.redis.servers.happier = lib.mkIf (isFullMode && cfg.redis.createLocally) {
      enable = true;
      port = 6379;
      bind = "127.0.0.1";
    };

    # MinIO configuration for S3-compatible storage (full mode only)
    services.minio = lib.mkIf (isFullMode && cfg.minio.createLocally) {
      enable = true;
      listenAddress = "127.0.0.1:9000";
      consoleAddress = "127.0.0.1:9001";
      dataDir = [ "/var/lib/minio/data" ];
      inherit (cfg.minio) rootCredentialsFile;
    };

    # Create MinIO bucket after service starts (full mode only)
    systemd.services.minio-bucket-init = lib.mkIf (isFullMode && cfg.minio.createLocally) {
      description = "Create MinIO bucket for happier-server";
      wantedBy = [ "multi-user.target" ];
      after = [ "minio.service" ];
      requires = [ "minio.service" ];
      path = [
        pkgs.minio-client
        pkgs.getent
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = cfg.minio.rootCredentialsFile;
      };
      script = ''
        # Wait for MinIO to be ready
        for i in $(seq 1 30); do
          mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && break
          sleep 1
        done

        # Create bucket if it doesn't exist
        mc mb --ignore-existing local/${cfg.minio.bucket}
      '';
    };

    # Run database migrations before server starts
    systemd.services.happier-server-migrate = {
      description = "Run happier-server database migrations";
      wantedBy = [ "happier-server.service" ];
      before = [ "happier-server.service" ];
      after = lib.optional (isFullMode && cfg.database.createLocally) "postgresql.service";
      requires = lib.optional (isFullMode && cfg.database.createLocally) "postgresql.service";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Share the same user and state directory as happier-server
        # so migrations write to the same database the server reads
        DynamicUser = true;
        StateDirectory = "happier-server";
      }
      // (
        if isFullMode then
          {
            ExecStart = "${cfg.package}/bin/happier-server-migrate";
            Environment = [
              "DATABASE_URL=postgresql://${cfg.database.user}@localhost/${cfg.database.name}"
              "NODE_ENV=production"
              "HOME=%S/happier-server"
            ];
          }
        else
          {
            ExecStart = "${cfg.package}/bin/happier-server-migrate-light";
            Environment = [
              "NODE_ENV=production"
              "HOME=%S/happier-server"
            ];
          }
      );
    };

    # Enable WAL mode on the SQLite database (light mode only).
    # WAL allows concurrent readers + one writer, eliminating the lock contention
    # that causes "Socket timeout" and "Transaction already closed" Prisma errors.
    systemd.services.happier-server-sqlite-wal = lib.mkIf (!isFullMode) {
      description = "Enable WAL mode on happier-server SQLite database";
      wantedBy = [ "happier-server.service" ];
      before = [ "happier-server.service" ];
      after = [ "happier-server-migrate.service" ];
      requires = [ "happier-server-migrate.service" ];
      path = [ pkgs.sqlite ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        StateDirectory = "happier-server";
      };
      script = ''
        DB="%S/happier-server/.happy/server-light/happier-server-light.sqlite"
        if [ -f "$DB" ]; then
          sqlite3 "$DB" "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"
        fi
      '';
    };

    # Main happier-server service
    systemd.services.happier-server = {
      description = "Happier Server";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "happier-server-migrate.service"
      ]
      ++ lib.optional (!isFullMode) "happier-server-sqlite-wal.service"
      ++ lib.optionals isFullMode (
        lib.optional cfg.database.createLocally "postgresql.service"
        ++ lib.optional cfg.redis.createLocally "redis-happier.service"
        ++ lib.optional cfg.minio.createLocally "minio-bucket-init.service"
      );
      requires = [
        "happier-server-migrate.service"
      ]
      ++ lib.optional (!isFullMode) "happier-server-sqlite-wal.service"
      ++ lib.optionals isFullMode (
        lib.optional cfg.database.createLocally "postgresql.service"
        ++ lib.optional cfg.redis.createLocally "redis-happier.service"
        ++ lib.optional cfg.minio.createLocally "minio.service"
      );
      script = ''
        ${lib.optionalString (cfg.environmentFile != null) ''
          set -a
          source "$CREDENTIALS_DIRECTORY/happier-env"
          set +a
        ''}
        ${lib.optionalString
          (isFullMode && cfg.minio.createLocally && cfg.minio.rootCredentialsFile != null)
          ''
            source "$CREDENTIALS_DIRECTORY/minio-creds"
            export S3_ACCESS_KEY="$MINIO_ROOT_USER"
            export S3_SECRET_KEY="$MINIO_ROOT_PASSWORD"
          ''
        }
        exec ${cfg.package}/bin/${if isFullMode then "happier-server" else "happier-server-light"}
      '';
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 5;

        Environment = [
          "NODE_ENV=production"
          "PORT=${toString cfg.port}"
          "HOME=%S/happier-server"
        ]
        ++ lib.optionals isFullMode (
          [
            "DATABASE_URL=postgresql://${cfg.database.user}@localhost/${cfg.database.name}"
          ]
          ++ lib.optional cfg.redis.createLocally "REDIS_URL=redis://localhost:6379"
          ++ lib.optionals cfg.minio.createLocally [
            "S3_HOST=127.0.0.1"
            "S3_PORT=9000"
            "S3_USE_SSL=false"
            "S3_BUCKET=${cfg.minio.bucket}"
            "S3_PUBLIC_URL=http://127.0.0.1:9000/${cfg.minio.bucket}"
          ]
        );

        # Use LoadCredential to make secret files readable by DynamicUser.
        # systemd copies them to a private $CREDENTIALS_DIRECTORY.
        LoadCredential =
          lib.optional (cfg.environmentFile != null) "happier-env:${cfg.environmentFile}"
          ++ lib.optional (
            isFullMode && cfg.minio.createLocally && cfg.minio.rootCredentialsFile != null
          ) "minio-creds:${cfg.minio.rootCredentialsFile}";

        # Hardening
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        StateDirectory = "happier-server";
        WorkingDirectory = "${cfg.package}/lib/happier-server/apps/server";
      };
    };
  };
}
