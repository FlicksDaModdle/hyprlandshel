package main

// The window talks to the daemon over a Unix socket in $XDG_RUNTIME_DIR,
// one JSON object per line. Requests carry an "id" and get a reply with the
// same "re"; everything else the daemon sends is an event ("ev"), to every
// window connected.
//
//   hello                      → state
//   pair      {phone?}         start linking: QR codes, or a code to type on the phone
//   chats                      → {chats}
//   messages  {chat, before?, limit?} → {messages}, oldest first
//   send      {chat, text, quote?}    → {msg}
//   sendFile  {chat, path, caption?, voice?, seconds?, waveform?} → {msg}
//   react     {chat, msg, emoji}      ("" takes a reaction back)
//   revoke    {chat, msg}             delete one of yours for everyone
//   read      {chat}
//   download  {chat, msg}             → {msg} with media.path
//   typing    {chat, on}
//   view      {chat, focused}         what the window is showing, for notifications
//   avatar    {jid}                   → {path}
//   newChat   {phone}                 → {chat}
//   search    {q}                     → {messages}
//   show      {chat?}                 bring the open window forward (on a chat)
//   logout
//
// Events: state, qr {code}, pairCode {code}, chat {chat}, message {msg},
// typing {chat, who, on}, reload, unread {count}, open {chat}.

import (
	"bufio"
	"encoding/json"
	"errors"
	"log"
	"net"
	"os"
	"sync"
)

type Backend interface {
	Start()
	State() map[string]any
	Pair(phone string) error
	SendText(chat, text, quote string) (*Msg, error)
	SendFile(chat, path, caption string, voice bool, seconds int, waveform []int) (*Msg, error)
	React(chat, id, emoji string) error
	Revoke(chat, id string) error
	Read(chat string) error
	Download(chat, id string) (*Msg, error)
	Typing(chat string, on bool)
	Presence(online bool)
	Avatar(jid string) string
	NewChat(phone string) (string, error)
	Logout() error
}

type conn struct {
	c   net.Conn
	out chan []byte
}

type Server struct {
	store   *Store
	be      Backend
	notify  *Notifier
	mu      sync.Mutex
	conns   map[*conn]bool
	viewing string
	focused bool
	unread  int
}

func NewServer(store *Store) *Server {
	return &Server{store: store, conns: map[*conn]bool{}}
}

func (s *Server) Emit(ev map[string]any) {
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	b = append(b, '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.conns {
		select {
		case c.out <- b:
		default:
			// A window that has stopped reading doesn't hold the rest up.
		}
	}
}

func (s *Server) HasWindow() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns) > 0
}

// Viewing: whether the window is open on this chat and has the focus.
func (s *Server) Viewing(chat string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns) > 0 && s.focused && s.viewing == chat
}

func (s *Server) EmitChat(jid string) {
	if c, err := s.store.Chat(jid); err == nil {
		s.Emit(map[string]any{"ev": "chat", "chat": c})
	}
	s.EmitUnread()
}

func (s *Server) EmitUnread() {
	n := s.store.TotalUnread()
	s.mu.Lock()
	changed := n != s.unread
	s.unread = n
	s.mu.Unlock()
	if changed {
		s.Emit(map[string]any{"ev": "unread", "count": n})
		writeUnread(n)
	}
}

func (s *Server) EmitMessage(m *Msg) {
	s.Emit(map[string]any{"ev": "message", "msg": m})
}

func (s *Server) Listen(path string) error {
	// Another daemon already answering: leave it be.
	if c, err := net.Dial("unix", path); err == nil {
		c.Close()
		return errAlreadyRunning
	}
	_ = os.Remove(path)
	old := umask(0o077)
	l, err := net.Listen("unix", path)
	umask(old)
	if err != nil {
		return err
	}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				log.Printf("accept: %v", err)
				return
			}
			go s.serve(c)
		}
	}()
	return nil
}

var errAlreadyRunning = errors.New("already running")

func (s *Server) serve(nc net.Conn) {
	c := &conn{c: nc, out: make(chan []byte, 512)}
	s.mu.Lock()
	s.conns[c] = true
	s.mu.Unlock()
	done := make(chan struct{})
	go func() {
		for {
			select {
			case b := <-c.out:
				if _, err := nc.Write(b); err != nil {
					nc.Close()
					return
				}
			case <-done:
				return
			}
		}
	}()
	defer func() {
		s.mu.Lock()
		delete(s.conns, c)
		last := len(s.conns) == 0
		s.mu.Unlock()
		close(done)
		nc.Close()
		// No window left: not online any more, as far as contacts can see.
		if last {
			s.be.Presence(false)
		}
	}()
	sc := bufio.NewScanner(nc)
	sc.Buffer(make([]byte, 64<<10), 8<<20)
	for sc.Scan() {
		var req map[string]any
		if err := json.Unmarshal(sc.Bytes(), &req); err != nil {
			continue
		}
		reply := s.handle(req)
		if id, ok := req["id"]; ok {
			if reply == nil {
				reply = map[string]any{}
			}
			reply["re"] = id
			if _, has := reply["ok"]; !has {
				reply["ok"] = true
			}
			b, _ := json.Marshal(reply)
			select {
			case c.out <- append(b, '\n'):
			case <-done:
				return
			}
		}
	}
}

func str(m map[string]any, k string) string {
	v, _ := m[k].(string)
	return v
}
func num(m map[string]any, k string) int64 {
	v, _ := m[k].(float64)
	return int64(v)
}
func boolean(m map[string]any, k string) bool {
	v, _ := m[k].(bool)
	return v
}
func fail(err error) map[string]any {
	return map[string]any{"ok": false, "error": err.Error()}
}

func (s *Server) handle(r map[string]any) map[string]any {
	switch str(r, "cmd") {
	case "hello":
		st := s.be.State()
		st["unread"] = s.store.TotalUnread()
		s.mu.Lock()
		st["windows"] = len(s.conns)
		s.mu.Unlock()
		return st
	case "show":
		// A second window starting: the first one comes forward instead.
		s.Emit(map[string]any{"ev": "open", "chat": str(r, "chat")})
	case "pair":
		if err := s.be.Pair(str(r, "phone")); err != nil {
			return fail(err)
		}
	case "chats":
		cs, err := s.store.Chats()
		if err != nil {
			return fail(err)
		}
		if cs == nil {
			cs = []*Chat{}
		}
		return map[string]any{"chats": cs}
	case "messages":
		limit := int(num(r, "limit"))
		if limit <= 0 || limit > 500 {
			limit = 60
		}
		ms, err := s.store.Messages(str(r, "chat"), num(r, "before"), limit)
		if err != nil {
			return fail(err)
		}
		if ms == nil {
			ms = []*Msg{}
		}
		return map[string]any{"messages": ms}
	case "send":
		m, err := s.be.SendText(str(r, "chat"), str(r, "text"), str(r, "quote"))
		if err != nil {
			return fail(err)
		}
		return map[string]any{"msg": m}
	case "sendFile":
		var wave []int
		if a, ok := r["waveform"].([]any); ok {
			for _, v := range a {
				f, _ := v.(float64)
				wave = append(wave, int(f))
			}
		}
		m, err := s.be.SendFile(str(r, "chat"), str(r, "path"), str(r, "caption"), boolean(r, "voice"), int(num(r, "seconds")), wave)
		if err != nil {
			return fail(err)
		}
		return map[string]any{"msg": m}
	case "react":
		if err := s.be.React(str(r, "chat"), str(r, "msg"), str(r, "emoji")); err != nil {
			return fail(err)
		}
	case "revoke":
		if err := s.be.Revoke(str(r, "chat"), str(r, "msg")); err != nil {
			return fail(err)
		}
	case "read":
		if err := s.be.Read(str(r, "chat")); err != nil {
			return fail(err)
		}
	case "download":
		m, err := s.be.Download(str(r, "chat"), str(r, "msg"))
		if err != nil {
			return fail(err)
		}
		return map[string]any{"msg": m}
	case "typing":
		s.be.Typing(str(r, "chat"), boolean(r, "on"))
	case "view":
		s.mu.Lock()
		s.viewing, s.focused = str(r, "chat"), boolean(r, "focused")
		focused := s.focused
		s.mu.Unlock()
		s.be.Presence(focused)
		if s.notify != nil && s.viewing != "" && focused {
			s.notify.Clear(s.viewing)
		}
	case "avatar":
		return map[string]any{"path": s.be.Avatar(str(r, "jid"))}
	case "newChat":
		jid, err := s.be.NewChat(str(r, "phone"))
		if err != nil {
			return fail(err)
		}
		return map[string]any{"chat": jid}
	case "search":
		ms, err := s.store.Search(str(r, "q"), 60)
		if err != nil {
			return fail(err)
		}
		if ms == nil {
			ms = []*Msg{}
		}
		return map[string]any{"messages": ms}
	case "logout":
		if err := s.be.Logout(); err != nil {
			return fail(err)
		}
	default:
		return map[string]any{"ok": false, "error": "unknown command"}
	}
	return nil
}
