# Renew the Archimedes GBrain access token.
#
# Hermes MCP is the authorization-code flow. It cannot mint a
# client_credentials bearer. The serve still reads
# `Authorization: Bearer ${GBRAIN_TOKEN}` from the Hermes env file.
# This timer mints that bearer from the OAuth client in sops and
# restarts the agent only when the value changes. The client id and
# secret never go into /run/hermes.env.
#
# The restart is not free: it kills pid 1 and every kanban worker the
# dispatcher is running under it. So it waits, bounded, for the jail to
# have no run in flight (see restart_agent).
#
# Every switch rewrites that env file from /run/hermes.env, which has
# no GBRAIN_TOKEN. hermes-pnp then copies ~/.gbrain/hermes-mcp.token
# back when the line is missing. That file is the legacy bearer and
# stays on disk as the rollback. The activation script below mints
# again after that copy. A path unit restarts the agent so the
# process does not keep the legacy value.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agent = config.services.hermes-agent;
  envFile = "${agent.stateDir}/.hermes/.env";
  tokenUrl = "http://127.0.0.1:${toString config.services.hermesPnP.gbrain.port}/token";
  changedStamp = "/run/archimedes-gbrain-token.changed";
  # The dispatcher's run ledger: a row with no ended_at is a worker a restart
  # would kill. Same tree the jail sees at /data/.hermes/kanban.db.
  kanbanDb = "${agent.stateDir}/.hermes/kanban.db";
  renew = pkgs.writers.writePython3 "archimedes-gbrain-token-renew" { } ''
    import json
    import os
    import re
    import sqlite3
    import subprocess
    import time
    import urllib.error
    import urllib.parse
    import urllib.request
    from pathlib import Path


    # Bounded wait for a quiet jail before the restart. The bearer being
    # replaced was minted at most one cadence (12 h) ago, and this unit's whole
    # premise is that it stays valid until the next mint, so minutes of delay
    # cost nothing; an unbounded wait could leave the env file and the running
    # process disagreeing for good. TimeoutStartSec below covers max + mint.
    QUIET_MAX_WAIT_S = int(os.environ.get("QUIET_MAX_WAIT_S") or "300")
    QUIET_POLL_S = int(os.environ.get("QUIET_POLL_S") or "15")


    def runs_in_flight(db):
        """Kanban runs the dispatcher has not ended; 0 when the check cannot answer.

        A restart kills pid 1, so every worker under it dies mid tool call --
        measured once: task_runs 261 (t_56eb54f7) crashed 2 s after the
        2026-10-30T11:36:58Z restart and only finished on the dispatcher's
        retry. Fail open on any read error: this gate must never turn a token
        renew into a no-op.
        """
        if not db.is_file():
            return 0
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        except sqlite3.Error:
            return 0
        try:
            row = con.execute(
                "select count(*) from task_runs where ended_at is null and status = 'running'"
            ).fetchone()
        except sqlite3.Error:
            return 0
        finally:
            con.close()
        return int(row[0] or 0)


    def restart_agent():
        db = Path(os.environ.get("KANBAN_DB") or "")
        waited = 0
        while True:
            busy = runs_in_flight(db)
            if busy == 0:
                break
            if waited >= QUIET_MAX_WAIT_S:
                print("restart anyway", busy, "run(s) in flight after", waited, "s")
                break
            print("defer restart", busy, "run(s) in flight")
            time.sleep(QUIET_POLL_S)
            waited += QUIET_POLL_S
        subprocess.run(
            ["systemctl", "restart", "hermes-agent.service"],
            check=True,
        )


    def drop_stamp(stamp):
        if stamp is not None and stamp.exists():
            stamp.unlink()


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
    req = urllib.request.Request(
        os.environ["TOKEN_URL"],
        data=body,
        method="POST",
    )
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
    stamp_name = os.environ.get("CHANGED_STAMP") or ""
    stamp = Path(stamp_name) if stamp_name else None
    skip_restart = os.environ.get("SKIP_AGENT_RESTART") == "1"
    if old == token:
        pending = stamp is not None and stamp.exists()
        if pending and not skip_restart:
            drop_stamp(stamp)
            print("restart", "expires_in", expires)
            restart_agent()
        else:
            print("unchanged", "expires_in", expires)
        raise SystemExit(0)
    if match:
        prefix = text[:match.start()]
        suffix = text[match.end():]
        text2 = prefix + "GBRAIN_TOKEN=" + token + suffix
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
    if skip_restart:
        if stamp is not None:
            stamp.write_text("1\n")
    else:
        drop_stamp(stamp)
        restart_agent()
  '';
in
{
  config = lib.mkIf config.services.hermesPnP.gbrain.enable {
    # After hermes-gbrain has copied the legacy token file.
    system.activationScripts.archimedes-gbrain-token = lib.stringAfter [ "hermes-gbrain" ] ''
      cred=$(${pkgs.coreutils}/bin/mktemp -d)
      ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg config.sops.secrets.archimedes_gbrain_client_id.path} "$cred/client_id"
      ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg config.sops.secrets.archimedes_gbrain_client_secret.path} "$cred/client_secret"
      if ! CREDENTIALS_DIRECTORY="$cred" \
          HERMES_ENV_FILE=${lib.escapeShellArg envFile} \
          TOKEN_URL=${lib.escapeShellArg tokenUrl} \
          SKIP_AGENT_RESTART=1 \
          CHANGED_STAMP=${lib.escapeShellArg changedStamp} \
          KANBAN_DB=${lib.escapeShellArg kanbanDb} \
          ${renew}; then
        echo "archimedes-gbrain-token: mint failed; the timer will retry" >&2
      fi
      ${pkgs.coreutils}/bin/rm -rf "$cred"
    '';

    systemd.services.archimedes-gbrain-token = {
      description = "Renew the Archimedes GBrain access token";
      after = [ "gbrain-mcp-http.service" ];
      wants = [ "gbrain-mcp-http.service" ];
      serviceConfig = {
        Type = "oneshot";
        # The mint's own 30 s request timeout plus the bounded quiet-wait
        # (QUIET_MAX_WAIT_S = 300). A shorter start budget would make systemd
        # kill the unit mid-wait and leave the timer's next fire to retry.
        TimeoutStartSec = 420;
        LoadCredential = [
          "client_id:${config.sops.secrets.archimedes_gbrain_client_id.path}"
          "client_secret:${config.sops.secrets.archimedes_gbrain_client_secret.path}"
        ];
      };
      environment = {
        HERMES_ENV_FILE = envFile;
        TOKEN_URL = tokenUrl;
        CHANGED_STAMP = changedStamp;
        KANBAN_DB = kanbanDb;
      };
      path = [ pkgs.systemd ];
      script = ''
        ${renew}
      '';
    };

    # Activation writes the stamp after it replaces the legacy line.
    # The path unit is already running on the next switch, so the
    # agent restart happens outside the activation script.
    systemd.paths.archimedes-gbrain-token = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = changedStamp;
        Unit = "archimedes-gbrain-token.service";
      };
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
