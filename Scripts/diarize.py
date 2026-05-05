#!/usr/bin/env -S uv run --script
#
# /// script
# requires-python = ">=3.12"
# dependencies = ["pyannote.audio", "torch"]
# ///

"""Speaker diarization for meeting recordings. Outputs speaker-labeled segments."""

import argparse
import json
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description="Speaker diarization")
    parser.add_argument("--input", required=True, help="WAV file to diarize")
    parser.add_argument("--token", default=None, help="HuggingFace token (or set HF_TOKEN env)")
    parser.add_argument("--num-speakers", type=int, default=0, help="Expected speaker count (0=auto)")
    parser.add_argument("--output", default=None, help="Output JSON file (default: stdout)")
    args = parser.parse_args()

    wav_path = Path(args.input)
    if not wav_path.exists():
        print(f"ERROR: {args.input} not found", file=sys.stderr)
        sys.exit(1)

    token = args.token or None  # pyannote uses env HF_TOKEN if not passed
    if not token:
        print("Set HF_TOKEN env or pass --token for pyannote model access", file=sys.stderr)
        print("Get a token: https://huggingface.co/settings/tokens", file=sys.stderr)
        sys.exit(1)

    try:
        from pyannote.audio import Pipeline
    except ImportError:
        print("pyannote.audio not installed", file=sys.stderr)
        sys.exit(1)

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=token,
    )

    # Run diarization
    diarization = pipeline(str(wav_path), num_speakers=args.num_speakers or None)

    # pyannote 4.x: DiarizeOutput wraps speaker_diarization (Annotation)
    annotation = (
        getattr(diarization, "speaker_diarization", None)
        or diarization
    )

    segments = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        segments.append({
            "start": round(turn.start, 2),
            "end": round(turn.end, 2),
            "speaker": str(speaker),
        })

    result = json.dumps(segments, indent=2, ensure_ascii=False)

    if args.output:
        Path(args.output).write_text(result + "\n")
        print(f"[diarize] {len(segments)} speaker segments → {args.output}", file=sys.stderr)
    else:
        print(result)


if __name__ == "__main__":
    main()
