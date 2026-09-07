#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# != 5 )); then
    echo "Usage: $0 OUTPUT ASPECT_WIDTH ASPECT_HEIGHT OUTPUT_WIDTH OUTPUT_HEIGHT" >&2
    exit 2
fi

OUTPUT_PATH="$1"
ASPECT_WIDTH="$2"
ASPECT_HEIGHT="$3"
OUTPUT_WIDTH="$4"
OUTPUT_HEIGHT="$5"

for VALUE in \
    "$ASPECT_WIDTH" \
    "$ASPECT_HEIGHT" \
    "$OUTPUT_WIDTH" \
    "$OUTPUT_HEIGHT"
do
    if [[ ! "$VALUE" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid capture dimension: $VALUE" >&2
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
        if pw-link "$OUTPUT_PORT" "$INPUT_PORT"; then
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

if (( 1280 * ASPECT_HEIGHT >
      720 * ASPECT_WIDTH ))
then
    CROP_WIDTH=$((720 * ASPECT_WIDTH / ASPECT_HEIGHT))
    CROP_HEIGHT=720
else
    CROP_WIDTH=1280
    CROP_HEIGHT=$((1280 * ASPECT_HEIGHT / ASPECT_WIDTH))
fi

CROP_WIDTH=$((CROP_WIDTH - CROP_WIDTH % 2))
CROP_HEIGHT=$((CROP_HEIGHT - CROP_HEIGHT % 2))


FILTER="crop=${CROP_WIDTH}:${CROP_HEIGHT}:(in_w-out_w)/2:(in_h-out_h)/2"
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
