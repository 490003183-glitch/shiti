#!/usr/bin/env python3
"""Read-only macOS process counters. CPU uses Mach ticks, not nanoseconds.

These counters are not watts or Activity Monitor's Energy Impact score.
Example: python3 scripts/measure-energy.py --pid 123 --seconds 60
"""
import argparse
import ctypes
import json
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_size", "resident_size", "footprint",
            "start_time", "exit_time", "child_user_time", "child_system_time",
            "child_idle_wakeups", "child_interrupt_wakeups", "child_pageins",
            "child_elapsed", "read_bytes", "write_bytes",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=60)
    args = parser.parse_args()
    if args.pid <= 0 or not 1 <= args.seconds <= 3600:
        parser.error("PID must be positive; seconds must be 1–3600")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    clock = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    clock.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    base = Timebase()
    if clock.mach_timebase_info(ctypes.byref(base)) != 0 or base.denom == 0:
        raise RuntimeError("Cannot read Mach timebase; refusing uncalibrated CPU data")
    factor = base.numer / base.denom

    def snap():
        usage = Usage()
        if lib.proc_pid_rusage(args.pid, 2, ctypes.byref(usage)) != 0:
            raise OSError(ctypes.get_errno(), "Process counters unavailable")
        return time.monotonic(), usage

    start, first = snap()
    previous_time, previous = start, first
    peak_cpu = 0
    print(json.dumps({"event": "start", "pid": args.pid, "tick_to_ns": factor,
                      "cumulative_cpu_seconds": (first.user_time + first.system_time) * factor / 1e9}), flush=True)
    for elapsed_target in list(range(10, args.seconds, 10)) + [args.seconds]:
        time.sleep(max(0, start + elapsed_target - time.monotonic()))
        now, current = snap()
        cpu = ((current.user_time - previous.user_time) +
               (current.system_time - previous.system_time)) * factor / 1e9 / (now - previous_time) * 100
        peak_cpu = max(cpu, peak_cpu)
        print(json.dumps({"elapsed_s": round(now - start, 2), "cpu_percent": round(cpu, 4),
                          "footprint_MiB": round(current.footprint / 1048576, 2),
                          "idle_wakeups": current.idle_wakeups - previous.idle_wakeups,
                          "interrupt_wakeups": current.interrupt_wakeups - previous.interrupt_wakeups,
                          "write_bytes": current.write_bytes - previous.write_bytes}), flush=True)
        previous_time, previous = now, current
    print(json.dumps({"event": "complete", "elapsed_s": round(now - start, 2),
                      "average_cpu_percent": round(((current.user_time - first.user_time) +
                          (current.system_time - first.system_time)) * factor / 1e9 / (now - start) * 100, 4),
                      "highest_interval_cpu_percent": round(peak_cpu, 4),
                      "idle_wakeups_total": current.idle_wakeups - first.idle_wakeups,
                      "read_bytes_total": current.read_bytes - first.read_bytes,
                      "write_bytes_total": current.write_bytes - first.write_bytes}), flush=True)


if __name__ == "__main__":
    main()
