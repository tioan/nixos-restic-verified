# The credentials of modules/restic-s3.nix from sops-nix: per job the
# repository password and the S3 key pair as sops secrets, the S3
# environment file as a sops template, and the same for the exporter's own
# key (exporter.ownKey). Every file is root-only: restic runs as root, and
# the exporter runs under a dynamic user, but systemd reads its
# EnvironmentFile and the password (LoadCredential) as root before it drops
# privileges.
#
# Secret names per job, under `secretNames` (defaults after the job's name):
#   restic_<name>_password, restic_<name>_key_id, restic_<name>_secret_key,
#   template restic-<name>-s3-env
# and for the exporter: restic_exporter_key_id, restic_exporter_secret_key,
# template restic-exporter-s3-env.
{ config, lib, ... }:
let
  top = config;
  cfg = config.services.resticS3;

  fromFile = sopsFile: lib.optionalAttrs (sopsFile != null) { inherit sopsFile; };

  # Per job, under fixed option paths: the job names must not decide which
  # options this module defines, or the module system recurses.
  perJob = f: lib.mkMerge (lib.mapAttrsToList f cfg.jobs);

  # The S3 environment restic reads, for a pair of key secrets.
  s3Env =
    { keyId, secretKey, ... }:
    ''
      AWS_ACCESS_KEY_ID=${config.sops.placeholder.${keyId}}
      AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.${secretKey}}
    ''
    + lib.optionalString (cfg.region != null) ''
      AWS_DEFAULT_REGION=${cfg.region}
    '';

  nameOption =
    default: description:
    lib.mkOption {
      type = lib.types.str;
      inherit default description;
    };
in
{
  imports = [ ./restic-s3.nix ];

  options.services.resticS3 = {
    region = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "garage";
      description = "AWS_DEFAULT_REGION in the rendered S3 environments; null leaves it out.";
    };

    jobs = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            options = {
              sopsFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "sops file with the job's secrets; null for sops.defaultSopsFile.";
              };
              secretNames = {
                password = nameOption "restic_${name}_password" "sops secret with the repository password.";
                keyId = nameOption "restic_${name}_key_id" "sops secret with the S3 access key ID.";
                secretKey = nameOption "restic_${name}_secret_key" "sops secret with the S3 secret key.";
                environment = nameOption "restic-${name}-s3-env" "sops template rendered as the S3 environment file.";
              };
            };
            config = {
              passwordFile = lib.mkDefault top.sops.secrets.${config.secretNames.password}.path;
              environmentFile = lib.mkDefault top.sops.templates.${config.secretNames.environment}.path;
            };
          }
        )
      );
    };

    exporter.ownKey = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Read the repository with a key of the exporter's own instead of the
        job's read/write key: the secrets exporter.secretNames.keyId and
        exporter.secretNames.secretKey, a key that may only read the job's
        bucket. The job keeps its own key.
      '';
    };

    exporter.sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "sops file with the exporter's own key (exporter.ownKey); null for sops.defaultSopsFile.";
    };

    exporter.secretNames = {
      keyId = nameOption "restic_exporter_key_id" "sops secret with the exporter's S3 access key ID.";
      secretKey = nameOption "restic_exporter_secret_key" "sops secret with the exporter's S3 secret key.";
      environment = nameOption "restic-exporter-s3-env" "sops template rendered as the exporter's S3 environment file.";
    };
  };

  config = lib.mkMerge [
    {
      sops.secrets = perJob (
        _: job:
        let
          s = job.secretNames;
        in
        {
          ${s.password} = fromFile job.sopsFile;
          ${s.keyId} = fromFile job.sopsFile;
          ${s.secretKey} = fromFile job.sopsFile;
        }
      );
      sops.templates = perJob (
        _: job: {
          ${job.secretNames.environment}.content = s3Env job.secretNames;
        }
      );
    }
    (lib.mkIf (cfg.exporter.job != null && cfg.exporter.ownKey) (
      let
        s = cfg.exporter.secretNames;
      in
      {
        sops.secrets = lib.genAttrs [ s.keyId s.secretKey ] (_: fromFile cfg.exporter.sopsFile);
        sops.templates.${s.environment} = {
          content = s3Env s;
          restartUnits = [ "prometheus-restic-exporter.service" ];
        };
        services.resticS3.exporter.environmentFile = config.sops.templates.${s.environment}.path;
      }
    ))
  ];
}
