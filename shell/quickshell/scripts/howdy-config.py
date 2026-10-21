#!/usr/bin/env python3
"""Change Howdy's settings, from Settings -> Login screen -> Howdy.

Run as root by scripts/howdy-setup.sh (--set), never by itself:

  howdy-config.py CONFIG section.key=value ...

Only the settings listed in SCHEMA, each checked against its type and
range before anything is written; one bad value and nothing is. The
file is edited in place, line by line: comments, order and every other
setting stay as they are. "webcam.*" are the options of the webcam
check's rule (scripts/hyprshell_webcam.py) in [rubberstamps].
"""
import os
import re
import sys

# section.key: (kind, *limits)
#   bool                     true / false
#   float lo hi, int lo hi   within the range, both ends included
#   enum a b c               one of these
SCHEMA = {
    "core.detection_notice": ("bool",),
    "core.timeout_notice": ("bool",),
    "core.no_confirmation": ("bool",),
    "core.suppress_unknown": ("bool",),
    "core.abort_if_ssh": ("bool",),
    "core.abort_if_lid_closed": ("bool",),
    "core.disabled": ("bool",),
    "core.use_cnn": ("bool",),
    "core.workaround": ("enum", "off", "input", "native"),
    "video.certainty": ("float", 1.0, 6.0),
    "video.timeout": ("int", 1, 20),
    "video.dark_threshold": ("int", 0, 100),
    "video.max_height": ("int", 120, 1080),
    "video.recording_plugin": ("enum", "opencv", "ffmpeg", "pyv4l2"),
    "video.force_mjpeg": ("bool",),
    "video.device_fps": ("int", -1, 120),
    "video.exposure": ("int", -1, 10000),
    "video.rotate": ("enum", "0", "1", "2"),
    "snapshots.save_failed": ("bool",),
    "snapshots.save_successful": ("bool",),
    "debug.end_report": ("bool",),
    "debug.verbose_stamps": ("bool",),
    "webcam.certainty": ("float", 2.0, 6.0),
    "webcam.min_light": ("int", 5, 150),
}


def check(name, value):
    if name not in SCHEMA:
        raise ValueError("not a setting that can be changed here: " + name)
    kind, *limits = SCHEMA[name]
    if kind == "bool":
        if value not in ("true", "false"):
            raise ValueError("%s: true or false, not %r" % (name, value))
        return value
    if kind == "enum":
        if value not in limits:
            raise ValueError("%s: one of %s, not %r" % (name, ", ".join(limits), value))
        return value
    number = float(value) if kind == "float" else int(value)
    if not limits[0] <= number <= limits[1]:
        raise ValueError("%s: between %s and %s, not %s" % (name, limits[0], limits[1], value))
    return ("%.1f" % number) if kind == "float" else str(number)


def apply(lines, section, key, value):
    """Set key in [section]: its line rewritten, or added at the end of the
    section if it isn't there."""
    start = next((i for i, l in enumerate(lines) if l.strip() == "[%s]" % section), None)
    if start is None:
        lines += ["", "[%s]" % section, "%s = %s" % (key, value)]
        return
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))
    pattern = re.compile(r"^\s*%s\s*=" % re.escape(key))
    for i in range(start + 1, end):
        if pattern.match(lines[i]):
            lines[i] = "%s = %s" % (key, value)
            return
    # After the section's last non-blank line.
    at = end
    while at > start + 1 and not lines[at - 1].strip():
        at -= 1
    lines.insert(at, "%s = %s" % (key, value))


def apply_webcam(lines, key, value):
    """An option of the webcam check's rule, in [rubberstamps]."""
    for i, l in enumerate(lines):
        if l.strip().startswith("hyprshell_webcam"):
            if re.search(r"\b%s=\S*" % key, l):
                lines[i] = re.sub(r"\b%s=\S*" % key, "%s=%s" % (key, value), l)
            else:
                lines[i] = l.rstrip() + " %s=%s" % (key, value)
            return
    raise ValueError("the webcam check isn't on")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    config = argv[0]
    changes = []
    try:
        for arg in argv[1:]:
            name, sep, value = arg.partition("=")
            if not sep:
                raise ValueError("section.key=value, not %r" % arg)
            changes.append((name, check(name, value.strip())))
        with open(config) as f:
            lines = f.read().split("\n")
        for name, value in changes:
            section, key = name.split(".", 1)
            if section == "webcam":
                apply_webcam(lines, key, value)
            else:
                apply(lines, section, key, value)
    except (ValueError, OSError) as error:
        print("howdy-config: %s" % error, file=sys.stderr)
        return 1
    tmp = config + ".new"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.chmod(tmp, os.stat(config).st_mode & 0o777)
    os.replace(tmp, config)
    print("changed: " + ", ".join(name for name, _ in changes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
