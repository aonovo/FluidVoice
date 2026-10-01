#!/usr/bin/env python3
"""Does music left playing at a ducked level hurt recognition on speakers?

Speaks reference phrases with `say` through the default output while a music file
plays via `afplay -v <level>` on the same output, records each phrase with the
FluidVoice Debug toggle trigger (suppression off, so the music level is exactly the
one under test) and scores the transcript against the reference (WER).

  accuracy.py --music track.mp3 --conditions silence,0.2,1.0 --label speakers
"""

import argparse
import json
import re
import subprocess
import time
from pathlib import Path

import bench_media as bench

PHRASES = [
    ("Samantha", "The birch canoe slid on the smooth planks."),
    ("Samantha", "Glue the sheet to the dark blue background."),
    ("Samantha", "It's easy to tell the depth of a well."),
    ("Samantha", "These days a chicken leg is a rare dish."),
    ("Samantha", "Rice is often served in round bowls."),
    ("Samantha", "The juice of lemons makes fine punch."),
    ("Samantha", "The box was thrown beside the parked truck."),
    ("Samantha", "Four hours of steady work faced us."),
    ("Milena", "Завтра утром я отправлю отчёт по проекту."),
    ("Milena", "Нужно проверить настройки микрофона перед встречей."),
    ("Milena", "Музыка играет тихо и почти не мешает работе."),
    ("Milena", "Пожалуйста, перезвоните мне после обеда."),
]

TRANSCRIPT = re.compile(r"After post-processing: '(.*)'")


def words(text):
    return re.sub(r"[^\w\s]", " ", text.lower().replace("ё", "е")).split()


def wer(reference, hypothesis):
    ref, hyp = words(reference), words(hypothesis)
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, row[0] = row[0], i
        for j, h in enumerate(hyp, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (r != h))
    return row[len(hyp)] / max(len(ref), 1), len(ref)


def last_transcript(offset):
    found = [m.group(1) for line in bench.read_new(offset) if (m := TRANSCRIPT.search(line))]
    return found[-1] if found else ""


def run_condition(condition, music, settle):
    player = None
    if condition != "silence":
        player = subprocess.Popen(["afplay", "-v", condition, str(music)])
        time.sleep(2.0)
    rows = []
    try:
        for voice, phrase in PHRASES:
            offset = bench.mark()
            bench.ensure_safe_target()
            bench.toggle()
            time.sleep(0.6)
            subprocess.run(["say", "-v", voice, phrase], check=True)
            time.sleep(0.6)
            bench.ensure_safe_target()
            bench.toggle()
            time.sleep(settle)
            hypothesis = last_transcript(offset)
            error, count = wer(phrase, hypothesis)
            rows.append({"voice": voice, "reference": phrase, "hypothesis": hypothesis, "wer": error, "words": count})
            print(f"  [{condition}] {error:.2f}  {hypothesis}")
    finally:
        if player:
            player.terminate()
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--music", required=True)
    parser.add_argument("--conditions", default="silence,0.2,1.0")
    parser.add_argument("--settle", type=float, default=3.0)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    bench.set_mode("none", 0.25)
    results = {"label": args.label, "devices": bench.output_device(), "conditions": {}}
    for condition in args.conditions.split(","):
        results["conditions"][condition] = run_condition(condition, Path(args.music), args.settle)
    out = bench.HERE / "results" / f"accuracy-{args.label}.json"
    out.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(f"saved {out}\n")
    print("| music level | language | phrases | words | WER |")
    print("|---|---|---|---|---|")
    for condition, rows in results["conditions"].items():
        for language, voice in (("en", "Samantha"), ("ru", "Milena")):
            subset = [r for r in rows if r["voice"] == voice]
            total = sum(r["words"] for r in subset)
            errors = sum(r["wer"] * r["words"] for r in subset)
            print(f"| {condition} | {language} | {len(subset)} | {total} | {errors / max(total, 1):.1%} |")


if __name__ == "__main__":
    main()
