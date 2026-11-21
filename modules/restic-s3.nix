# restic jobs that back up to an S3 store, one bucket each. Each job gets
# what every host would otherwise write out by hand: the repository URL,
# `initialize = false` (modules/restic-verified.nix explains why), the timer,
# the prune policy, optional read-only btrfs snapshots to read from
# (modules/restic-btrfs-snapshots.nix) and the verification by
# modules/restic-verified.nix. Optionally one job per host is watched by the
# restic exporter, which the NixOS module runs once per host.
#
# Credentials are plain file paths here: the repository password and an
# environment file with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and, where
# the store wants one, AWS_DEFAULT_REGION. modules/restic-s3-sops.nix fills
# them from sops-nix instead.
#
# Not here: buckets and keys (create them in the store first), what a job
# reads and how it makes that consistent (`paths`, `snapshots`, `prepare`,
# `cleanup` per job), restic jobs with other targets. The first run needs an
# initialised repository: once `restic-<job> init`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Defaults shared with modules/darwin/restic-s3.nix.
  policy = import ./restic-policy.nix;
  cfg = config.services.resticS3;

  # Snapshots first, then the job's own steps; cleanup the other way round.
  steps =
    job:
    let
      snap = import ./restic-btrfs-snapshots.nix { inherit pkgs; } job.snapshots;
      orEmpty = s: if s == null then "" else s;
      orNull = s: if s == "" then null else s;
      # A one-line step written without its newline must not run into the next.
      line = s: if s == "" || lib.hasSuffix "\n" s then s else s + "\n";
    in
    {
      prepare = orNull (snap.prepare + orEmpty job.prepare);
      cleanup = orNull (
        if snap.cleanup == "" then orEmpty job.cleanup else line (orEmpty job.cleanup) + snap.cleanup
      );
    };

  backup =
    _name: job:
    {
      inherit (job)
        paths
        exclude
        passwordFile
        environmentFile
        ;
      repository = "s3:${cfg.endpoint}/${job.bucket}";
      initialize = false; # see modules/restic-verified.nix
      timerConfig = {
        OnCalendar = job.time;
        RandomizedDelaySec = job.randomizedDelay;
        Persistent = true;
      };
      # One group per host, not per host and path list (restic's default):
      # each job has a repository of its own, and a changed path list would
      # otherwise start a new group and leave the old one's snapshots in
      # place for good, since nothing new joins it.
      pruneOpts = [
        "--group-by host"
        "--keep-daily ${toString job.keepDaily}"
        "--keep-weekly ${toString job.keepWeekly}"
        "--keep-monthly ${toString job.keepMonthly}"
      ];
    }
    // lib.optionalAttrs ((steps job).prepare != null) { backupPrepareCommand = (steps job).prepare; }
    // lib.optionalAttrs ((steps job).cleanup != null) { backupCleanupCommand = (steps job).cleanup; };
in
{
  imports = [ ./restic-verified.nix ];

  options.services.resticS3 = {
    endpoint = lib.mkOption {
      type = lib.types.str;
      example = "https://s3.example.org";
      description = "URL of the S3 endpoint, without a bucket.";
    };

    jobs = lib.mkOption {
      default = { };
      description = "restic jobs (services.restic.backups.<name>) to a bucket of their own.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            bucket = lib.mkOption {
              type = lib.types.str;
              description = "Bucket of the repository.";
            };
            paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "What restic stores, as services.restic.backups.<name>.paths.";
            };
            exclude = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "As services.restic.backups.<name>.exclude.";
            };
            snapshots = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options.from = lib.mkOption {
                    type = lib.types.str;
                    description = "btrfs subvolume to snapshot.";
                  };
                  options.to = lib.mkOption {
                    type = lib.types.str;
                    description = "Path of the read-only snapshot.";
                  };
                }
              );
              default = [ ];
              description = "Read-only btrfs snapshots taken before the backup and removed after it (modules/restic-btrfs-snapshots.nix); `paths` point into them.";
            };
            prepare = lib.mkOption {
              type = lib.types.nullOr lib.types.lines;
              default = null;
              description = "Runs before the backup, after the snapshots, e.g. a database copy (backupPrepareCommand).";
            };
            cleanup = lib.mkOption {
              type = lib.types.nullOr lib.types.lines;
              default = null;
              description = "Runs after the backup, failed ones too, before the snapshots are removed (backupCleanupCommand).";
            };
            time = lib.mkOption {
              type = lib.types.str;
              example = "02:30";
              description = "OnCalendar of the job's timer.";
            };
            randomizedDelay = lib.mkOption {
              type = lib.types.str;
              default = "20min";
              description = "RandomizedDelaySec of the job's timer.";
            };
            keepDaily = lib.mkOption {
              type = lib.types.ints.positive;
              default = policy.keepDaily;
              description = "--keep-daily of the prune policy.";
            };
            keepWeekly = lib.mkOption {
              type = lib.types.ints.positive;
              default = policy.keepWeekly;
              description = "--keep-weekly of the prune policy.";
            };
            keepMonthly = lib.mkOption {
              type = lib.types.ints.positive;
              default = policy.keepMonthly;
              description = "--keep-monthly of the prune policy.";
            };
            passwordFile = lib.mkOption {
              type = lib.types.str;
              description = "File with the repository password (services.restic.backups.<name>.passwordFile).";
            };
            environmentFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                File with the S3 environment: AWS_ACCESS_KEY_ID,
                AWS_SECRET_ACCESS_KEY and, where the store needs one,
                AWS_DEFAULT_REGION (services.restic.backups.<name>.environmentFile).
              '';
            };
          };
        }
      );
    };

    exporter.job = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The job whose repository the restic exporter watches, on 127.0.0.1
        only: the exporter holds the repository password and an S3 key.
      '';
    };

    exporter.environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        S3 environment of the exporter; null for the job's own. A key that
        may only read the job's bucket is enough: restic is called with
        --no-lock throughout, `restic check` included
        (tests/restic-exporter-readonly.nix), so a taken-over exporter can
        read the backups but neither write nor delete them.
      '';
    };
  };

  config = lib.mkMerge [
    {
      services.restic.backups = lib.mapAttrs backup cfg.jobs;
      # Success is what modules/restic-verified.nix confirms, not the unit's
      # result. Hosts add the job's inputs and limits there.
      services.resticVerified.jobs = lib.mapAttrs (_: _: { }) cfg.jobs;
    }
    (lib.mkIf (cfg.exporter.job != null) {
      assertions = [
        {
          assertion = cfg.jobs ? ${cfg.exporter.job};
          message = "services.resticS3.exporter.job: ${cfg.exporter.job} is not one of services.resticS3.jobs.";
        }
      ];

      services.prometheus.exporters.restic =
        let
          job = config.services.restic.backups.${cfg.exporter.job};
        in
        {
          enable = true;
          # Loopback only: the exporter holds the repository password and an S3 key.
          listenAddress = "127.0.0.1";
          inherit (job) repository passwordFile;
          environmentFile =
            if cfg.exporter.environmentFile != null then cfg.exporter.environmentFile else job.environmentFile;
          # Every collection is a burst of S3 requests; hourly tells just as much.
          refreshInterval = 3600;
        };
    })
  ];
}
