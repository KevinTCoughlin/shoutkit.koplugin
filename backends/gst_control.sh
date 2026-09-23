#!/bin/sh
# Owns a gst-launch-1.0 pipeline and speaks the protocol in docs/PROTOCOL.md.
#
# mpv has an IPC channel, so its control script rides inside mpv itself.
# gst-launch-1.0 has nothing of the kind: it parses a pipeline, runs it, and
# exits. Everything the protocol asks for -- a status file, a command file, a
# state machine -- therefore has to live in a wrapper process, and this is it.
#
# Every input arrives as an environment variable, because a Kobo's busybox sh
# and a desktop's dash disagree about almost everything else:
#
#   KOAUDIO_STATUS    path to write  <base>.status
#   KOAUDIO_COMMAND   path to read   <base>.command
#   KOAUDIO_LOG       path for gst-launch's stderr
#   KOAUDIO_URL       the stream URL or the local file path
#   KOAUDIO_KIND      stream | file
#   KOAUDIO_SINK      sink element, already chosen by the backend
#   KOAUDIO_VOLUME    0-100, baked into the pipeline at start
#   KOAUDIO_FETCH     wget | curl | none   (how a stream's bytes are fetched)
#   KOAUDIO_START     seconds to start a file at (0 when starting at the top)
#   KOAUDIO_BYTE_RATE bytes per second, for turning seconds into a byte offset;
#                     0 means the caller could not work it out and seeking is off
set -u

STATUS="${KOAUDIO_STATUS:?}"
COMMAND="${KOAUDIO_COMMAND:?}"
LOG="${KOAUDIO_LOG:-/dev/null}"
URL="${KOAUDIO_URL:?}"
KIND="${KOAUDIO_KIND:-stream}"
SINK="${KOAUDIO_SINK:-autoaudiosink}"
VOLUME="${KOAUDIO_VOLUME:-70}"
FETCH="${KOAUDIO_FETCH:-none}"
START="${KOAUDIO_START:-0}"
BYTE_RATE="${KOAUDIO_BYTE_RATE:-0}"

SEQ=0               # highest command sequence number applied
GST_PID=""          # the pipeline, or the fetch|pipeline shell
STATE=stopped
PAUSED=0
OFFSET="$START"     # seconds into the item that the current pipeline began at
STARTED_AT=0        # wall clock when the current pipeline began
WANT_EXIT=0
ERROR=""
PAUSED_AT=0         # position the pause froze at, so elapsed stops advancing

now() { date +%s 2>/dev/null || echo 0; }

# Atomic, because the reader is KOReader polling from a UIManager task and a
# half-written file there is a parse error inside the event loop. On Kindle's
# FAT storage it can be a read error instead, which is worse.
write_status() {
    elapsed=0
    if [ "$STATE" = playing ]; then
        elapsed=$(( $(now) - STARTED_AT + OFFSET ))
    elif [ "$STATE" = paused ]; then
        # The wall clock keeps running; the episode does not. Reporting
        # now-STARTED_AT here would march the position forward through a pause
        # and then jump the audio backwards on resume.
        elapsed="$PAUSED_AT"
    fi
    [ "$elapsed" -lt 0 ] && elapsed=0
    # A live stream has no meaningful position, and reporting one invites the UI
    # to draw a progress bar that means nothing.
    [ "$KIND" = stream ] && elapsed=0
    {
        echo "state=$STATE"
        echo "volume=$VOLUME"
        echo "elapsed=$elapsed"
        echo "duration=0"
        echo "seq=$SEQ"
        # gst-launch prints no tags we can read without a bus watch, and the
        # device has no ICY-capable source element anyway, so title stays empty
        # rather than pretending.
        echo "title="
        if [ -n "$ERROR" ]; then echo "error=$ERROR"; fi
        # The group's exit status is the last command's, and it gates the rename
        # below. An `[ -n "$ERROR" ] && echo` here would return non-zero on the
        # ordinary no-error path and silently skip writing the file at all.
    } > "$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS" 2>/dev/null
}

set_state() {
    STATE="$1"
    write_status
}

# The whole pipeline, as one shell word list. Two genuinely different shapes:
# a file GStreamer can open itself, and a stream it cannot, because no Kobo
# firmware ships an HTTP source element (docs/probe-clara-colour-2.txt).
decode_chain() {
    # mpg123audiodec is the only audio decoder on an MTK Kobo. Naming the
    # elements rather than using decodebin keeps the failure honest: a format
    # this chain cannot handle fails at once instead of silently producing no
    # audio.
    printf '%s' "mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample"
}

gst_volume() {
    # GStreamer's volume element takes a linear 0.0-1.0 multiplier.
    awk "BEGIN { printf \"%.3f\", $VOLUME / 100 }" 2>/dev/null || echo 1.0
}

# setsid puts the pipeline in its own process group, which is what makes a
# clean group kill possible later. Without it a backgrounded job inherits this
# script's group, and `kill -- -$pid` would either fail or -- if that number
# happened to name a real group -- take down something it had no business
# touching. Busybox has setsid; when it is missing we fall back to killing the
# shell and then its children by hand.
HAVE_SETSID=0
command -v setsid >/dev/null 2>&1 && HAVE_SETSID=1

spawn() {
    if [ "$HAVE_SETSID" = 1 ]; then
        setsid sh -c "$1" >>"$LOG" 2>&1 &
    else
        sh -c "$1" >>"$LOG" 2>&1 &
    fi
    GST_PID=$!
}

start_pipeline() {
    ERROR=""
    chain="$(decode_chain) ! volume volume=$(gst_volume) ! $SINK"

    if [ "$KIND" = file ]; then
        if [ "$OFFSET" -gt 0 ] && [ "$BYTE_RATE" -gt 0 ]; then
            # gst-launch cannot be told to seek, so the seek happens before the
            # bytes reach it: skip ahead in the file and feed the rest down a
            # pipe. Byte-accurate only for constant bitrate, which is what the
            # caller's byte rate assumes; mpegaudioparse resynchronises to the
            # next frame header, so a mid-frame landing costs at most one frame.
            skip=$(( OFFSET * BYTE_RATE / 4096 ))
            spawn "dd if=$URL bs=4096 skip=$skip 2>/dev/null | gst-launch-1.0 -q fdsrc fd=0 ! $chain"
        else
            OFFSET=0
            spawn "gst-launch-1.0 -q filesrc location=$URL ! $chain"
        fi
    else
        case "$FETCH" in
            wget) fetcher="wget -q -O - $URL" ;;
            curl) fetcher="curl -s -L $URL" ;;
            *)
                ERROR="no HTTP client to feed the pipeline"
                set_state error
                return 1
                ;;
        esac
        # queue2 is the buffer. Without it every hiccup on the link is a gap in
        # the audio, and on an e-reader's Wi-Fi there are many.
        spawn "$fetcher | gst-launch-1.0 -q fdsrc fd=0 ! queue2 max-size-time=10000000000 ! $chain"
    fi

    STARTED_AT=$(now)
    # Nothing here can tell when sound actually starts -- there is no bus to
    # watch -- so we claim buffering and let the next tick call it playing.
    set_state buffering
    return 0
}

# Signals the pipeline and everything under it. Killing the wrapper shell alone
# would orphan gst-launch, and on MTK Kobo an orphan keeps the exclusive A2DP
# socket -- which makes every later attempt fail for reasons the user cannot
# see. This is the single most important thing in this file.
signal_pipeline() {
    sig="$1"
    [ -n "$GST_PID" ] || return 0
    # Both routes, always. The group kill is the one that works when setsid put
    # the pipeline in its own session; the child hunt covers the case where it
    # did not, including a setsid that chose to fork rather than exec. Signals
    # to processes that are already gone are free, so trying both costs nothing
    # and leaving an orphan holding the A2DP socket costs everything.
    kill "-$sig" -- "-$GST_PID" 2>/dev/null
    kill "-$sig" "$GST_PID" 2>/dev/null
    # /proc rather than `ps -o`: Kobo's busybox ps takes no format options, so
    # parsing its columns would work on the desktop and quietly do nothing on
    # the device -- which is exactly where the orphan matters.
    for stat in /proc/[0-9]*/stat; do
        [ -r "$stat" ] || continue
        # "pid (comm) state ppid ...", and comm can contain spaces, so cut after
        # the last ')' rather than splitting the whole line on whitespace.
        set -- $(sed -e 's/.*) //' "$stat" 2>/dev/null)
        [ "${2:-}" = "$GST_PID" ] || continue
        child="${stat#/proc/}"
        kill "-$sig" "${child%/stat}" 2>/dev/null
    done
}

stop_pipeline() {
    if [ -n "$GST_PID" ]; then
        signal_pipeline TERM
        # Poll for the exit rather than sleeping a flat second: this runs on
        # every seek, and a second of dead air per seek is the difference
        # between a scrubber that feels broken and one that does not.
        i=0
        while [ "$i" -lt 10 ] && kill -0 "$GST_PID" 2>/dev/null; do
            sleep 0.1 2>/dev/null || sleep 1
            i=$((i + 1))
        done
        signal_pipeline KILL
        wait "$GST_PID" 2>/dev/null
        GST_PID=""
    fi
}

pipeline_alive() {
    [ -n "$GST_PID" ] && kill -0 "$GST_PID" 2>/dev/null
}

# Where we are now, so a restart can resume from the same place.
current_position() {
    if [ "$STATE" = playing ] || [ "$STATE" = paused ]; then
        pos=$(( $(now) - STARTED_AT + OFFSET ))
        [ "$pos" -lt 0 ] && pos=0
        echo "$pos"
    else
        echo "$OFFSET"
    fi
}

restart_at() {
    OFFSET="$1"
    [ "$OFFSET" -lt 0 ] && OFFSET=0
    # Say so before tearing anything down. A restart takes about a second, and
    # without this the status file keeps advertising the old pipeline's position
    # the whole time -- so a UI polling it shows the pre-seek position, then
    # jumps. Announcing `buffering` first is also what lets a caller tell "the
    # seek has not landed yet" from "the seek did nothing".
    set_state buffering
    stop_pipeline
    start_pipeline
}

apply_command() {
    verb="$1"
    arg="${2:-}"
    case "$verb" in
        stop)
            WANT_EXIT=1
            ;;
        pause)
            if [ "$KIND" = file ]; then
                # SIGSTOP freezes the pipeline where it is; the sink holds its
                # buffers and picks up where it left off.
                PAUSED_AT=$(current_position)
                signal_pipeline STOP
                PAUSED=1
                set_state paused
            else
                # A paused live stream is a stopped one: the broadcast carries
                # on without us, and holding the socket open only burns Wi-Fi.
                PAUSED_AT=$(current_position)
                stop_pipeline
                PAUSED=1
                set_state paused
            fi
            ;;
        resume)
            if [ "$PAUSED" = 1 ]; then
                if [ "$KIND" = file ] && pipeline_alive; then
                    signal_pipeline CONT
                    # The clock ran while we were stopped; rebase it so elapsed
                    # does not jump by the length of the pause.
                    OFFSET="$PAUSED_AT"
                    STARTED_AT=$(now)
                else
                    start_pipeline
                fi
                PAUSED=0
                set_state playing
            fi
            ;;
        seek)
            if [ "$KIND" = file ] && [ "$BYTE_RATE" -gt 0 ]; then
                restart_at $(( $(current_position) + arg ))
            fi
            ;;
        seek_to)
            if [ "$KIND" = file ] && [ "$BYTE_RATE" -gt 0 ]; then
                restart_at "$arg"
            fi
            ;;
        volume)
            # No control channel means no live volume change: the value is baked
            # into the pipeline. Record it so the next start uses it, and so the
            # status file tells the UI the truth about what is set.
            VOLUME="$arg"
            write_status
            ;;
        loadfile)
            URL="$arg"
            restart_at 0
            ;;
    esac
}

read_commands() {
    [ -f "$COMMAND" ] || return 0
    # Re-read from the top every tick: the file is append-only and SEQ filters
    # what we have already applied, which is what makes this safe without any
    # cursor to lose.
    while read -r seq verb arg; do
        case "$seq" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$seq" -gt "$SEQ" ]; then
            SEQ="$seq"
            apply_command "$verb" "${arg:-}"
        fi
    done < "$COMMAND"
}

trap 'WANT_EXIT=1' TERM INT

: > "$LOG" 2>/dev/null
set_state opening
start_pipeline || exit 1

while [ "$WANT_EXIT" = 0 ]; do
    read_commands
    [ "$WANT_EXIT" = 1 ] && break

    if [ "$PAUSED" = 0 ]; then
        if pipeline_alive; then
            [ "$STATE" = buffering ] && set_state playing
        else
            # It ended. For a file that is the end of the episode; for a stream
            # it is the link dropping, which the controller retries.
            if [ "$KIND" = file ]; then
                STATE=stopped
                break
            fi
            ERROR="$(tail -c 400 "$LOG" 2>/dev/null | tr '\n' ' ')"
            [ -z "$ERROR" ] && ERROR="the stream ended"
            set_state error
            break
        fi
    fi

    write_status
    # 4 Hz, matching the mpv backend: fast enough that a stop feels immediate,
    # slow enough to be invisible on a device this small.
    sleep 0.25 2>/dev/null || sleep 1
done

stop_pipeline
[ "$STATE" = error ] || STATE=stopped
write_status
