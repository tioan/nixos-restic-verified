# Defaults of the restic jobs, shared by modules/restic-s3.nix and
# modules/restic-verified.nix on NixOS and modules/darwin/restic-s3.nix on
# nix-darwin, so a job means the same everywhere. Plain values, imported with
# `import ./restic-policy.nix`; each module still offers them as options.
{
  # Prune policy (restic forget).
  keepDaily = 7;
  keepWeekly = 4;
  keepMonthly = 6;
  # Verification (modules/restic-verified.sh).
  maxAgeHours = 26;
  minPercent = 50;
  checkSubset = "5%";
  keepUnverifiedDays = 14;
  # Metrics: node_exporter's textfile directory and the prefix of the names.
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";
  metricPrefix = "nixlab_";
}
