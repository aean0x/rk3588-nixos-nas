# DEPRECATED — moved to containers/comet.nix
#
# Comet is a Docker container (not a native NixOS service), so its module now
# lives under hosts/system/containers/ following the project convention.
# Container definitions belong in containers.nix imports.
#
# If you previously enabled it here, move the uncomment to:
#   hosts/system/containers.nix  ->  ./containers/comet.nix
#
# The implementation, secret handling (torbox_api_key), and behavior are unchanged.
{ ... }: { }
