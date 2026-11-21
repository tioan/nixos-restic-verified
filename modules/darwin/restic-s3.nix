# restic jobs on nix-darwin that back up to an S3 store, one bucket each -
# the counterpart of modules/restic-s3.nix.
#
# nix-darwin has no restic module, so each job is a launchd daemon that runs
# the very same verification as on NixOS: `restic-verified run` from
# modules/restic-verified.sh (backup, then the snapshot, the required paths
# and `restic check` are verified; a failed check tags the snapshot
# `unverified` and keeps forget from pushing good snapshots out). Its
# metrics carry the same names (<metricPrefix>backup_verified_*,
# <metricPrefix>backup_last_run_failed), so alert rules written for the NixOS
# hosts cover the Mac as well. The defaults are the same
# (modules/restic-policy.nix).
#
# Credentials are plain file paths here (passwordFile, keyIdFile,
# secretKeyFile), one set per host; modules/darwin/restic-s3-sops.nix fills
# them from sops-nix.
#
# Not here: `retry` (systemd only - a failed night shows up as an alert and the
# next night runs again) and the restic exporter.
#
# Setting up a job: bucket and key in the store, the secrets, switch, then
# once `restic-<job> init`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.resticS3;
  policy = import ../restic-policy.nix;
  stateDir = "/var/lib/restic-verified";

  restic = pkgs.restic;

  # modules/restic-verified.sh unchanged; GNU coreutils for `date -d`.
  verified = pkgs.writeShellApplication {
    name = "restic-verified";
    runtimeInputs = [
      restic
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
    ];
    text = import ../restic-verified-script.nix { inherit (cfg) metricPrefix; };
  };

  # The repository's environment, for the job and for `restic-<job>` by hand.
  envScript =
    name: job:
    pkgs.writeShellScript "restic-${name}-env" (
      ''
        export RESTIC_REPOSITORY=${lib.escapeShellArg "s3:${cfg.endpoint}/${job.bucket}"}
        export RESTIC_PASSWORD_FILE=${cfg.passwordFile}
        AWS_ACCESS_KEY_ID=$(cat ${cfg.keyIdFile})
        AWS_SECRET_ACCESS_KEY=$(cat ${cfg.secretKeyFile})
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      ''
      + lib.optionalString (cfg.region != null) ''
        export AWS_DEFAULT_REGION=${cfg.region}
      ''
      + ''
        export RESTIC_CACHE_DIR=${stateDir}/cache
      ''
    );

  jobConfig =
    name: job:
    pkgs.writeText "restic-verified-${name}.json" (
      builtins.toJSON (
        import ./restic-s3-config.nix {
          inherit name job stateDir;
          inherit (cfg) textfileDir;
        }
      )
    );

  runScript =
    name: job:
    pkgs.writeShellScript "restic-backups-${name}" ''
      set -euo pipefail
      . ${envScript name job}
      mkdir -p ${stateDir}/stamps "$RESTIC_CACHE_DIR"
      exec ${lib.getExe verified} run ${jobConfig name job}
    '';

  # `restic-<job> snapshots`, `restic-<job> init`, ... as root.
  wrapper =
    name: job:
    pkgs.writeShellScriptBin "restic-${name}" ''
      . ${envScript name job}
      exec ${lib.getExe restic} "$@"
    '';
in
{
  options.services.resticS3 = {
    endpoint = mkOption {
      type = types.str;
      example = "https://s3.example.org";
      description = "URL of the S3 endpoint, without a bucket.";
    };

    region = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "garage";
      description = "AWS_DEFAULT_REGION for restic; null leaves it unset.";
    };

    textfileDir = mkOption {
      type = types.str;
      example = "/var/lib/node-exporter-textfile";
      description = "node_exporter's textfile directory on this Mac, for the verification metrics.";
    };

    metricPrefix = mkOption {
      type = types.str;
      default = policy.metricPrefix;
      example = "";
      description = "Prefix of the metric names, as services.resticVerified.metricPrefix on NixOS.";
    };

    passwordFile = mkOption {
      type = types.str;
      description = "File with the repository password, shared by this host's jobs.";
    };

    keyIdFile = mkOption {
      type = types.str;
      description = "File with the S3 access key ID, shared by this host's jobs.";
    };

    secretKeyFile = mkOption {
      type = types.str;
      description = "File with the S3 secret key, shared by this host's jobs.";
    };

    jobs = mkOption {
      default = { };
      description = "restic jobs, keyed by name (metrics label `backup`, wrapper `restic-<name>`).";
      type = types.attrsOf (
        types.submodule {
          options = {
            bucket = mkOption {
              type = types.str;
              description = "Bucket of the repository.";
            };
            paths = mkOption {
              type = types.listOf types.str;
              description = "What to back up; every path must exist and hold something, or the run is not verified.";
            };
            hour = mkOption {
              type = types.ints.between 0 23;
              description = "Hour of the nightly run (launchd StartCalendarInterval).";
            };
            minute = mkOption {
              type = types.ints.between 0 59;
              default = 0;
              description = "Minute of the nightly run.";
            };
            keepDaily = mkOption {
              type = types.ints.positive;
              default = policy.keepDaily;
              description = "--keep-daily of the prune policy.";
            };
            keepWeekly = mkOption {
              type = types.ints.positive;
              default = policy.keepWeekly;
              description = "--keep-weekly of the prune policy.";
            };
            keepMonthly = mkOption {
              type = types.ints.positive;
              default = policy.keepMonthly;
              description = "--keep-monthly of the prune policy.";
            };
            maxAgeHours = mkOption {
              type = types.ints.positive;
              default = policy.maxAgeHours;
              description = "As in modules/restic-verified.nix (no inputs here, kept for the script).";
            };
            minPercent = mkOption {
              type = types.ints.between 1 100;
              default = policy.minPercent;
              description = "Files and bytes must reach this share of the last verified snapshot.";
            };
            checkSubset = mkOption {
              type = types.str;
              default = policy.checkSubset;
              description = "Share of the repository's data that `restic check` reads on Sundays.";
            };
            keepUnverifiedDays = mkOption {
              type = types.ints.positive;
              default = policy.keepUnverifiedDays;
              description = "How long snapshots tagged `unverified` are kept.";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf (cfg.jobs != { }) {
    assertions = lib.flatten (
      lib.mapAttrsToList (
        name: job:
        map (p: {
          assertion = !lib.hasInfix " " p;
          message = "services.resticS3.jobs.${name}: path with a space: ${p}";
        }) job.paths
      ) cfg.jobs
    );

    environment.systemPackages = lib.mapAttrsToList wrapper cfg.jobs;

    launchd.daemons = lib.mapAttrs' (
      name: job:
      lib.nameValuePair "restic-backups-${name}" {
        command = "${runScript name job}";
        serviceConfig = {
          StartCalendarInterval = [
            {
              Hour = job.hour;
              Minute = job.minute;
            }
          ];
          # Only the summary and IDs reach the log (restic-verified.sh never
          # prints file names).
          StandardOutPath = "/var/log/restic-backups-${name}.log";
          StandardErrorPath = "/var/log/restic-backups-${name}.log";
        };
      }
    ) cfg.jobs;
  };
}
