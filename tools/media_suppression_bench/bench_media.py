#!/usr/bin/env python3
"""Measure microphone start latency of FluidVoice Debug per media-suppression mode.

Drives the Debug app's own toggle path (FluidDebugRemoteToggleEnabled), then reads
~/Library/Logs/Fluid/Fluid.log for ASR_BENCH first_audio and MEDIA_BENCH lines.

  bench_media.py run --modes none,pause,duck --count 20 --label builtin-before
  bench_media.py report results/*.json
"""

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOG = Path.home() / "Library/Logs/Fluid/Fluid.log"
DOMAIN = "com.FluidApp.app.debug"
POST = HERE / "post-note"
TOGGLE = "com.FluidApp.debug.toggleRecording"

FIELD = re.compile(r"(\w+)=(\S+)")


def defaults_write(key, kind, value):
    subprocess.run(["defaults", "write", DOMAIN, key, kind, value], check=True)


def set_mode(mode, level):
    defaults_write("PauseMediaDuringTranscription", "-bool", "NO" if mode == "none" else "YES")
    defaults_write("DuckMediaInsteadOfPausing", "-bool", "YES" if mode == "duck" else "NO")
    defaults_write("DuckMediaVolumeLevel", "-float", str(level))


def output_device():
    out = subprocess.run(
        ["system_profiler", "SPAudioDataType", "-json"], capture_output=True, text=True
    ).stdout
    try:
        items = json.loads(out)["SPAudioDataType"][0]["_items"]
    except (KeyError, IndexError, ValueError):
        return {}
    result = {}
    for item in items:
        if item.get("coreaudio_default_audio_output_device") == "spaudio_yes":
            result["output"] = item.get("_name")
        if item.get("coreaudio_default_audio_input_device") == "spaudio_yes":
            result["input"] = item.get("_name")
    return result


def toggle():
    subprocess.run([str(POST), TOGGLE], check=True)


def frontmost():
    return subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true'],
        capture_output=True, text=True,
    ).stdout.strip()


def ensure_safe_target():
    """Transcripts are pasted into the frontmost app; only ever let that be TextEdit."""
    for _ in range(3):
        if frontmost() == "TextEdit":
            return
        subprocess.run(["osascript", "-e", 'tell application "TextEdit" to activate'], capture_output=True)
        time.sleep(0.3)
    subprocess.run(["pkill", "-f", "FluidVoice Debug.app"])
    sys.exit(f"aborted: frontmost app is {frontmost()!r}, not TextEdit; Debug app killed so nothing is pasted")


def dictation(record, gap):
    ensure_safe_target()
    toggle()
    time.sleep(record)
    ensure_safe_target()
    toggle()
    time.sleep(gap)


def mark():
    """A log position that survives rotation: Fluid.log is renamed to Fluid.log.1
    (same inode) when it reaches 1 MB, so remember the inode with the offset."""
    stat = LOG.stat()
    return (stat.st_ino, stat.st_size)


def read_from(path, offset):
    with path.open("rb") as handle:
        handle.seek(offset)
        return handle.read().decode("utf-8", "replace").splitlines()


def read_new(position):
    inode, offset = position
    lines = []
    if LOG.stat().st_ino != inode:
        backup = LOG.with_name("Fluid.log.1")
        if backup.exists() and backup.stat().st_ino == inode:
            lines += read_from(backup, offset)
        else:
            print("  warning: log rotated more than once, some lines are lost")
        offset = 0
    return lines + read_from(LOG, offset)


def parse(lines):
    """Group first_audio and CoreAudio timings by recording session."""
    sessions = {}
    current = None
    for line in lines:
        if "MEDIA_CONTROL recording_started" in line:
            fields = dict(FIELD.findall(line))
            current = int(fields["session"])
            sessions.setdefault(current, {"coreaudio": []})["suppression"] = fields.get("suppression")
        elif "ASR_BENCH" in line and " first_audio " in line:
            fields = dict(FIELD.findall(line))
            sid = int(fields["session"])
            entry = sessions.setdefault(sid, {"coreaudio": []})
            entry.setdefault("elapsedMs", int(fields["elapsedMs"]))
            entry.setdefault("acquisitionMs", int(fields["acquisitionMs"]))
        elif "MEDIA_BENCH" in line and current is not None:
            fields = dict(FIELD.findall(line))
            sessions[current]["coreaudio"].append(
                {
                    "op": fields["op"],
                    "result": fields["result"],
                    "us": int(fields["us"]),
                    "mainThread": fields["mainThread"] == "true",
                }
            )
        elif "MEDIA_CONTROL duck_applied" in line or "MEDIA_CONTROL duck_restored" in line:
            fields = dict(FIELD.findall(line))
            sid = int(fields["session"]) if "session" in fields else current
            key = "duckMs" if "duck_applied" in line else "restoreMs"
            if sid in sessions and "elapsedMs" in fields:
                sessions[sid][key] = int(fields["elapsedMs"])
    return sessions


def run(args):
    if not POST.exists():
        sys.exit(f"missing {POST}; compile post-note.swift first")
    results = {"label": args.label, "devices": output_device(), "modes": {}}
    print(f"devices: {results['devices']}")
    modes = args.modes.split(",")
    for mode in modes:
        set_mode(mode, args.level)
        time.sleep(1.0)
        for _ in range(args.warmup):
            dictation(args.record, args.gap)
        offset = mark()
        print(f"[{mode}] {args.count} dictations, record {args.record}s, gap {args.gap}s")
        for index in range(args.count):
            dictation(args.record, args.gap)
            print(f"  {index + 1}/{args.count}", end="\r", flush=True)
        time.sleep(2.0)
        sessions = parse(read_new(offset))
        results["modes"][mode] = sessions
        got = [s for s in sessions.values() if "elapsedMs" in s]
        print(f"  [{mode}] sessions with first_audio: {len(got)}/{args.count}")
    out = HERE / "results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=2))
    print(f"saved {out}")
    report([out])


def pct(values, q):
    values = sorted(values)
    if not values:
        return float("nan")
    index = min(len(values) - 1, max(0, round(q * (len(values) - 1))))
    return values[index]


def report(paths):
    print("\n| run | mode | n | first audio median ms | p95 | max | CoreAudio calls on main thread | CoreAudio per call median µs | max µs | duck ms | restore ms |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for path in paths:
        data = json.loads(Path(path).read_text())
        for mode, sessions in data["modes"].items():
            sessions = sessions.values()
            elapsed = [s["elapsedMs"] for s in sessions if "elapsedMs" in s]
            calls = [c for s in sessions for c in s["coreaudio"]]
            on_main = sum(1 for c in calls if c["mainThread"])
            us = [c["us"] for c in calls]
            duck = [s["duckMs"] for s in sessions if "duckMs" in s]
            restore = [s["restoreMs"] for s in sessions if "restoreMs" in s]
            fmt = lambda v: "—" if not v else f"{statistics.median(v):.0f}"
            print(
                f"| {data['label']} | {mode} | {len(elapsed)} | {fmt(elapsed)} | {pct(elapsed, 0.95) if elapsed else '—'} | "
                f"{max(elapsed) if elapsed else '—'} | {on_main}/{len(calls)} | {fmt(us)} | {max(us) if us else '—'} | "
                f"{fmt(duck)} | {fmt(restore)} |"
            )


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--modes", default="none,pause,duck")
    run_parser.add_argument("--count", type=int, default=20)
    run_parser.add_argument("--record", type=float, default=2.0)
    run_parser.add_argument("--gap", type=float, default=3.0)
    run_parser.add_argument("--level", type=float, default=0.25)
    run_parser.add_argument("--warmup", type=int, default=1)
    run_parser.add_argument("--label", required=True)
    report_parser = sub.add_parser("report")
    report_parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    else:
        report(args.paths)


if __name__ == "__main__":
    main()
