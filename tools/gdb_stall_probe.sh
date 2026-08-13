#!/bin/bash
# tools/gdb_stall_probe.sh — SMP stall forensics helper.
#
# Boots the x86_64 kernel in QEMU with a GDB stub (no halt-at-start), SMP=4,
# serial to a temp log. Watches the log: on reaching the shell marker the run
# is a pass and the next iteration starts; on no log growth for STALL_SECS
# the run is presumed stalled and a batch GDB session dumps every vCPU's
# registers and the kernel task-table state before QEMU is killed.
#
# Usage:   ./tools/gdb_stall_probe.sh [max_iterations]
# Output:  /tmp/stall-probe-<ts>/run-<n>.{log,gdb.txt}
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

MAX_ITER="${1:-6}"
STALL_SECS="${STALL_SECS:-90}"
GDB_PORT="${GDB_PORT:-1234}"
OUT_DIR="$(mktemp -d "/tmp/stall-probe-$(date +%s)-XXXX")"

GDB_CMDS="$OUT_DIR/probe.gdb"
cat > "$GDB_CMDS" <<'EOF'
set pagination off
target remote :1234
printf "=== per-vCPU registers ===\n"
thread apply all info registers rip rsp eflags
printf "=== per-vCPU backtraces ===\n"
thread apply all bt 6
printf "=== task table ===\n"
set $bm = 'proc.task.slot_bitmap'
printf "slot_bitmap = 0x%lx\n", $bm
printf "task_lock.locked = %d\n", 'proc.task.task_lock'.locked
printf "sleep_bm = 0x%lx\n", 'proc.sched.sleep_bm'
printf "ctty_owner_sid = %d foreground_pgid = %d\n", 'proc.jobctl.ctty_owner_sid', 'proc.jobctl.foreground_pgid'
set $i = 0
while $i < 64
  if ($bm >> $i) & 1
    set $t = &'proc.task.tasks'[$i]
    printf "slot %2d tid=%3d parent=%3d state=%d stopped=%d is_thread=%d is_user=%d sid=%d pgid=%d sleep_deadline=%lu wait_child=%d\n", $i, $t.tid, $t.parent_tid, $t.state, $t.stopped, $t.is_thread, $t.is_user, $t.sid, $t.pgid, $t.sleep_deadline_ns, $t.waiting_for_child
    if $t.is_user && $t.state != 1
      printf "--- saved frame at saved_rsp=0x%lx ---\n", $t.saved_rsp
      x/24gx $t.saved_rsp
    end
  end
  set $i = $i + 1
end
detach
quit
EOF

echo "[probe] output dir: $OUT_DIR"
zig build || exit 1

for ((iter = 1; iter <= MAX_ITER; iter++)); do
    LOG="$OUT_DIR/run-$iter.log"
    echo "[probe] iteration $iter/$MAX_ITER (log: $LOG)"
    # Private disk copy per iteration: the boot writes to the ext2 image and
    # the canonical fixture must stay untouched (qemu_run.sh verifies its
    # SHA-256 when MOQI_DISK is unset).
    cp --reflink=auto disk.img "$OUT_DIR/disk-$iter.img"
    MOQI_SERIAL="file:$LOG" MOQI_SMP=4 \
        MOQI_DISK="$OUT_DIR/disk-$iter.img" \
        MOQI_EXTRA_QEMU="-gdb tcp::$GDB_PORT" \
        ./tools/qemu_run.sh >"$OUT_DIR/run-$iter.qemu.log" 2>&1 &
    QPID=$!

    last_size=-1
    last_change=$SECONDS
    outcome="stall"
    while true; do
        if ! kill -0 "$QPID" 2>/dev/null; then outcome="qemu-exited"; break; fi
        if grep -aq "MoQiOS shell" "$LOG" 2>/dev/null; then outcome="pass"; break; fi
        size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
        if [ "$size" != "$last_size" ]; then
            last_size=$size
            last_change=$SECONDS
        elif (( SECONDS - last_change > STALL_SECS )); then
            outcome="stall"
            break
        fi
        sleep 2
    done
    echo "[probe] iteration $iter: $outcome"

    if [ "$outcome" = "stall" ]; then
        gdb -batch -x "$GDB_CMDS" zig-out/bin/moqi-kernel.elf \
            >"$OUT_DIR/run-$iter.gdb.txt" 2>&1 || true
        echo "[probe] gdb dump: $OUT_DIR/run-$iter.gdb.txt"
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
        echo "[probe] STALL captured in run $iter — see $OUT_DIR"
        exit 0
    fi

    kill "$QPID" 2>/dev/null || true
    wait "$QPID" 2>/dev/null || true
done
echo "[probe] no stall in $MAX_ITER iterations"
