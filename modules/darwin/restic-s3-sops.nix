# The credentials of modules/darwin/restic-s3.nix from sops-nix: the
# repository password and the S3 key pair of this host's jobs as sops
# secrets (root-only, like everything the jobs read).
{ config, lib, ... }:
let
  cfg = config.services.resticS3;
  secretName =
    default: description:
    lib.mkOption {
      type = lib.types.str;
      inherit default description;
    };
in
{
  imports = [ ./restic-s3.nix ];

  options.services.resticS3 = {
    sopsFile = lib.mkOption {
      type = lib.types.path;
      description = "sops file with the secrets in secretNames. One set per host.";
    };

    secretNames = {
      password = secretName "restic_password" "sops secret with the repository password.";
      keyId = secretName "restic_key_id" "sops secret with the S3 access key ID.";
      secretKey = secretName "restic_secret_key" "sops secret with the S3 secret key.";
    };
  };

  config = lib.mkIf (cfg.jobs != { }) {
    sops.secrets = lib.genAttrs (lib.attrValues cfg.secretNames) (_: {
      inherit (cfg) sopsFile;
    });

    services.resticS3 = {
      passwordFile = lib.mkDefault config.sops.secrets.${cfg.secretNames.password}.path;
      keyIdFile = lib.mkDefault config.sops.secrets.${cfg.secretNames.keyId}.path;
      secretKeyFile = lib.mkDefault config.sops.secrets.${cfg.secretNames.secretKey}.path;
    };
  };
}
