# The text of modules/restic-verified.sh with the metric prefix filled in,
# for writeShellApplication's `text`. Shared by modules/restic-verified.nix,
# modules/darwin/restic-s3.nix and the tests, so all of them run the same
# script. The prefix is part of the text rather than read at run time: the
# metric names stay greppable in the built script.
{ metricPrefix }:
builtins.replaceStrings [ "@metricPrefix@" ] [ metricPrefix ] (
  builtins.readFile ./restic-verified.sh
)
