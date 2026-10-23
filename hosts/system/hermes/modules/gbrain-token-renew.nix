# Renew the Archimedes GBrain access token.
#
# Hermes MCP is the authorization-code flow. It cannot mint a
# client_credentials bearer. The serve still reads
# `Authorization: Bearer ${GBRAIN_TOKEN}` from the Hermes env file.
# This timer mints that bearer from the OAuth client in sops and
# restarts the agent only when the value changes. The client id and
# secret never go into /run/hermes.env.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = config.services.hermes-agent;
  envFile = "${agent.stateDir}/.hermes/.env";
  renew = pkgs.writers.writePython3 "archimedes-gbrain-token-renew" { } ''
    import json, os, re, subprocess, urllib.error, urllib.parse, urllib.request
    from pathlib import Path

    cred_dir = Path(os.environ["CREDENTIALS_DIRECTORY"])
    client_id = (cred_dir / "client_id").read_text().strip()
    client_secret = (cred_dir / "client_secret").read_text().strip()
    body = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        }
    ).encode()
    req = urllib.request.Request(os.environ["TOKEN_URL"], data=body, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            data = json.load(resp)
    except urllib.error.HTTPError as exc:
        print("token_http", exc.code)
        raise SystemExit(1)
    token = data.get("access_token") or ""
    if not token:
        print("token_http", status, "no_access_token")
        raise SystemExit(1)
    expires = data.get("expires_in")
    envp = Path(os.environ["HERMES_ENV_FILE"])
    text = envp.read_text()
    match = re.search(r"^GBRAIN_TOKEN=(.*)$", text, re.M)
    old = match.group(1).strip() if match else None
    if old == token:
        print("unchanged", "expires_in", expires)
        raise SystemExit(0)
    if match:
        text2 = text[: match.start()] + "GBRAIN_TOKEN=" + token + text[match.end() :]
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text2 = text + "GBRAIN_TOKEN=" + token + "\n"
    tmp = envp.with_name(".env.token-tmp")
    tmp.write_text(text2)
    st = envp.stat()
    os.chmod(tmp, st.st_mode & 0o777)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, envp)
    print("updated", "expires_in", expires)
    subprocess.run(["systemctl", "restart", "hermes-agent.service"], check=True)
  '';
in
{
  config = lib.mkIf config.services.hermesPnP.gbrain.enable {
    systemd.services.archimedes-gbrain-token = {
      description = "Renew the Archimedes GBrain access token";
      after = [ "gbrain-mcp-http.service" ];
      wants = [ "gbrain-mcp-http.service" ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = 120;
        LoadCredential = [
          "client_id:${config.sops.secrets.archimedes_gbrain_client_id.path}"
          "client_secret:${config.sops.secrets.archimedes_gbrain_client_secret.path}"
        ];
      };
      environment = {
        HERMES_ENV_FILE = envFile;
        TOKEN_URL = "http://127.0.0.1:${toString config.services.hermesPnP.gbrain.port}/token";
      };
      path = [ pkgs.systemd ];
      script = ''
        ${renew}
      '';
    };

    systemd.timers.archimedes-gbrain-token = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "12h";
        AccuracySec = "1min";
      };
    };
  };
}
