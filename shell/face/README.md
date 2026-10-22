# Face unlock service

Face unlock without Howdy's startup cost: a small Rust service,
`hyprshell-faced`, keeps two face models loaded and opens the cameras only
when the lock screen, the login screen or `sudo` asks. Howdy stays
installed as its fallback.

```
sudo ./install.sh            build, install, start; ask it first at the lock and login screens
./install.sh --status        what's installed and running
sudo ./install.sh --uninstall
```

Then add your face again in **Settings → Login screen**: the service keeps
its own faces (Howdy's stay, for the fallback).

## How it works

* **hyprshell-faced**, a systemd service, loads the models at boot:
  [YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet)
  (MIT) finds faces and five points on each, and
  [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)
  (Apache-2.0) turns a face, lined up by those points, into 128 numbers.
  They run with [tract](https://github.com/sonos/tract), in Rust, with
  nothing to install. The installer downloads them and checks their SHA-256.
* The infrared camera is read directly (V4L2). A frame too dark to use
  (the emitter flashes) is skipped. Your face has to be close enough to one
  you added (cosine similarity, `threshold`).
* With the **webcam check** on, the webcam is opened at the same moment,
  and it has to recognise you too, against pictures taken while you were
  added. If it's too dark for the webcam, or another app has it, the
  infrared camera decides alone.
* **pam_hyprshell_face.so** asks the service over
  `/run/hyprshell-face/socket` and answers *you*, *not you*, or
  *unavailable*. On *unavailable* (the service isn't running, or you've no
  face added to it), PAM moves on to Howdy:

  ```
  auth [success=done authinfo_unavail=ignore default=die] pam_hyprshell_face.so
  auth required pam_howdy.so
  ```

  `shell/quickshell/scripts/howdy-setup.sh` writes these lines, for the lock
  screen (`/etc/pam.d/hyprshell-lock`) and greetd.

## Who can ask what

The socket says who's asking (`SO_PEERCRED`):

* **Checking a face**: yourself only (the lock screen runs as you), or root
  (greetd, sudo) for anyone.
* **Listing and removing** looks: your own, or root for anyone's.
* **Adding a face**: root only. That's Settings' helper, behind your
  password, so a program running as you can't add another person's face.

Faces are kept as numbers, not pictures, in `/var/lib/hyprshell-face/`,
readable by root alone. The service runs with systemd's sandboxing: no
network, no capabilities, no devices but cameras.

## Settings

`/etc/hyprshell-face.conf`, changed from Settings or with
`sudo hyprshell-face set key=value`, read at each unlock:

| key | default | |
|---|---|---|
| `ir_device` | | the infrared camera |
| `webcam_device` | | the webcam, for the webcam check |
| `webcam_check` | `false` | the webcam has to recognise you too |
| `threshold` | `0.45` | how alike the infrared face has to be (0.2 to 0.9) |
| `webcam_threshold` | `0.40` | the same for the webcam |
| `timeout` | `4` | seconds before giving up |
| `min_light` | `45` | darker webcam frames don't count (0-255) |
| `dark_frame` | `8` | darker infrared frames are skipped |
| `detect_score` | `0.8` | how sure it has to be that there's a face |

## Trying it

```
hyprshell-face verify          look for you now, as the lock screen does
hyprshell-face list            your looks
journalctl -u hyprshell-faced  each try, with how long it took and how alike
```
