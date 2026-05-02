# TeamSpeak 6 Server (Docker)
# Voice: 9987/udp, File Transfer: 30033/tcp
# First run: check logs for ServerAdmin privilege key
{ ... }:
let
  image = "indogermane/teamspeak6-server-arm:latest";
  dataDir = "/var/lib/teamspeak";
  voicePort = 9987;
  fileTransferPort = 30033;
in
{
  # ===================
  # Container
  # ===================
  virtualisation.oci-containers.containers.teamspeak = {
    inherit image;
    environment = {
      TSSERVER_LICENSE_ACCEPTED = "accept";
    };
    volumes = [
      "${dataDir}:/data"
    ];
    networks = [ "host" ];
    autoStart = true;
  };

  # ===================
  # Pre-start setup
  # ===================
  systemd.services.docker-teamspeak.preStart = ''
    mkdir -p ${dataDir}
  '';

  # ===================
  # Firewall
  # ===================
  networking.firewall = {
    allowedUDPPorts = [ voicePort ];
    allowedTCPPorts = [ fileTransferPort ];
  };
}
