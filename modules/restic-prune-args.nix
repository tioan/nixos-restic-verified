# A job's keep policy as restic forget arguments, shared by
# modules/restic-s3.nix (NixOS) and modules/darwin/restic-s3-config.nix
# (nix-darwin), so a job prunes alike on both.
#
# One group per host, not per host and path list (restic's default): each
# job has a repository of its own, and a changed path list would otherwise
# start a new group and leave the old one's snapshots in place for good,
# since nothing new joins it.
job: [
  "--group-by host"
  "--keep-daily ${toString job.keepDaily}"
  "--keep-weekly ${toString job.keepWeekly}"
  "--keep-monthly ${toString job.keepMonthly}"
]
