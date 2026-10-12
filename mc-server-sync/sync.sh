#!/bin/bash

GAME_PATH="/usr/games/minecraft/survival"
TARGET_PATH="$HOME/mc-sync"
REPLAY="server/replay/player"
BLOBS="pb_files/blobs"
PB_DB="pb_files/prime_backup.db"
TMP_DB="tmp.db"
HOST="example.xyz"
PORT="34301"
SSH_USER="fortern"
SSH_KEY="$HOME/.ssh/ForternGame@fortern"

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "command [$1] not found"
        exit 1
    fi
}

check_cmd rsync
check_cmd sqlite3
check_cmd flock

# Keep the lock file in place; closing fd 9 releases the lock automatically.
mkdir -p "$TARGET_PATH"
exec 9>"$TARGET_PATH/.sync.lock"
if flock -n -E 75 9; then
    :
else
    LOCK_STATUS=$?
    if [ "$LOCK_STATUS" -eq 75 ]; then
        log "Another synchronization is running; skipping."
        exit 0
    fi
    log "Failed to acquire synchronization lock."
    exit "$LOCK_STATUS"
fi

# rsync replay
log "REPLAYS synchronization started."
rsync -e "ssh -p $PORT -i $SSH_KEY" -rz $SSH_USER@$HOST:$GAME_PATH/$REPLAY/ $TARGET_PATH/$REPLAY
log "REPLAYS synchronization finished."

# rsync prime_backup.db
log "PB DB synchronization started."
rsync -e "ssh -p $PORT -i $SSH_KEY" -z $SSH_USER@$HOST:$GAME_PATH/$PB_DB $TARGET_PATH/$TMP_DB
log "PB DB synchronization finished."

# rsync pb_blobs
log "PB BLOBS synchronization started."
rsync -e "ssh -p $PORT -i $SSH_KEY" -rz $SSH_USER@$HOST:$GAME_PATH/$BLOBS/ $TARGET_PATH/$BLOBS
log "PB BLOBS synchronization finished."

# CHECK VERSION
VERSION=$(sqlite3 "$TARGET_PATH/$TMP_DB" "SELECT version FROM db_meta LIMIT 1;")
if [ "$VERSION" != "3" ]; then
    log "VERSION ERROR!"
    exit 1
fi
log "PB db_meta checking succeed!"

# merge db
sqlite3 -bail "$TARGET_PATH/$PB_DB" <<EOF
ATTACH DATABASE '$TARGET_PATH/$TMP_DB' AS tmp;
BEGIN IMMEDIATE;

INSERT INTO blob SELECT * FROM tmp.blob WHERE true
ON CONFLICT(hash) DO NOTHING;

INSERT INTO fileset SELECT * FROM tmp.fileset WHERE true
ON CONFLICT(id) DO NOTHING;

INSERT INTO file SELECT * FROM tmp.file WHERE true
ON CONFLICT(fileset_id, path) DO NOTHING;

INSERT INTO backup SELECT * FROM tmp.backup WHERE creator NOT LIKE '%pre_restore%'
ON CONFLICT(id) DO NOTHING;

COMMIT;
DETACH DATABASE tmp;
EOF

rm $TARGET_PATH/$TMP_DB

log "✔ 数据合并完成"
