# Example: Happier Server in full mode (PostgreSQL + Redis + MinIO).
#
# This is the recommended production setup. It:
#   - Runs happier-server on localhost:3005 with the full backing stack
#   - Provisions PostgreSQL, Redis, and MinIO locally (createLocally = true)
#   - Uses Tailscale for private networking (not exposed to the public internet)
#   - Terminates TLS via Caddy, which auto-provisions certs from Tailscale
#   - Loads secrets via agenix (environmentFile + MinIO credentials)
#
# Prerequisites:
#   - A Tailscale account with HTTPS enabled (admin console → DNS → Enable HTTPS)
#   - An environment file containing at minimum:
#       HANDY_MASTER_SECRET=<your-secret>
#   - A MinIO credentials file containing:
#       MINIO_ROOT_USER=<user>
#       MINIO_ROOT_PASSWORD=<password>
#
# Replace "happier.example.ts.net" with your machine's Tailscale FQDN.

{ config, ... }:
{
  # -- Happier Server (full mode) ----------------------------------------------

  services.happier-server = {
    enable = true;
    port = 3005;
    mode = "full";
    # Required — must contain HANDY_MASTER_SECRET at minimum.
    # Use agenix, sops-nix, or a plain file with restricted permissions.
    environmentFile = config.age.secrets.happier-env.path;
    minio.rootCredentialsFile = config.age.secrets.minio-credentials.path;
  };

  # -- Secrets (agenix) --------------------------------------------------------

  age.secrets.happier-env.file = ../secrets/happier-env.age;
  age.secrets.minio-credentials.file = ../secrets/minio-credentials.age;

  # -- Tailscale ----------------------------------------------------------------

  services.tailscale.enable = true;
  # Allow Caddy to provision TLS certs via Tailscale
  services.tailscale.permitCertUid = "caddy";

  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ 41641 ]; # Tailscale
  };

  # -- Caddy reverse proxy (auto TLS via Tailscale) -----------------------------

  services.caddy = {
    enable = true;
    virtualHosts."happier.example.ts.net".extraConfig = ''
      reverse_proxy localhost:3005
    '';
  };
}
