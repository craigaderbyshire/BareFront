#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# != 9 )); then
    echo "Usage: $0 OUTPUT SOURCE_WIDTH SOURCE_HEIGHT CROP_X CROP_Y CROP_WIDTH CROP_HEIGHT OUTPUT_WIDTH OUTPUT_HEIGHT" >&2
    exit 2
fi

OUTPUT_PATH="$1"
SOURCE_WIDTH="$2"
SOURCE_HEIGHT="$3"
CROP_X="$4"
CROP_Y="$5"
CROP_WIDTH="$6"
CROP_HEIGHT="$7"
OUTPUT_WIDTH="$8"
OUTPUT_HEIGHT="$9"

for VALUE in \
    "$SOURCE_WIDTH" \
    "$SOURCE_HEIGHT" \
    "$CROP_WIDTH" \
    "$CROP_HEIGHT" \
    "$OUTPUT_WIDTH" \
    "$OUTPUT_HEIGHT"
do
    if [[ ! "$VALUE" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid capture dimension: $VALUE" >&2
        exit 2
    fi
done

for VALUE in \
    "$CROP_X" \
    "$CROP_Y"
do
    if [[ ! "$VALUE" =~ ^[0-9]+$ ]]; then
        echo "Invalid capture position: $VALUE" >&2
        exit 2
    fi
done

for COMMAND in \
    ffmpeg \
    gst-launch-1.0 \
    pw-dump \
    pw-link \
    python3 \
    timeout
do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        echo "Required capture command missing: $COMMAND" >&2
        exit 1
    fi
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

TEMP_OUTPUT="${OUTPUT_PATH}.part.$$.mp4"
RAW_OUTPUT="${OUTPUT_PATH}.raw.$$.mp4"
CLIENT_NAME="BareFront-capture-$$"
CAPTURE_PID=""

cleanup()
{
    if [[ -n "$CAPTURE_PID" ]] &&
       kill -0 "$CAPTURE_PID" 2>/dev/null
    then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi

    rm -f -- "$TEMP_OUTPUT"
    rm -f -- "$RAW_OUTPUT"
}

trap cleanup EXIT INT TERM

NODE_ID="$(
    pw-dump |
    python3 -c '
import json
import sys

for item in json.load(sys.stdin):
    props = item.get("info", {}).get("props", {})

    if props.get("node.name") == "gamescope":
        print(item.get("id", ""))
        break
'
)"

if [[ ! "$NODE_ID" =~ ^[0-9]+$ ]]; then
    echo "Gamescope PipeWire source was not found." >&2
    exit 1
fi

timeout 15s \
    gst-launch-1.0 -q -e \
        pipewiresrc \
            path="$NODE_ID" \
            client-name="$CLIENT_NAME" \
            do-timestamp=true \
        ! queue \
        ! videoconvert \
        ! videorate \
        ! video/x-raw,framerate=30/1 \
        ! identity eos-after=150 \
        ! videoscale \
        ! video/x-raw,width=1280,height=720,pixel-aspect-ratio=1/1 \
        ! x264enc \
            speed-preset=ultrafast \
            tune=zerolatency \
            bitrate=1200 \
            key-int-max=30 \
        ! h264parse \
        ! mp4mux \
        ! filesink location="$RAW_OUTPUT" &

CAPTURE_PID=$!

LINKED=false

for (( ATTEMPT=0; ATTEMPT < 50; ++ATTEMPT )); do
    OUTPUT_PORT="$(
        pw-link -o -I |
        awk '$2 ~ /^gamescope:/ { print $2; exit }'
    )"

    INPUT_PORT="$(
        pw-link -i -I |
        awk -v prefix="${CLIENT_NAME}:" \
            'index($2, prefix) == 1 { print $2; exit }'
    )"

    if [[ -n "$OUTPUT_PORT" &&
          -n "$INPUT_PORT" ]]
    then
        LINK_RESULT=""

        if LINK_RESULT="$(LC_ALL=C pw-link "$OUTPUT_PORT" "$INPUT_PORT" 2>&1)"; then
            LINKED=true
            break
        fi

        if [[ "$LINK_RESULT" == *"File exists"* ]]; then
            LINKED=true
            break
        fi
    fi

    if ! kill -0 "$CAPTURE_PID" 2>/dev/null; then
        break
    fi

    sleep 0.1
done

if [[ "$LINKED" != true ]]; then
    echo "Could not link Gamescope to the capture pipeline." >&2
    exit 1
fi

set +e
wait "$CAPTURE_PID"
CAPTURE_EXIT=$?
set -e

CAPTURE_PID=""

if (( CAPTURE_EXIT != 0 )); then
    echo "Gamescope recording pipeline failed: $CAPTURE_EXIT" >&2
    exit "$CAPTURE_EXIT"
fi

if [[ ! -s "$RAW_OUTPUT" ]]; then
    echo "Gamescope recording produced no video." >&2
    exit 1
fi

# Map the detected game rectangle from the Gamescope window
# into the fixed 1280x720 PipeWire capture.
PIPEWIRE_WIDTH=1280
PIPEWIRE_HEIGHT=720

PIPE_CROP_X=$((CROP_X * PIPEWIRE_WIDTH / SOURCE_WIDTH))
PIPE_CROP_Y=$((CROP_Y * PIPEWIRE_HEIGHT / SOURCE_HEIGHT))

PIPE_CROP_RIGHT=$(((CROP_X + CROP_WIDTH) * PIPEWIRE_WIDTH / SOURCE_WIDTH))
PIPE_CROP_BOTTOM=$(((CROP_Y + CROP_HEIGHT) * PIPEWIRE_HEIGHT / SOURCE_HEIGHT))

if (( PIPE_CROP_RIGHT > PIPEWIRE_WIDTH )); then
    PIPE_CROP_RIGHT=$PIPEWIRE_WIDTH
fi

if (( PIPE_CROP_BOTTOM > PIPEWIRE_HEIGHT )); then
    PIPE_CROP_BOTTOM=$PIPEWIRE_HEIGHT
fi

# H.264 / yuv420p require even crop coordinates and dimensions.
PIPE_CROP_X=$((PIPE_CROP_X - PIPE_CROP_X % 2))
PIPE_CROP_Y=$((PIPE_CROP_Y - PIPE_CROP_Y % 2))

PIPE_CROP_WIDTH=$((PIPE_CROP_RIGHT - PIPE_CROP_X))
PIPE_CROP_HEIGHT=$((PIPE_CROP_BOTTOM - PIPE_CROP_Y))

PIPE_CROP_WIDTH=$((PIPE_CROP_WIDTH - PIPE_CROP_WIDTH % 2))
PIPE_CROP_HEIGHT=$((PIPE_CROP_HEIGHT - PIPE_CROP_HEIGHT % 2))

if (( PIPE_CROP_WIDTH < 2 ||
      PIPE_CROP_HEIGHT < 2 ))
then
    echo "Mapped Gamescope crop is invalid." >&2
    exit 1
fi

FILTER="crop=${PIPE_CROP_WIDTH}:${PIPE_CROP_HEIGHT}:${PIPE_CROP_X}:${PIPE_CROP_Y}"
FILTER+=",scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:flags=lanczos,setsar=1"

ffmpeg \
    -hide_banner \
    -loglevel error \
    -y \
    -i "$RAW_OUTPUT" \
    -an \
    -vf "$FILTER" \
    -c:v libx264 \
    -preset veryfast \
    -crf 23 \
    -pix_fmt yuv420p \
    "$TEMP_OUTPUT"

rm -f -- "$RAW_OUTPUT"

if [[ ! -s "$TEMP_OUTPUT" ]]; then
    echo "Gamescope recording conversion produced no video." >&2
    exit 1
fi

mv -f -- "$TEMP_OUTPUT" "$OUTPUT_PATH"

trap - EXIT INT TERM

echo "Video saved: $OUTPUT_PATH"
