# NFS: Network file shares
# /media — wide-open read-write for LAN + Tailscale (no auth)
# /var/lib/openclaw — Kerberos-optional, restricted to LAN + Tailscale, root squash
{
  settings,
  ...
}:
let
  lan = "192.168.1.0/24";
  tailscale = "100.64.0.0/10";
in
{
  services.nfs.server = {
    enable = true;
    exports = ''
      /media                ${lan}(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=100) ${tailscale}(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=100)
      /var/lib/openclaw     ${lan}(ro,sync,no_subtree_check,root_squash) ${tailscale}(ro,sync,no_subtree_check,root_squash)
    '';
  };

  # NFSv4 only — single port, no portmapper/rpcbind needed
  services.nfs.server.extraNfsdConfig = ''
    vers2=n
    vers3=n
    vers4=y
    vers4.1=y
    vers4.2=y
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
