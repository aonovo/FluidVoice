#!/usr/bin/env python3
"""Measure microphone start latency of FluidVoice Debug per media-suppression mode.

Drives the Debug app's own toggle path (FluidDebugRemoteToggleEnabled), then reads
~/Library/Logs/Fluid/Fluid.log for ASR_BENCH first_audio and MEDIA_BENCH lines.

  bench_media.py set-mic BuiltInMicrophoneDevice   # FluidVoice picks the first entry of MicrophonePriority
  bench_media.py run --modes none,pause,duck --count 20 --label builtin-before --expect-input MacBook
  bench_media.py report results/*.json
  bench_media.py restore-mic
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
CAPTURE_DEVICE = re.compile(r"device='([^']*)'")
MIC_BACKUP = HERE / "results" / ".mic-priority-backup.json"


def defaults_write(key, kind, value):
    subprocess.run(["defaults", "write", DOMAIN, key, kind, value], check=True)


def set_mode(mode, level):
    defaults_write("PauseMediaDuringTranscription", "-bool", "NO" if mode == "none" else "YES")
    defaults_write("DuckMediaInsteadOfPausing", "-bool", "YES" if mode == "duck" else "NO")
    defaults_write("DuckMediaVolumeLevel", "-float", str(level))


def read_defaults():
    import plistlib

    exported = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True, check=True).stdout
    return plistlib.loads(exported)


def write_priority(raw):
    subprocess.run(["defaults", "write", DOMAIN, "MicrophonePriority", "-data", raw.hex()], check=True)


def set_mic(uid):
    """FluidVoice records from the first available entry of MicrophonePriority;
    PreferredInputDeviceUID alone does not switch the microphone."""
    settings = read_defaults()
    raw = settings.get("MicrophonePriority", b"[]")
    if not MIC_BACKUP.exists():
        MIC_BACKUP.parent.mkdir(exist_ok=True)
        MIC_BACKUP.write_bytes(raw)
    entries = json.loads(raw)
    entry = next((e for e in entries if e["uid"] == uid), {"uid": uid, "name": uid})
    entries = [entry] + [e for e in entries if e["uid"] != uid]
    write_priority(json.dumps(entries, ensure_ascii=False, separators=(",", ":")).encode())
    defaults_write("PreferredInputDeviceUID", "-string", uid)
    print(f"microphone priority -> {entry['name']} first")


def restore_mic():
    if MIC_BACKUP.exists():
        write_priority(MIC_BACKUP.read_bytes())
        MIC_BACKUP.unlink()
        print("microphone priority restored")


def output_volume():
    out = subprocess.run(
        ["osascript", "-e", "output volume of (get volume settings)"], capture_output=True, text=True
    ).stdout.strip()
    return int(out) if out.isdigit() else None


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
        elif "device resolved" in line and current is not None:
            match = CAPTURE_DEVICE.search(line)
            if match:
                sessions[current]["inputDevice"] = match.group(1)
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
    # "devices" is the system default input/output; the microphone FluidVoice records
    # from is taken per session from its own log (inputDevice).
    results = {"label": args.label, "devices": output_device(), "modes": {}, "volume": {}}
    print(f"devices: {results['devices']}")
    modes = args.modes.split(",")
    for mode in modes:
        set_mode(mode, args.level)
        time.sleep(1.0)
        for _ in range(args.warmup):
            dictation(args.record, args.gap)
        offset = mark()
        baseline = output_volume()
        after = []
        print(f"[{mode}] {args.count} dictations, record {args.record}s, gap {args.gap}s, volume {baseline}")
        for index in range(args.count):
            dictation(args.record, args.gap)
            after.append(output_volume())
            print(f"  {index + 1}/{args.count}", end="\r", flush=True)
        time.sleep(2.0)
        sessions = parse(read_new(offset))
        results["modes"][mode] = sessions
        results["volume"][mode] = {"baseline": baseline, "after": after}
        got = [s for s in sessions.values() if "elapsedMs" in s]
        mics = sorted({s.get("inputDevice", "unknown") for s in sessions.values()})
        print(f"  [{mode}] sessions with first_audio: {len(got)}/{args.count}, mic: {', '.join(mics)}")
        known = [mic for mic in mics if mic != "unknown"]
        if args.expect_input and (not known or any(args.expect_input not in mic for mic in known)):
            subprocess.run(["pkill", "-f", "FluidVoice Debug.app"])
            sys.exit(f"wrong input: expected {args.expect_input!r}, recorded from {mics}")
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
    print("\n| run | mode | mic | n | first audio median ms | p95 | max | CoreAudio calls on main thread | CoreAudio per call median µs | max µs | duck ms | restore ms | volume back |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
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
            mics = ", ".join(sorted({s.get("inputDevice", "?") for s in sessions}))
            volume = data.get("volume", {}).get(mode)
            if volume and volume["baseline"] is not None:
                back = sum(1 for v in volume["after"] if v is not None and abs(v - volume["baseline"]) <= 1)
                volume_back = f"{back}/{len(volume['after'])}"
            else:
                volume_back = "—"
            print(
                f"| {data['label']} | {mode} | {mics} | {len(elapsed)} | {fmt(elapsed)} | {pct(elapsed, 0.95) if elapsed else '—'} | "
                f"{max(elapsed) if elapsed else '—'} | {on_main}/{len(calls)} | {fmt(us)} | {max(us) if us else '—'} | "
                f"{fmt(duck)} | {fmt(restore)} | {volume_back} |"
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
    run_parser.add_argument("--expect-input", help="abort unless every session recorded from a mic containing this")
    report_parser = sub.add_parser("report")
    report_parser.add_argument("paths", nargs="+")
    mic_parser = sub.add_parser("set-mic")
    mic_parser.add_argument("uid")
    sub.add_parser("restore-mic")
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    elif args.command == "set-mic":
        set_mic(args.uid)
    elif args.command == "restore-mic":
        restore_mic()
    else:
        report(args.paths)


if __name__ == "__main__":
    main()
