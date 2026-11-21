# The config file modules/restic-verified.sh reads, for a job of
# modules/darwin/restic-s3.nix. Its own file so tests/restic-verified-darwin.nix
# runs the script with exactly what the Mac passes.
{
  name,
  job,
  stateDir,
  textfileDir,
}:
{
  inherit name stateDir textfileDir;
  inherit (job)
    maxAgeHours
    minPercent
    checkSubset
    keepUnverifiedDays
    ;
  # No inputs (dumps, exporters) on the Mac.
  inputs = [ ];
  requiredPaths = job.paths;
  # One argument per line, split on whitespace by the script: the paths
  # must not contain spaces (asserted in the module).
  backupArgs = job.paths;
  # Grouped by host only, as on NixOS.
  pruneArgs = import ../restic-prune-args.nix job;
}
