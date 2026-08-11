#!/usr/bin/env bash
# Seed two simple ErsatzTV flood channels from the Music Videos library so you
# can learn the app by reverse-engineering a working setup:
#   ch 10 — MTV Shuffle        (PlaybackOrder = Shuffle)
#   ch 11 — MTV Chronological  (PlaybackOrder = Chronological / rotate)
#
# Safe to re-run: skips objects that already exist by name/number.
# Run on the NAS as root:
#   scp scripts/oneshot/ersatztv-seed-music.sh rocknas:/tmp/ && ssh rocknas 'sudo bash /tmp/ersatztv-seed-music.sh'
# Archived under scripts/oneshot/ (not part of deploy).
set -euo pipefail

ETV="${ETV_URL:-http://127.0.0.1:8409}"
DB="${ETV_DB:-/var/lib/ersatztv/ersatztv.sqlite3}"
# Music Videos library id is always 3 in a stock local media source.
MUSIC_LIB_ID=3

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
need docker

# Prefer host sqlite3; else nix-shell; else docker image with sqlite.
run_sql() {
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "$@"
  elif command -v nix-shell >/dev/null 2>&1; then
    nix-shell -p sqlite --run "sqlite3 '$DB' $(printf '%q' "$*")"
  else
    # last resort: temporary container sharing host DB path
    docker run --rm -v "$DB:$DB" nouchka/sqlite3 "$DB" "$@"
  fi
}

echo "==> ErsatzTV seed (music videos demo channels)"

# Host path is always the source of truth; container may be stopped.
HOST_MV="/media/Videos/Music Videos"
if [[ ! -d "$HOST_MV" ]]; then
  echo "ERROR: host path missing: $HOST_MV" >&2
  exit 1
fi
file_count=$(find "$HOST_MV" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.webm" \) 2>/dev/null | wc -l | tr -d ' ')
echo "    media files on host: $file_count"
if [[ "${file_count:-0}" -lt 1 ]]; then
  echo "ERROR: no video files under Music Videos" >&2
  exit 1
fi

# Ensure ersatztv is (or was) configured with the Videos bind. If running, check.
if docker ps --format '{{.Names}}' | grep -qx ersatztv; then
  if ! docker exec ersatztv test -d "/media/library/Music Videos" 2>/dev/null; then
    echo "ERROR: /media/library/Music Videos not visible inside running ersatztv." >&2
    echo "Deploy ersatztv.nix with Videos → /media/library mount, then re-run." >&2
    exit 1
  fi
fi

# --- stop app so SQLite is quiet --------------------------------------------
echo "==> Stopping ersatztv for DB seed"
systemctl stop docker-ersatztv.service || true
sleep 2

# --- SQL seed (idempotent by name/number) -----------------------------------
# Enums (ErsatzTV.Core.Domain):
#   CollectionType.SmartCollection = 5
#   PlaybackOrder.Chronological    = 1
#   PlaybackOrder.Shuffle          = 3
#   PlayoutScheduleKind.Classic    = 1
#   StreamingMode.TransportStreamHybrid = 5
#   GuideMode.Normal = 0, FillWithGroupMode.None = 0
SQL_FILE=$(mktemp)
trap 'rm -f "$SQL_FILE"' EXIT
cat >"$SQL_FILE" <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN;

-- Smart collection: every music video in the index
INSERT INTO SmartCollection (Name, Query)
SELECT 'All Music Videos', 'type:music_video'
WHERE NOT EXISTS (SELECT 1 FROM SmartCollection WHERE Name = 'All Music Videos');

-- Schedules -----------------------------------------------------------------
INSERT INTO ProgramSchedule (
  FixedStartTimeBehavior, KeepMultiPartEpisodesTogether, Name,
  RandomStartPoint, ShuffleScheduleItems, TreatCollectionsAsShows
)
SELECT 0, 0, 'MTV Shuffle Flood', 1, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM ProgramSchedule WHERE Name = 'MTV Shuffle Flood');

INSERT INTO ProgramSchedule (
  FixedStartTimeBehavior, KeepMultiPartEpisodesTogether, Name,
  RandomStartPoint, ShuffleScheduleItems, TreatCollectionsAsShows
)
SELECT 0, 0, 'MTV Chronological Flood', 0, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM ProgramSchedule WHERE Name = 'MTV Chronological Flood');

-- Flood items (one continuous "block" per schedule) -------------------------
-- Shuffle
INSERT INTO ProgramScheduleItem (
  CollectionId, CollectionType, CustomTitle, FakeCollectionKey,
  FallbackFillerId, FillWithGroupMode, FixedStartTimeBehavior, GuideMode,
  "Index", MarathonBatchSize, MarathonGroupBy, MarathonShuffleGroups,
  MarathonShuffleItems, MediaItemId, MidRollFillerId, MultiCollectionId,
  PlaybackOrder, PlaylistId, PostRollFillerId, PreRollFillerId,
  PreferredAudioLanguageCode, PreferredAudioTitle, PreferredSubtitleLanguageCode,
  ProgramScheduleId, RerunCollectionId, SmartCollectionId, StartTime,
  SubtitleMode, TailFillerId, SearchQuery, SearchTitle
)
SELECT
  NULL, 5, NULL, NULL,
  NULL, 0, NULL, 0,
  0, NULL, 0, 0,
  0, NULL, NULL, NULL,
  3, NULL, NULL, NULL,
  NULL, NULL, NULL,
  (SELECT Id FROM ProgramSchedule WHERE Name = 'MTV Shuffle Flood'),
  NULL, (SELECT Id FROM SmartCollection WHERE Name = 'All Music Videos'), NULL,
  NULL, NULL, NULL, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM ProgramScheduleItem psi
  JOIN ProgramSchedule ps ON ps.Id = psi.ProgramScheduleId
  WHERE ps.Name = 'MTV Shuffle Flood'
);

INSERT INTO ProgramScheduleFloodItem (Id)
SELECT psi.Id FROM ProgramScheduleItem psi
JOIN ProgramSchedule ps ON ps.Id = psi.ProgramScheduleId
WHERE ps.Name = 'MTV Shuffle Flood'
  AND NOT EXISTS (SELECT 1 FROM ProgramScheduleFloodItem f WHERE f.Id = psi.Id);

-- Chronological (file order / rotate through the library)
INSERT INTO ProgramScheduleItem (
  CollectionId, CollectionType, CustomTitle, FakeCollectionKey,
  FallbackFillerId, FillWithGroupMode, FixedStartTimeBehavior, GuideMode,
  "Index", MarathonBatchSize, MarathonGroupBy, MarathonShuffleGroups,
  MarathonShuffleItems, MediaItemId, MidRollFillerId, MultiCollectionId,
  PlaybackOrder, PlaylistId, PostRollFillerId, PreRollFillerId,
  PreferredAudioLanguageCode, PreferredAudioTitle, PreferredSubtitleLanguageCode,
  ProgramScheduleId, RerunCollectionId, SmartCollectionId, StartTime,
  SubtitleMode, TailFillerId, SearchQuery, SearchTitle
)
SELECT
  NULL, 5, NULL, NULL,
  NULL, 0, NULL, 0,
  0, NULL, 0, 0,
  0, NULL, NULL, NULL,
  1, NULL, NULL, NULL,
  NULL, NULL, NULL,
  (SELECT Id FROM ProgramSchedule WHERE Name = 'MTV Chronological Flood'),
  NULL, (SELECT Id FROM SmartCollection WHERE Name = 'All Music Videos'), NULL,
  NULL, NULL, NULL, NULL
WHERE NOT EXISTS (
  SELECT 1 FROM ProgramScheduleItem psi
  JOIN ProgramSchedule ps ON ps.Id = psi.ProgramScheduleId
  WHERE ps.Name = 'MTV Chronological Flood'
);

INSERT INTO ProgramScheduleFloodItem (Id)
SELECT psi.Id FROM ProgramScheduleItem psi
JOIN ProgramSchedule ps ON ps.Id = psi.ProgramScheduleId
WHERE ps.Name = 'MTV Chronological Flood'
  AND NOT EXISTS (SELECT 1 FROM ProgramScheduleFloodItem f WHERE f.Id = psi.Id);

-- Channels ------------------------------------------------------------------
INSERT INTO Channel (
  Categories, FFmpegProfileId, FallbackFillerId, "Group", IdleBehavior,
  IsEnabled, MirrorSourceChannelId, MusicVideoCreditsMode, MusicVideoCreditsTemplate,
  Name, Number, PlayoutMode, PlayoutOffset, PlayoutSource,
  PreferredAudioLanguageCode, PreferredAudioTitle, PreferredSubtitleLanguageCode,
  ShowInEpg, SongVideoMode, SortNumber, StreamSelector, StreamSelectorMode,
  StreamingMode, SubtitleMode, TranscodeMode, UniqueId, WatermarkId,
  SlugSeconds, StreamingEngine, NextEngineTextSubtitleMode
)
SELECT
  NULL, 1, NULL, 'Music Videos', 0,
  1, NULL, 0, NULL,
  'MTV Shuffle', '10', 0, NULL, 0,
  NULL, NULL, NULL,
  1, 0, 10.0, NULL, 0,
  5, 0, 0,
  lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(6))),
  NULL, NULL, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM Channel WHERE Number = '10');

INSERT INTO Channel (
  Categories, FFmpegProfileId, FallbackFillerId, "Group", IdleBehavior,
  IsEnabled, MirrorSourceChannelId, MusicVideoCreditsMode, MusicVideoCreditsTemplate,
  Name, Number, PlayoutMode, PlayoutOffset, PlayoutSource,
  PreferredAudioLanguageCode, PreferredAudioTitle, PreferredSubtitleLanguageCode,
  ShowInEpg, SongVideoMode, SortNumber, StreamSelector, StreamSelectorMode,
  StreamingMode, SubtitleMode, TranscodeMode, UniqueId, WatermarkId,
  SlugSeconds, StreamingEngine, NextEngineTextSubtitleMode
)
SELECT
  NULL, 1, NULL, 'Music Videos', 0,
  1, NULL, 0, NULL,
  'MTV Chronological', '11', 0, NULL, 0,
  NULL, NULL, NULL,
  1, 0, 11.0, NULL, 0,
  5, 0, 0,
  lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(6))),
  NULL, NULL, 0, 0
WHERE NOT EXISTS (SELECT 1 FROM Channel WHERE Number = '11');

-- Classic playouts (ScheduleKind = 1) ---------------------------------------
INSERT INTO Playout (ChannelId, DailyRebuildTime, DecoId, OnDemandCheckpoint, ProgramScheduleId, ScheduleFile, ScheduleKind, Seed)
SELECT
  (SELECT Id FROM Channel WHERE Number = '10'),
  NULL, NULL, NULL,
  (SELECT Id FROM ProgramSchedule WHERE Name = 'MTV Shuffle Flood'),
  NULL, 1, abs(random() % 1000000)
WHERE NOT EXISTS (
  SELECT 1 FROM Playout p
  JOIN Channel c ON c.Id = p.ChannelId
  WHERE c.Number = '10'
);

INSERT INTO Playout (ChannelId, DailyRebuildTime, DecoId, OnDemandCheckpoint, ProgramScheduleId, ScheduleFile, ScheduleKind, Seed)
SELECT
  (SELECT Id FROM Channel WHERE Number = '11'),
  NULL, NULL, NULL,
  (SELECT Id FROM ProgramSchedule WHERE Name = 'MTV Chronological Flood'),
  NULL, 1, abs(random() % 1000000)
WHERE NOT EXISTS (
  SELECT 1 FROM Playout p
  JOIN Channel c ON c.Id = p.ChannelId
  WHERE c.Number = '11'
);

COMMIT;

SELECT 'smart' AS kind, Id, Name, Query FROM SmartCollection WHERE Name = 'All Music Videos';
SELECT 'schedules' AS kind, Id, Name FROM ProgramSchedule WHERE Name LIKE 'MTV%';
SELECT 'channels' AS kind, Id, Number, Name FROM Channel WHERE Number IN ('10','11');
SELECT 'playouts' AS kind, p.Id, c.Number, p.ProgramScheduleId, p.ScheduleKind
  FROM Playout p JOIN Channel c ON c.Id = p.ChannelId
  WHERE c.Number IN ('10','11');
SQL

echo "==> Applying SQL seed"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" <"$SQL_FILE"
else
  # Device image is slim — use a one-shot sqlite container against the host DB.
  # Root user required: /var/lib/ersatztv is root-owned.
  docker run --rm -i --user 0:0 \
    -v "$(dirname "$DB"):$(dirname "$DB")" \
    keinos/sqlite3 \
    sqlite3 "$DB" <"$SQL_FILE"
fi

echo "==> Starting ersatztv"
systemctl start docker-ersatztv.service

# wait for HTTP
for _ in $(seq 1 40); do
  if curl -sf "$ETV/api/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "$ETV/api/version" >/dev/null || { echo "ERROR: ersatztv not up" >&2; exit 1; }

echo "==> Scanning Music Videos library (id=$MUSIC_LIB_ID)"
curl -sS -X POST "$ETV/api/libraries/${MUSIC_LIB_ID}/scan" || true
echo "    (scan runs async — watch UI / logs for progress)"

echo "==> Resetting playouts so flood schedules build"
curl -sS -o /dev/null -w "ch10=%{http_code}\n" -X POST "$ETV/api/channels/10/playout/reset" || true
curl -sS -o /dev/null -w "ch11=%{http_code}\n" -X POST "$ETV/api/channels/11/playout/reset" || true

echo
echo "==> Done. What to open in the UI (pick it apart):"
echo "    Media Sources → Local → Music Videos  (path /media/library/Music Videos)"
echo "    Lists → Smart Collections → All Music Videos  (query: type:music_video)"
echo "    Schedules → MTV Shuffle Flood          (Flood + PlaybackOrder Shuffle)"
echo "    Schedules → MTV Chronological Flood    (Flood + PlaybackOrder Chronological)"
echo "    Channels  → 10 MTV Shuffle / 11 MTV Chronological"
echo "    Playouts  → each channel (classic flood)"
echo
echo "    M3U:  $ETV/iptv/channels.m3u"
echo "    UI:   $ETV"
echo
sleep 3
curl -sS "$ETV/iptv/channels.m3u" 2>/dev/null | grep -E "MTV|EXTINF|#EXTM3U" | head -30 || true
