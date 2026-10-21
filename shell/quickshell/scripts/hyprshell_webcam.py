# Howdy rubberstamp: the webcam has to recognise you too.
#
# Installed into Howdy's rubberstamps folder by scripts/howdy-setup.sh
# (--webcam-check on), and run by Howdy after the infrared camera has
# recognised you. It then looks through the ordinary webcam as well, and
# compares what it sees with the webcam pictures taken while your face was
# added (Settings -> Login screen -> Your face). Both cameras have to know
# you: a picture that fools one of them rarely fools the other, since
# skin, paper and screens look different in infrared and in colour.
#
# In low light the webcam sees too little to say anything, and the
# infrared camera decides alone. Likewise when no webcam pictures were
# taken for you yet, or the webcam can't be opened (another app has it).
#
# Rule, in Howdy's config.ini, [rubberstamps] stamp_rules:
#   hyprshell_webcam 4s failsafe device=/dev/video0 min_light=45 certainty=4.5
#
#   device      the webcam
#   min_light   average brightness (0-255) below which the webcam is
#               "too dark" and infrared decides alone
#   certainty   how close a match has to be, on Howdy's own scale (lower
#               is stricter; Howdy's infrared default is 3.5)
#
# Not recognised within the timeout: the stamp says no (failsafe), and
# your password is asked for.

import json
import os
import sys
import time

import cv2
import dlib
import numpy as np

import paths_factory
from rubberstamps import RubberStamp


class hyprshell_webcam(RubberStamp):
    def declare_config(self):
        self.options["device"] = ""
        self.options["min_light"] = 45
        self.options["certainty"] = 4.5

    def say(self, text):
        print("hyprshell_webcam: " + text)

    def run(self):
        try:
            return self.check()
        except Exception as error:
            # Not a pass: something unexpected is a "no", and the password
            # is asked for.
            self.say("failed: %s" % error)
            return not self.options["failsafe"]

    def check(self):
        user = sys.argv[1] if len(sys.argv) > 1 else ""
        path = os.path.join(str(paths_factory.user_models_dir_path()), user + ".webcam.json")
        try:
            with open(path) as f:
                looks = json.load(f)
        except FileNotFoundError:
            self.say("no webcam pictures for %s yet: infrared decides alone" % user)
            return True
        known = [enc for look in looks for enc in look.get("data", [])]
        if not known:
            self.say("no webcam pictures for %s yet: infrared decides alone" % user)
            return True
        known = np.array(known)

        device = str(self.options["device"])
        if not device:
            self.say("no webcam set: infrared decides alone")
            return True
        capture = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not capture.isOpened():
            self.say("couldn't open %s: infrared decides alone" % device)
            return True
        try:
            # Small and compressed: it shares the USB bus with the infrared
            # camera, which is still open.
            capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
            capture.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
            capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
            return self.look(capture, known)
        finally:
            capture.release()

    def look(self, capture, known):
        detector = dlib.get_frontal_face_detector()
        encoder = dlib.face_recognition_model_v1(paths_factory.dlib_face_recognition_resnet_model_v1_path())
        limit = float(self.options["certainty"]) / 10
        min_light = float(self.options["min_light"])

        start = time.time()
        frames = 0
        brightest = 0.0
        best = 10.0
        while time.time() < start + float(self.options["timeout"]):
            ok, frame = capture.read()
            if not ok or frame is None:
                continue
            frames += 1
            # The first few while the webcam finds its exposure.
            if frames <= 3:
                continue
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            light = float(gray.mean())
            brightest = max(brightest, light)
            if light < min_light:
                # Dark all along, after its exposure had time to settle.
                if frames >= 12 and brightest < min_light:
                    self.say("too dark for the webcam (%.0f): infrared decides alone" % brightest)
                    return True
                continue
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            for rect in detector(gray, 1):
                shape = self.pose_predictor(rgb, rect)
                encoding = np.array(encoder.compute_face_descriptor(rgb, shape, 1))
                distance = float(np.min(np.linalg.norm(known - encoding, axis=1)))
                best = min(best, distance)
                if distance < limit:
                    self.say("the webcam knows you too (%.2f)" % (distance * 10))
                    return True
        self.say("the webcam didn't recognise you (best %.2f of %.1f needed)" % (best * 10, limit * 10))
        return not self.options["failsafe"]
