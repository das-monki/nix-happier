# Example: Happier Server behind Tailscale with Caddy TLS reverse proxy.
#
# This is the recommended production setup for light mode. It:
#   - Runs happier-server on localhost:3005 (SQLite, no external deps)
#   - Uses Tailscale for private networking (not exposed to the public internet)
#   - Terminates TLS via Caddy, which auto-provisions certs from Tailscale
#   - Loads secrets (HANDY_MASTER_SECRET) from an environment file
#
# Prerequisites:
#   - A Tailscale account with HTTPS enabled (admin console → DNS → Enable HTTPS)
#   - An environment file containing at minimum:
#       HANDY_MASTER_SECRET=<your-secret>
#
# Replace "happier.example.ts.net" with your machine's Tailscale FQDN.

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
  # Allow Caddy to provision TLS certs via Tailscale
  services.tailscale.permitCertUid = "caddy";

  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ 41641 ]; # Tailscale
  };

  # -- Caddy reverse proxy (auto TLS via Tailscale) ---------------------------

  services.caddy = {
    enable = true;
    virtualHosts."happier.example.ts.net".extraConfig = ''
      reverse_proxy localhost:3005
    '';
  };
}
