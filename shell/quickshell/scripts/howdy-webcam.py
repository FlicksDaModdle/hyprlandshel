#!/usr/bin/env python3
"""The webcam half of face unlock: its pictures of you, and Howdy's rule.

Run as root by scripts/howdy-setup.sh, never by itself:

  howdy-webcam.py enrol  HOWDY_DIR USER LABEL STILLS_DIR
      webcam pictures of USER, taken while the face labelled LABEL was
      added, kept beside Howdy's own models as USER.webcam.json, tied to
      the Howdy model just added (its id)
  howdy-webcam.py forget HOWDY_DIR USER ID     the pictures for one model
  howdy-webcam.py clear  HOWDY_DIR USER        all of them
  howdy-webcam.py rule   CONFIG on DEVICE | off
      the hyprshell_webcam rule in Howdy's config.ini (and rubberstamps on
      or off with it), leaving any other rules as they are

The pictures are kept as Howdy keeps its own: face descriptors, not
images, readable like Howdy's models are (the lock screen checks them as
you, not as root).
"""
import glob
import json
import os
import re
import sys
import time

MIN_LIGHT = 45
# In Howdy's config, while the webcam check is on.
MARKER = "# hyprshell-webcam: rubberstamps were off before the webcam check"
PARKED = "hyprshell-webcam set aside:"


def models_path(howdy_dir, user):
    sys.path.insert(0, howdy_dir)
    import paths_factory
    return str(paths_factory.user_models_dir_path()), paths_factory


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def save(path, looks):
    if not looks:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    tmp = path + ".new"
    with open(tmp, "w") as f:
        json.dump(looks, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def enrol(howdy_dir, user, label, stills):
    folder, paths_factory = models_path(howdy_dir, user)
    import cv2
    import dlib
    import numpy as np

    # The Howdy model this goes with: the one just added, the highest id.
    models = load(os.path.join(folder, user + ".dat"))
    if not models:
        print("webcam: Howdy has no model for you to go with")
        return 1
    howdy_id = max(m["id"] for m in models)

    detector = dlib.get_frontal_face_detector()
    predictor = dlib.shape_predictor(paths_factory.shape_predictor_5_face_landmarks_path())
    encoder = dlib.face_recognition_model_v1(paths_factory.dlib_face_recognition_resnet_model_v1_path())

    encodings, dark, faceless = [], 0, 0
    for still in sorted(glob.glob(os.path.join(stills, "*.jpg"))):
        frame = cv2.imread(still)
        if frame is None:
            continue
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        if gray.mean() < MIN_LIGHT:
            dark += 1
            continue
        faces = detector(gray, 1)
        if len(faces) != 1:
            faceless += 1
            continue
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        shape = predictor(rgb, faces[0])
        encodings.append(list(encoder.compute_face_descriptor(rgb, shape, 1)))

    if not encodings:
        why = ("too dark" if dark >= faceless else "not one face in each, alone") if dark or faceless \
            else "none were taken"
        print("webcam: no usable webcam pictures (%s): the infrared camera decides alone for this look" % why)
        return 0

    path = os.path.join(folder, user + ".webcam.json")
    looks = [look for look in load(path) if look.get("howdy_id") != howdy_id]
    looks.append({"howdy_id": howdy_id, "label": label, "time": int(time.time()), "data": encodings})
    save(path, looks)
    print("webcam: %d webcam picture%s kept" % (len(encodings), "" if len(encodings) == 1 else "s"))
    return 0


def forget(howdy_dir, user, model_id):
    folder, _ = models_path(howdy_dir, user)
    path = os.path.join(folder, user + ".webcam.json")
    save(path, [look for look in load(path) if look.get("howdy_id") != int(model_id)])
    return 0


def clear(howdy_dir, user):
    folder, _ = models_path(howdy_dir, user)
    save(os.path.join(folder, user + ".webcam.json"), [])
    return 0


def rule(config, state, device=""):
    """Rewrite [rubberstamps] in place: enabled, and stamp_rules with
    ours added or taken out. Comments and the other sections are left as
    they are; only these two keys' lines are touched."""
    with open(config) as f:
        lines = f.read().split("\n")

    start = next((i for i, l in enumerate(lines) if l.strip() == "[rubberstamps]"), None)
    if start is None:
        lines += ["", "[rubberstamps]", "enabled = false", "stamp_rules ="]
        start = len(lines) - 3
    end = next((i for i in range(start + 1, len(lines)) if lines[i].strip().startswith("[")), len(lines))
    section = lines[start + 1:end]
    # Ours from a previous run, read and taken out before anything is
    # located, so positions are of what's left.
    parked = [l.split(PARKED, 1)[1].strip() for l in section if PARKED in l]
    marker = any(MARKER in l for l in section)
    section = [l for l in section if PARKED not in l and MARKER not in l]

    # stamp_rules and its continuation lines (indented, or blank-free
    # lines that start with whitespace).
    rules, at = [], None
    i = 0
    while i < len(section):
        if re.match(r"^\s*stamp_rules\s*=", section[i]):
            at = i
            first = section[i].split("=", 1)[1].strip()
            if first:
                rules.append(first)
            j = i + 1
            while j < len(section) and section[j][:1] in (" ", "\t") and section[j].strip():
                rules.append(section[j].strip())
                j += 1
            del section[i:j]
            break
        i += 1
    rules = [r for r in rules if not r.startswith("hyprshell_webcam")]
    was_enabled = any(re.match(r"^\s*enabled\s*=\s*true", l) for l in section)
    # Rules that were there while rubberstamps were off (Howdy's own nod,
    # say) aren't switched on with ours: they're set aside in comments, and
    # put back when ours goes.
    if state == "on":
        if not was_enabled and not marker:
            parked, rules, marker = parked + rules, [], True
        rules.append("hyprshell_webcam 4s failsafe device=%s min_light=%d certainty=4.5" % (device, MIN_LIGHT))
        enabled = True
    else:
        rules += parked
        parked = []
        enabled = False if marker else (was_enabled and bool(rules))
        marker = False
    block = ([MARKER] if marker else []) + ["# " + PARKED + " " + r for r in parked]
    block += ["stamp_rules ="] + ["\t" + r for r in rules]
    if at is None:
        at = len(section)
    section[at:at] = block

    found = False
    for k, l in enumerate(section):
        if re.match(r"^\s*enabled\s*=", l):
            section[k] = "enabled = " + ("true" if enabled else "false")
            found = True
    if not found:
        section.insert(0, "enabled = " + ("true" if enabled else "false"))

    lines[start + 1:end] = section
    tmp = config + ".new"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.chmod(tmp, os.stat(config).st_mode & 0o777)
    os.replace(tmp, config)
    return 0


def main(argv):
    if len(argv) >= 5 and argv[0] == "enrol":
        return enrol(argv[1], argv[2], argv[3], argv[4])
    if len(argv) == 4 and argv[0] == "forget":
        return forget(argv[1], argv[2], argv[3])
    if len(argv) == 3 and argv[0] == "clear":
        return clear(argv[1], argv[2])
    if len(argv) >= 3 and argv[0] == "rule":
        return rule(argv[1], argv[2], argv[3] if len(argv) > 3 else "")
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
