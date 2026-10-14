package main

// --demo: made-up chats that behave like real ones (your messages are
// sent, delivered and read; people type and answer back), with no WhatsApp
// account involved. For trying the window out, and for its tests.
// HYPRSHELL_CHATS_DEMO=pair starts at the linking screen instead.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type Demo struct {
	srv   *Server
	store *Store
	dir   string
	mu    sync.Mutex
	state string
	n     int
	reply int
}

const demoMe = "10000000000@s.whatsapp.net"

func NewDemo(srv *Server, st *Store, dir string) *Demo {
	return &Demo{srv: srv, store: st, dir: dir}
}

func (d *Demo) setState(s, errText string) {
	d.mu.Lock()
	d.state = s
	d.mu.Unlock()
	ev := d.State()
	ev["ev"] = "state"
	ev["error"] = errText
	d.srv.Emit(ev)
}

func (d *Demo) State() map[string]any {
	d.mu.Lock()
	defer d.mu.Unlock()
	return map[string]any{"state": d.state, "error": "", "demo": true, "me": demoMe, "name": "You"}
}

func (d *Demo) Start() {
	if os.Getenv("HYPRSHELL_CHATS_DEMO") == "pair" {
		d.setState("pairing", "")
		return
	}
	d.fill()
	d.setState("online", "")
}

func (d *Demo) Pair(phone string) error {
	if phone != "" {
		go func() {
			time.Sleep(700 * time.Millisecond)
			d.srv.Emit(map[string]any{"ev": "pairCode", "code": "HYPR-SHEL"})
		}()
	}
	go func() {
		d.srv.Emit(map[string]any{"ev": "qr", "code": "2@demo-not-a-real-code,hyprshell-chats-demo,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==", "timeout": 60})
		if os.Getenv("HYPRSHELL_CHATS_DEMO_STAY") != "" {
			return
		}
		time.Sleep(8 * time.Second)
		d.setState("connecting", "")
		time.Sleep(1500 * time.Millisecond)
		d.fill()
		d.setState("online", "")
		d.srv.Emit(map[string]any{"ev": "reload"})
	}()
	return nil
}

// ── the made-up world ────────────────────────────────────────────────────

type demoPerson struct{ jid, name string }

var (
	alex   = demoPerson{"15550100001@s.whatsapp.net", "Alex Rivera"}
	jordan = demoPerson{"15550100002@s.whatsapp.net", "Jordan Lee"}
	priya  = demoPerson{"15550100003@s.whatsapp.net", "Priya Shah"}
	mum    = demoPerson{"15550100004@s.whatsapp.net", "Mum"}
	sam    = demoPerson{"15550100005@s.whatsapp.net", "Sam"}
	noor   = demoPerson{"15550100006@s.whatsapp.net", "Noor"}
)

func (d *Demo) id() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.n++
	return fmt.Sprintf("DEMO%06d", d.n)
}

func (d *Demo) put(chat string, isGroup bool, name string, from *demoPerson, ago time.Duration, kind, text string, mod func(*Msg)) *Msg {
	d.store.EnsureChat(chat, isGroup)
	d.store.SetChatName(chat, name)
	m := &Msg{Chat: chat, ID: d.id(), Ts: time.Now().Add(-ago).UnixMilli(), Kind: kind, Text: text, Status: StatusRead}
	if from == nil {
		m.FromMe, m.Sender = true, demoMe
	} else {
		m.Sender, m.SenderName, m.Status = from.jid, from.name, StatusSent
	}
	if mod != nil {
		mod(m)
	}
	_, _ = d.store.PutMessage(m)
	d.store.Touch(m, previewOf(m.Kind, m.Text, m.Media), m.Kind)
	return m
}

func (d *Demo) fill() {
	if cs, _ := d.store.Chats(); len(cs) > 0 {
		return
	}
	h, m := time.Hour, time.Minute
	day := 24 * h

	a := alex.jid
	d.put(a, false, alex.name, &alex, 2*day+3*h, "text", "Did you get the tickets sorted?", nil)
	d.put(a, false, alex.name, nil, 2*day+2*h, "text", "Yes! Row F, right in the middle", nil)
	photo := d.put(a, false, alex.name, &alex, 5*h, "image", "The view from the hut this morning", func(x *Msg) {
		x.Media = &Media{Mime: "image/jpeg", Width: 1200, Height: 800, Path: d.picture("hut", 1200, 800, 0.08)}
	})
	d.put(a, false, alex.name, nil, 4*h+50*m, "text", "That's unreal. Was it cold?", func(x *Msg) {
		x.Quote = &Quote{ID: photo.ID, Sender: alex.jid, SenderName: alex.name, Kind: "image", Text: "The view from the hut this morning"}
	})
	d.put(a, false, alex.name, &alex, 4*h+40*m, "text", "Freezing. Worth it though", func(x *Msg) {
		x.Reactions = []Reaction{{Emoji: "❤️", Sender: demoMe, FromMe: true}}
	})
	d.put(a, false, alex.name, &alex, 25*m, "voice", "", func(x *Msg) {
		x.Media = &Media{Mime: "audio/wav", Seconds: 7, Path: d.tone("hello", 7), Waveform: wave(64, 3)}
	})
	d.put(a, false, alex.name, &alex, 24*m, "text", "Are we still on for 8 tonight? I can pick you up on the way", nil)
	d.store.SetUnread(a, 2)
	d.store.SetAvatar(a, d.picture("avatar-alex", 160, 160, 0.55), "demo")

	f := "120363000000000001@g.us"
	d.put(f, true, "Family", &mum, 3*h, "text", "Sunday lunch at ours, 1pm. Bring the dog", nil)
	d.put(f, true, "Family", &sam, 2*h+55*m, "text", "Can't wait 🎉", nil)
	d.put(f, true, "Family", nil, 2*h+30*m, "text", "We'll be there. Need us to bring anything?", func(x *Msg) {
		x.Reactions = []Reaction{{Emoji: "👍", Sender: mum.jid}, {Emoji: "👍", Sender: sam.jid}}
	})
	d.put(f, true, "Family", &mum, 1*h, "document", "", func(x *Msg) {
		x.Media = &Media{Mime: "application/pdf", Size: 482113, Name: "Recipe — Gran's apple cake.pdf"}
	})
	d.put(f, true, "Family", &sam, 12*m, "text", "Gran's cake!! 🍰", nil)
	d.store.SetUnread(f, 3)
	d.store.SetFlag(f, "pinned", 1)

	j := jordan.jid
	d.put(j, false, jordan.name, nil, 6*day, "text", "Thanks for yesterday, that was a lot of fun", nil)
	d.put(j, false, jordan.name, &jordan, 6*day-20*m, "text", "Any time. Same again next month?", nil)
	d.put(j, false, jordan.name, nil, 9*h, "text", "Sending the photos over now", func(x *Msg) { x.Status = StatusDelivered })

	w := "120363000000000002@g.us"
	d.put(w, true, "Design team", &priya, day+2*h, "text", "New mockups are in the shared folder", nil)
	d.put(w, true, "Design team", &noor, day+h, "image", "", func(x *Msg) {
		x.Media = &Media{Mime: "image/jpeg", Width: 900, Height: 1200, Path: d.picture("mockup", 900, 1200, 0.72)}
	})
	d.put(w, true, "Design team", nil, day+50*m, "text", "These look great. The spacing on the cards especially", nil)
	d.store.SetFlag(w, "muted_until", 1<<60)

	p := priya.jid
	d.put(p, false, priya.name, &priya, 3*day, "text", "Happy birthday!! Hope it's a good one", nil)
	d.put(p, false, priya.name, nil, 3*day-h, "text", "Thank you 😊", nil)
}

// A soft picture (gradient and sun), for made-up photos.
func (d *Demo) picture(name string, w, h int, hue float64) string {
	p := filepath.Join(d.dir, "media", name+".jpg")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o700)
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		t := float64(y) / float64(h)
		for x := 0; x < w; x++ {
			s := float64(x) / float64(w)
			r, g, b := hsv(math.Mod(hue+0.12*t+0.04*s, 1), 0.45+0.2*t, 0.95-0.45*t)
			dx, dy := s-0.7, t-0.35
			if glow := 0.06 - (dx*dx + dy*dy); glow > 0 {
				k := math.Min(1, glow*40)
				r, g, b = r+(1-r)*k, g+(1-g)*k, b+(0.9-b)*k
			}
			img.Set(x, y, color.RGBA{uint8(r * 255), uint8(g * 255), uint8(b * 255), 255})
		}
	}
	f, err := os.Create(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	_ = jpeg.Encode(f, img, &jpeg.Options{Quality: 85})
	return p
}

func hsv(h, s, v float64) (float64, float64, float64) {
	i := math.Floor(h * 6)
	f := h*6 - i
	p, q, t := v*(1-s), v*(1-f*s), v*(1-(1-f)*s)
	switch int(i) % 6 {
	case 0:
		return v, t, p
	case 1:
		return q, v, p
	case 2:
		return p, v, t
	case 3:
		return p, q, v
	case 4:
		return t, p, v
	}
	return v, p, q
}

// A few seconds of something like speech, as WAV, for a made-up voice
// message.
func (d *Demo) tone(name string, seconds int) string {
	p := filepath.Join(d.dir, "media", name+".wav")
	if _, err := os.Stat(p); err == nil {
		return p
	}
	_ = os.MkdirAll(filepath.Dir(p), 0o700)
	rate := 16000
	n := rate * seconds
	buf := make([]byte, 44+n*2)
	copy(buf, "RIFF")
	binary.LittleEndian.PutUint32(buf[4:], uint32(36+n*2))
	copy(buf[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(buf[16:], 16)
	binary.LittleEndian.PutUint16(buf[20:], 1)
	binary.LittleEndian.PutUint16(buf[22:], 1)
	binary.LittleEndian.PutUint32(buf[24:], uint32(rate))
	binary.LittleEndian.PutUint32(buf[28:], uint32(rate*2))
	binary.LittleEndian.PutUint16(buf[32:], 2)
	binary.LittleEndian.PutUint16(buf[34:], 16)
	copy(buf[36:], "data")
	binary.LittleEndian.PutUint32(buf[40:], uint32(n*2))
	for i := 0; i < n; i++ {
		t := float64(i) / float64(rate)
		env := math.Max(0, math.Sin(t*math.Pi*2.3)) * 0.5
		v := env * (math.Sin(2*math.Pi*180*t) + 0.4*math.Sin(2*math.Pi*360*t+math.Sin(t*7)))
		binary.LittleEndian.PutUint16(buf[44+i*2:], uint16(int16(v*9000)))
	}
	_ = os.WriteFile(p, buf, 0o600)
	return p
}

func wave(n int, seed float64) []int {
	out := make([]int, n)
	for i := range out {
		x := float64(i)
		out[i] = int(20 + 70*math.Abs(math.Sin(x*0.37+seed)*math.Sin(x*0.11)))
	}
	return out
}

// ── doing things ─────────────────────────────────────────────────────────

func (d *Demo) send(m *Msg) {
	m.FromMe, m.Sender, m.Status, m.Ts = true, demoMe, StatusPending, time.Now().UnixMilli()
	_, _ = d.store.PutMessage(m)
	d.store.Touch(m, previewOf(m.Kind, m.Text, m.Media), m.Kind)
	d.store.SetUnread(m.Chat, 0)
	d.srv.EmitMessage(m)
	d.srv.EmitChat(m.Chat)
	go func() {
		for _, step := range []struct {
			after  time.Duration
			status int
		}{{500 * time.Millisecond, StatusSent}, {900 * time.Millisecond, StatusDelivered}, {1800 * time.Millisecond, StatusRead}} {
			time.Sleep(step.after)
			if got, err := d.store.SetStatus(m.Chat, m.ID, step.status); err == nil {
				d.srv.EmitMessage(got)
				d.srv.EmitChat(m.Chat)
			}
		}
		d.answer(m.Chat)
	}()
}

var answers = []string{
	"Sounds good 👍", "Ha, love it", "Give me five minutes", "Oh nice, tell me more",
	"Sure, let's do that", "I'll check and get back to you", "Perfect, see you then",
}

// Someone types for a moment and answers back.
func (d *Demo) answer(chat string) {
	c, err := d.store.Chat(chat)
	if err != nil || c.IsGroup {
		return
	}
	d.srv.Emit(map[string]any{"ev": "typing", "chat": chat, "on": true})
	time.Sleep(2200 * time.Millisecond)
	d.srv.Emit(map[string]any{"ev": "typing", "chat": chat, "on": false})
	d.mu.Lock()
	text := answers[d.reply%len(answers)]
	d.reply++
	d.mu.Unlock()
	m := &Msg{Chat: chat, ID: d.id(), Sender: chat, SenderName: c.Name, Ts: time.Now().UnixMilli(), Kind: "text", Text: text, Status: StatusSent}
	_, _ = d.store.PutMessage(m)
	d.store.Touch(m, text, "text")
	if !d.srv.Viewing(chat) {
		d.store.AddUnread(chat, 1)
		if ch, err := d.store.Chat(chat); err == nil {
			d.srv.notify.Message(ch, m)
		}
	}
	d.srv.EmitMessage(m)
	d.srv.EmitChat(chat)
}

func (d *Demo) SendText(chat, text, quote string) (*Msg, error) {
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("nothing to send")
	}
	m := &Msg{Chat: chat, ID: d.id(), Kind: "text", Text: text}
	if quote != "" {
		if q, err := d.store.Message(chat, quote); err == nil {
			m.Quote = &Quote{ID: q.ID, Sender: q.Sender, SenderName: q.SenderName, FromMe: q.FromMe, Kind: q.Kind, Text: previewOf(q.Kind, q.Text, q.Media)}
		}
	}
	d.send(m)
	return m, nil
}

func (d *Demo) SendFile(chat, path, caption string, voice bool, seconds int, waveform []int) (*Msg, error) {
	fi, err := os.Stat(path)
	if err != nil || fi.IsDir() {
		return nil, errors.New("that file can't be read")
	}
	kind := "document"
	ext := strings.ToLower(filepath.Ext(path))
	switch {
	case voice:
		kind = "voice"
	case ext == ".jpg" || ext == ".jpeg" || ext == ".png":
		kind = "image"
	case ext == ".mp4":
		kind = "video"
	}
	md := &Media{Size: fi.Size(), Name: filepath.Base(path), Path: path, Seconds: seconds, Waveform: waveform}
	if kind == "image" {
		if f, err := os.Open(path); err == nil {
			if cfg, _, err := image.DecodeConfig(f); err == nil {
				md.Width, md.Height = cfg.Width, cfg.Height
			}
			f.Close()
		}
		md.Name = ""
	}
	m := &Msg{Chat: chat, ID: d.id(), Kind: kind, Text: caption, Media: md}
	d.send(m)
	return m, nil
}

func (d *Demo) React(chat, id, emoji string) error {
	m, err := d.store.Message(chat, id)
	if err != nil {
		return err
	}
	var out []Reaction
	for _, r := range m.Reactions {
		if !r.FromMe {
			out = append(out, r)
		}
	}
	if emoji != "" {
		out = append(out, Reaction{Emoji: emoji, Sender: demoMe, FromMe: true})
	}
	m.Reactions = out
	_ = d.store.SetReactions(chat, id, out)
	d.srv.EmitMessage(m)
	return nil
}

func (d *Demo) Revoke(chat, id string) error {
	m, err := d.store.Message(chat, id)
	if err != nil {
		return err
	}
	m.Kind, m.Text, m.Media, m.Quote, m.Reactions = "deleted", "", nil, nil, nil
	_, _ = d.store.PutMessage(m)
	_ = d.store.SetReactions(chat, id, nil)
	d.srv.EmitMessage(m)
	return nil
}

func (d *Demo) Read(chat string) error {
	d.store.SetUnread(chat, 0)
	d.srv.notify.Clear(chat)
	d.srv.EmitChat(chat)
	return nil
}

func (d *Demo) Download(chat, id string) (*Msg, error) {
	m, err := d.store.Message(chat, id)
	if err != nil {
		return nil, err
	}
	if m.Media != nil && m.Media.Path == "" {
		time.Sleep(600 * time.Millisecond)
		p := filepath.Join(d.dir, "media", safeName(m.Media.Name))
		_ = os.WriteFile(p, []byte("%PDF-1.4\n% A made-up document for the demo.\n"), 0o600)
		m.Media.Path = p
		_ = d.store.SetMedia(chat, id, m.Media)
		d.srv.EmitMessage(m)
	}
	return m, nil
}

func (d *Demo) Typing(string, bool) {}
func (d *Demo) Presence(bool)       {}

func (d *Demo) Avatar(jid string) string {
	p, _, _ := d.store.AvatarState(jid)
	return p
}

func (d *Demo) NewChat(phone string) (string, error) {
	digits := regexp.MustCompile(`\D`).ReplaceAllString(phone, "")
	if len(digits) < 7 {
		return "", errors.New("that doesn't look like a phone number; include the country code")
	}
	jid := digits + "@s.whatsapp.net"
	d.store.EnsureChat(jid, false)
	d.store.SetChatName(jid, "+"+digits)
	d.store.Bump(jid)
	d.srv.EmitChat(jid)
	return jid, nil
}

func (d *Demo) Logout() error {
	_ = d.store.Wipe()
	d.setState("pairing", "")
	d.srv.Emit(map[string]any{"ev": "reload"})
	return nil
}
