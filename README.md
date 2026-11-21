# nixos-restic-verified

restic backups on NixOS and nix-darwin that only count as successful once they have been verified.

A unit that reports success is not proof of a backup. A switch resets failed units, and a reset unit reports success. restic exits 0 when a `--files-from` path is missing or a directory is empty. It also stores yesterday's database dump without complaint when today's dump failed. This flake wraps `services.restic.backups` so that every run is checked before and after the backup:

- **before:** every required path holds something, and declared inputs (dump or export services) finished successfully within `maxAgeHours`
- **backup:** always attempted; if a check before failed, the snapshot is tagged `unverified` at creation
- **after:** the snapshot is read back: it exists, it is from this run, its size is plausible against the last verified one, the required paths are in it, and `restic check` passes (on Sundays with `--read-data-subset`). If any of this fails, the snapshot is tagged `unverified`.
- **only then:** the "verified" timestamp moves and forget/prune runs. The job's keep policy applies to verified (untagged) snapshots only, so unverified snapshots never take a verified one's daily or weekly slot. Unverified snapshots age out after `keepUnverifiedDays`.

The result goes to node_exporter's textfile collector as metrics, written atomically. A failure stays reported until a verified run clears it, across switches and reboots. Failed jobs are retried in the morning.

On top of that there are:
- `restic-s3`: jobs to S3-compatible stores, one bucket per job, with optional read-only btrfs snapshots and the restic exporter on a read-only key
- `restic-s3-sops`: the same with the credentials from [sops-nix](https://github.com/Mic92/sops-nix)
- a nix-darwin module that runs the same verification from launchd

Tested with restic 0.18 and Garage 2 (nixpkgs 26.05).

## Outputs

| Output | What it is |
|---|---|
| `nixosModules.restic-verified` | verification for jobs you declare in `services.restic.backups` yourself |
| `nixosModules.restic-s3` (`default`) | S3 jobs, credentials as file paths; imports `restic-verified` |
| `nixosModules.restic-s3-sops` | S3 jobs with sops-nix secrets and templates; imports `restic-s3` |
| `darwinModules.restic-s3` (`default`) | S3 jobs on nix-darwin as launchd daemons, credentials as file paths |
| `darwinModules.restic-s3-sops` | the same with sops-nix secrets |
| `lib.btrfsSnapshots` | prepare/cleanup scripts for read-only btrfs snapshots, for any restic job |
| `checks` | NixOS VM tests (x86_64-linux) and the darwin script test (both systems) |

## Usage

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.restic-verified.url = "github:tioan/nixos-restic-verified/v0.1.0";
  inputs.restic-verified.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, restic-verified, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ restic-verified.nixosModules.default ./configuration.nix ];
    };
  };
}
```

### S3 job (NixOS)

```nix
{
  services.resticS3 = {
    endpoint = "https://s3.example.org";
    jobs.host = {
      bucket = "host-backups";
      # Read from a read-only snapshot of the root subvolume.
      snapshots = [ { from = "/"; to = "/snapshots/restic-host"; } ];
      paths = [ "/snapshots/restic-host/var/lib" ];
      time = "02:30";
      passwordFile = "/run/secrets/restic-password";
      # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and, if the store needs it,
      # AWS_DEFAULT_REGION.
      environmentFile = "/run/secrets/restic-s3-env";
      prepare = "pg_dump -Fc app > /var/backup/app.dump";
    };
    # The restic exporter (127.0.0.1 only) for one job of the host.
    exporter.job = "host";
  };

  # Extra verification settings for the job.
  services.resticVerified.jobs.host = {
    inputs = [ "postgresqlBackup" ]; # must have succeeded within maxAgeHours
    minPercent = 50;
  };
}
```

The first run needs an initialised repository: `restic-host init` once (the module sets `initialize = false`, see below).

### With sops-nix

Import `nixosModules.restic-s3-sops` instead (next to sops-nix's own module). It creates the secrets `restic_<job>_password`, `restic_<job>_key_id`, `restic_<job>_secret_key` and renders the template `restic-<job>-s3-env`. Without `jobs.<job>.sopsFile` they come from `sops.defaultSopsFile`.

```nix
{
  services.resticS3 = {
    endpoint = "https://s3.example.org";
    region = "garage"; # AWS_DEFAULT_REGION in the template; null leaves it out
    jobs.host = {
      bucket = "host-backups";
      paths = [ "/var/lib" ];
      time = "02:30";
      sopsFile = ./secrets/restic.yaml;
    };
    exporter.job = "host";
    # Read-only key of its own: restic_exporter_key_id, restic_exporter_secret_key.
    exporter.ownKey = true;
    exporter.sopsFile = ./secrets/restic-exporter.yaml;
  };
}
```

### Your own restic jobs

`nixosModules.restic-verified` alone verifies any job of `services.restic.backups`, whatever the target:

```nix
{
  services.restic.backups.offsite = {
    initialize = false;
    repositoryFile = "/run/secrets/offsite-repository";
    passwordFile = "/run/secrets/offsite-password";
    paths = [ "/srv" ];
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" ];
  };
  services.resticVerified.jobs.offsite = { };
}
```

For an append-only repository, leave `pruneOpts` empty. Snapshots can then only be tagged `unverified` at creation, not later, and nothing is forgotten.

btrfs snapshots for such a job:

```nix
{ pkgs, inputs, ... }:
let
  snap = inputs.restic-verified.lib.btrfsSnapshots { inherit pkgs; } [
    { from = "/srv"; to = "/srv/.restic-snapshot"; }
  ];
in
{
  services.restic.backups.offsite.backupPrepareCommand = snap.prepare;
  services.restic.backups.offsite.backupCleanupCommand = snap.cleanup;
}
```

A snapshot leaves nested subvolumes out, so restic does not descend into itself. A leftover from an aborted run is removed first. If the source is not a subvolume (a data disk that is not mounted leaves a plain directory), `btrfs subvolume snapshot` refuses and the run fails instead of storing an empty disk.

### nix-darwin

```nix
{
  imports = [ inputs.restic-verified.darwinModules.default ];
  services.resticS3 = {
    endpoint = "https://s3.example.org";
    textfileDir = "/var/lib/node-exporter-textfile";
    passwordFile = "/var/root/restic/password";
    keyIdFile = "/var/root/restic/key-id";
    secretKeyFile = "/var/root/restic/secret-key";
    jobs.mac = {
      bucket = "mac-backups";
      paths = [ "/Users/me/Documents" ];
      hour = 3;
      minute = 45;
    };
  };
}
```

There is no retry and no exporter on nix-darwin. A failed night shows up in the metrics, and the next night runs again. `restic-<job>` runs restic against the job's repository as root.

## Options

### `services.resticVerified` (NixOS)

| Option | Default | |
|---|---|---|
| `textfileDir` | `/var/lib/prometheus-node-exporter-text-files` | node_exporter's textfile directory; metrics are written to its top level as root |
| `metricPrefix` | `nixlab_` | prefix of the metric names (the default keeps existing alert rules working; set your own) |
| `jobs.<name>.requiredPaths` | the job's `paths` | paths that must hold data, before the backup and in the snapshot |
| `jobs.<name>.inputs` | `[ ]` | services (no `.service`) that produce what the job stores; each must have succeeded within `maxAgeHours` |
| `jobs.<name>.maxAgeHours` | `26` | how old an input's last successful run may be |
| `jobs.<name>.minPercent` | `50` | files and bytes must reach this share of the last verified snapshot |
| `jobs.<name>.checkSubset` | `"5%"` | `--read-data-subset` of Sunday's `restic check` |
| `jobs.<name>.keepUnverifiedDays` | `14` | how long `unverified` snapshots stay |
| `jobs.<name>.retryAt` | `[ "05:15" "07:15" ]` | when an unverified job is started again |
| `jobs.<name>.retryIfOlderThanHours` | `20` | a retry does nothing while the last verified backup is younger |

Assertions: the job needs `initialize = false`. With `pruneOpts` set, the job needs a repository of its own and no tag or host in `extraBackupArgs`, and `pruneOpts` may only hold `--keep-*`, `--group-by` and prune options. Every input must be a service that runs something.

Why `initialize = false`: the NixOS module's `restic cat config || restic init` would answer an emptied bucket with a new, empty repository that then counts as a backup.

### `services.resticS3` (NixOS)

| Option | Default | |
|---|---|---|
| `endpoint` | - | S3 URL without a bucket |
| `jobs.<name>.bucket` | - | the job's bucket; the repository is `s3:<endpoint>/<bucket>` |
| `jobs.<name>.paths` / `exclude` | - / `[ ]` | as in `services.restic.backups` |
| `jobs.<name>.snapshots` | `[ ]` | read-only btrfs snapshots (`{ from, to }`) taken before the backup, removed after it |
| `jobs.<name>.prepare` / `cleanup` | `null` | steps after the snapshots / before their removal (cleanup also after failed runs) |
| `jobs.<name>.time` / `randomizedDelay` | - / `"20min"` | the timer's `OnCalendar` / `RandomizedDelaySec` (persistent) |
| `jobs.<name>.keepDaily` / `keepWeekly` / `keepMonthly` | `7` / `4` / `6` | prune policy, grouped by host only |
| `jobs.<name>.passwordFile` / `environmentFile` | - | credentials (set by `restic-s3-sops`) |
| `exporter.job` | `null` | the job the restic exporter watches (127.0.0.1, hourly) |
| `exporter.environmentFile` | the job's | S3 environment of the exporter, e.g. a read-only key |

With `restic-s3-sops`: `region`, `jobs.<name>.sopsFile`, `jobs.<name>.secretNames.{password,keyId,secretKey,environment}`, `exporter.ownKey`, `exporter.sopsFile`, `exporter.secretNames.{keyId,secretKey,environment}`.

The exporter calls restic with `--no-lock` throughout, `restic check` included. A key that may only read the bucket is therefore enough, and a taken-over exporter can read the backups but neither write nor delete them (`tests/restic-exporter-readonly.nix`).

### `services.resticS3` (nix-darwin)

`endpoint`, `region`, `textfileDir`, `metricPrefix`, `passwordFile`, `keyIdFile`, `secretKeyFile` (one set per host), and `jobs.<name>.{bucket, paths, hour, minute, keepDaily, keepWeekly, keepMonthly, maxAgeHours, minPercent, checkSubset, keepUnverifiedDays}`; prune grouped by host only, as on NixOS. Paths must not contain spaces. With `restic-s3-sops`: `sopsFile` and `secretNames.{password,keyId,secretKey}` (defaults `restic_password`, `restic_key_id`, `restic_secret_key`).

## Metrics

One file per job, `<textfileDir>/restic-verified-<job>.prom`, label `backup="<job>"`:

| Metric | |
|---|---|
| `<prefix>backup_verified_timestamp_seconds` | finish time of the newest verified backup, 0 if there is none |
| `<prefix>backup_last_run_failed{reason}` | 1 from a failed run until the next verified one; `reason` lists the failed checks (`source`, `input`, `backup-partial`, `backup-exit-<n>`, `verify-snapshot`, `verify-size`, `verify-path`, `check`, `tag`, `prune`, `unit-<result>`) |
| `<prefix>backup_verified_files` / `_bytes` | size of the newest verified backup |
| `<prefix>backup_verified_snapshot_info{snapshot}` | short ID of the newest verified snapshot |

Only IDs, counts, sizes and reason classes reach the journal and the metrics. File names in a repository can be private, so the script never prints what restic lists.

Example rules (with the default prefix):

```yaml
- alert: BackupRunFailed
  expr: max by (instance, backup, reason) (nixlab_backup_last_run_failed) == 1
  for: 5m
- alert: BackupNotVerified # 0 for a job never verified, so that fires too
  expr: max by (instance, backup) (time() - nixlab_backup_verified_timestamp_seconds) > 26 * 3600
  for: 15m
- alert: BackupMetricMissing # seen within the week, gone now
  expr: |
    group by (instance, backup) (max_over_time(nixlab_backup_verified_timestamp_seconds[7d]))
      unless group by (instance, backup) (nixlab_backup_verified_timestamp_seconds)
  for: 1h
```

## Restoring

Take the snapshot ID from `<prefix>backup_verified_snapshot_info` rather than `latest`: the newest snapshot may be an `unverified` one.

## Tests

```bash
nix build .#checks.x86_64-linux.restic-verified            # forced failures, keep-slot series, retry
nix build .#checks.x86_64-linux.restic-exporter-readonly   # exporter on a read-only key against Garage
nix build .#checks.aarch64-darwin.restic-verified-darwin   # the script as nix-darwin runs it
nix build .#checks.aarch64-darwin.prune-args               # forget arguments, grouped by host on both systems
```

## Prior art

nixpkgs' `services.restic.backups` runs the backup and, optionally, `restic check` (`runCheck`). It does not verify the snapshot, tag bad ones or report metrics. nix-darwin has no restic module. [carpenike/nix-config](https://github.com/carpenike/nix-config) also writes textfile metrics from its backup units, bound to its own hosts. No code is taken from other projects.

## License

MIT, see [LICENSE](LICENSE).
