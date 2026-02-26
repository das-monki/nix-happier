# Example: Happier Server in light mode (SQLite, no external dependencies)
#
# Minimal configuration — the consumer must set services.happier-server.package.
# In production, also set environmentFile for secrets (HANDY_MASTER_SECRET).
{
  services.happier-server = {
    enable = true;
    mode = "light";
  };
}
