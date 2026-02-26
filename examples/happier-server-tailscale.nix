# Example: Happier Server behind Tailscale with nginx TLS reverse proxy.
#
# This is the recommended production setup for light mode. It:
#   - Runs happier-server on localhost:3005 (SQLite, no external deps)
#   - Uses Tailscale for private networking (not exposed to the public internet)
#   - Terminates TLS via nginx using auto-renewed Tailscale certs
#   - Loads secrets (HANDY_MASTER_SECRET) from an environment file
#
# Prerequisites:
#   - A Tailscale account and auth key
#   - An environment file containing at minimum:
#       HANDY_MASTER_SECRET=<your-secret>
#
# Adapt the tailnetDomain and listen address to your Tailscale network.

{ pkgs, ... }:
let
  # Replace with your machine's Tailscale FQDN
  tailnetDomain = "happier.example.ts.net";
  certDir = "/var/lib/tailscale-certs";
in
{
  # -- Happier Server (light mode) -------------------------------------------

  services.happier-server = {
    enable = true;
    mode = "light";
    port = 3005;
    # Required — must contain HANDY_MASTER_SECRET at minimum.
    # Use agenix, sops-nix, or a plain file with restricted permissions.
    environmentFile = "/run/secrets/happier-env";
  };

  # -- Tailscale --------------------------------------------------------------

  services.tailscale.enable = true;

  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ 41641 ]; # Tailscale
  };

  # -- TLS certificates from Tailscale ----------------------------------------

  systemd.services.tailscale-cert = {
    description = "Generate Tailscale TLS certificates";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    path = [ pkgs.tailscale ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p ${certDir}
      for i in $(seq 1 30); do
        tailscale status && break
        sleep 1
      done
      tailscale cert \
        --cert-file ${certDir}/${tailnetDomain}.crt \
        --key-file ${certDir}/${tailnetDomain}.key \
        ${tailnetDomain}
      chmod 640 ${certDir}/${tailnetDomain}.key
      chown root:nginx ${certDir}/${tailnetDomain}.key
    '';
  };

  # Renew certs daily
  systemd.timers.tailscale-cert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  # -- Nginx reverse proxy (Tailscale interface only) -------------------------

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts.${tailnetDomain} = {
      # Listen only on the Tailscale interface — replace with your Tailscale IP.
      listen = [
        {
          addr = "100.x.y.z"; # <- your machine's Tailscale IP
          port = 443;
          ssl = true;
        }
      ];
      onlySSL = true;
      sslCertificate = "${certDir}/${tailnetDomain}.crt";
      sslCertificateKey = "${certDir}/${tailnetDomain}.key";

      locations."/" = {
        proxyPass = "http://127.0.0.1:3005";
        proxyWebsockets = true;
      };
    };
  };

  # Ensure nginx starts after certs are generated
  systemd.services.nginx = {
    after = [ "tailscale-cert.service" ];
    requires = [ "tailscale-cert.service" ];
  };
}
