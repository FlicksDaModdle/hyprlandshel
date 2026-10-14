package main

// The daemon's own record of chats and messages. whatsmeow keeps the
// session (keys, contacts, app state) in its own database; what was said is
// kept here, so the window can show a conversation without asking the phone.

import (
	"database/sql"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

type Media struct {
	Mime     string `json:"mime,omitempty"`
	Size     int64  `json:"size,omitempty"`
	Width    int    `json:"w,omitempty"`
	Height   int    `json:"h,omitempty"`
	Seconds  int    `json:"seconds,omitempty"`
	Name     string `json:"name,omitempty"`
	Thumb    string `json:"thumb,omitempty"`    // a small JPEG on disk
	Path     string `json:"path,omitempty"`     // the file itself, once downloaded
	Waveform []int  `json:"waveform,omitempty"` // voice messages: 64 values, 0..100
	Failed   string `json:"failed,omitempty"`   // why it could not be downloaded
}

type Quote struct {
	ID         string `json:"id"`
	Sender     string `json:"sender,omitempty"`
	SenderName string `json:"senderName,omitempty"`
	FromMe     bool   `json:"fromMe,omitempty"`
	Text       string `json:"text,omitempty"`
	Kind       string `json:"kind,omitempty"`
}

type Reaction struct {
	Emoji  string `json:"emoji"`
	Sender string `json:"sender"`
	FromMe bool   `json:"fromMe,omitempty"`
}

// Status of a message you sent.
const (
	StatusFailed    = -1
	StatusPending   = 0
	StatusSent      = 1
	StatusDelivered = 2
	StatusRead      = 3
	StatusPlayed    = 4
)

type Msg struct {
	Chat       string     `json:"chat"`
	ID         string     `json:"id"`
	Sender     string     `json:"sender"`
	SenderName string     `json:"senderName,omitempty"`
	FromMe     bool       `json:"fromMe"`
	Ts         int64      `json:"ts"` // unix milliseconds
	Kind       string     `json:"kind"`
	Text       string     `json:"text,omitempty"`
	Media      *Media     `json:"media,omitempty"`
	Quote      *Quote     `json:"quote,omitempty"`
	Reactions  []Reaction `json:"reactions,omitempty"`
	Status     int        `json:"status"`
	Edited     bool       `json:"edited,omitempty"`
	Raw        []byte     `json:"-"` // the protobuf, for downloading its media later
}

type Chat struct {
	JID         string `json:"jid"`
	Name        string `json:"name"`
	IsGroup     bool   `json:"isGroup"`
	LastTs      int64  `json:"lastTs"`
	Preview     string `json:"preview"`
	PreviewKind string `json:"previewKind,omitempty"`
	PreviewMe   bool   `json:"previewMe,omitempty"`
	PreviewWho  string `json:"previewWho,omitempty"`
	// The last message's status, when it's yours.
	PreviewStatus int    `json:"previewStatus"`
	Unread        int    `json:"unread"`
	MutedUntil    int64  `json:"mutedUntil,omitempty"`
	Pinned        bool   `json:"pinned,omitempty"`
	Archived      bool   `json:"archived,omitempty"`
	Avatar        string `json:"avatar,omitempty"`
}

type Store struct {
	db *sql.DB
	mu sync.Mutex
}

const schema = `
CREATE TABLE IF NOT EXISTS chats (
	jid TEXT PRIMARY KEY,
	name TEXT NOT NULL DEFAULT '',
	is_group INTEGER NOT NULL DEFAULT 0,
	last_ts INTEGER NOT NULL DEFAULT 0,
	preview TEXT NOT NULL DEFAULT '',
	preview_kind TEXT NOT NULL DEFAULT '',
	preview_me INTEGER NOT NULL DEFAULT 0,
	preview_who TEXT NOT NULL DEFAULT '',
	unread INTEGER NOT NULL DEFAULT 0,
	muted_until INTEGER NOT NULL DEFAULT 0,
	pinned INTEGER NOT NULL DEFAULT 0,
	archived INTEGER NOT NULL DEFAULT 0,
	avatar TEXT NOT NULL DEFAULT '',
	avatar_id TEXT NOT NULL DEFAULT '',
	avatar_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages (
	chat TEXT NOT NULL,
	id TEXT NOT NULL,
	sender TEXT NOT NULL DEFAULT '',
	sender_name TEXT NOT NULL DEFAULT '',
	from_me INTEGER NOT NULL DEFAULT 0,
	ts INTEGER NOT NULL,
	kind TEXT NOT NULL,
	text TEXT NOT NULL DEFAULT '',
	media TEXT NOT NULL DEFAULT '',
	quote TEXT NOT NULL DEFAULT '',
	reactions TEXT NOT NULL DEFAULT '',
	status INTEGER NOT NULL DEFAULT 0,
	edited INTEGER NOT NULL DEFAULT 0,
	raw BLOB,
	PRIMARY KEY (chat, id)
);
CREATE INDEX IF NOT EXISTS messages_by_time ON messages (chat, ts);
`

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?_foreign_keys=on&_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func jsonOf(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case *Media:
		if x == nil {
			return ""
		}
	case *Quote:
		if x == nil {
			return ""
		}
	case []Reaction:
		if len(x) == 0 {
			return ""
		}
	}
	b, _ := json.Marshal(v)
	return string(b)
}

const msgCols = `chat, id, sender, sender_name, from_me, ts, kind, text, media, quote, reactions, status, edited, raw`

func scanMsg(sc interface{ Scan(...any) error }) (*Msg, error) {
	var m Msg
	var media, quote, reactions string
	var fromMe, edited int
	if err := sc.Scan(&m.Chat, &m.ID, &m.Sender, &m.SenderName, &fromMe, &m.Ts, &m.Kind, &m.Text,
		&media, &quote, &reactions, &m.Status, &edited, &m.Raw); err != nil {
		return nil, err
	}
	m.FromMe, m.Edited = fromMe != 0, edited != 0
	if media != "" {
		m.Media = &Media{}
		_ = json.Unmarshal([]byte(media), m.Media)
	}
	if quote != "" {
		m.Quote = &Quote{}
		_ = json.Unmarshal([]byte(quote), m.Quote)
	}
	if reactions != "" {
		_ = json.Unmarshal([]byte(reactions), &m.Reactions)
	}
	return &m, nil
}

// PutMessage stores a message, or replaces the one with its ID. Returns
// whether it was new.
func (s *Store) PutMessage(m *Msg) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	_ = s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE chat = ? AND id = ?`, m.Chat, m.ID).Scan(&n)
	_, err := s.db.Exec(`INSERT INTO messages (`+msgCols+`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (chat, id) DO UPDATE SET sender=excluded.sender, sender_name=excluded.sender_name,
		from_me=excluded.from_me, ts=excluded.ts, kind=excluded.kind, text=excluded.text, media=excluded.media,
		quote=excluded.quote, status=MAX(messages.status, excluded.status), edited=excluded.edited,
		raw=COALESCE(excluded.raw, messages.raw)`,
		m.Chat, m.ID, m.Sender, m.SenderName, b2i(m.FromMe), m.Ts, m.Kind, m.Text, jsonOf(m.Media),
		jsonOf(m.Quote), jsonOf(m.Reactions), m.Status, b2i(m.Edited), m.Raw)
	return n == 0, err
}

func (s *Store) Message(chat, id string) (*Msg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return scanMsg(s.db.QueryRow(`SELECT `+msgCols+` FROM messages WHERE chat = ? AND id = ?`, chat, id))
}

// MessageByID finds a message when only its ID is known (receipts in a
// chat whose address changed, reactions).
func (s *Store) MessageByID(id string) (*Msg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return scanMsg(s.db.QueryRow(`SELECT `+msgCols+` FROM messages WHERE id = ? LIMIT 1`, id))
}

// Messages before `before` (unix ms; 0 for the newest), oldest first.
func (s *Store) Messages(chat string, before int64, limit int) ([]*Msg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if before <= 0 {
		before = 1 << 62
	}
	rows, err := s.db.Query(`SELECT `+msgCols+` FROM messages WHERE chat = ? AND ts < ? ORDER BY ts DESC LIMIT ?`, chat, before, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Msg
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, rows.Err()
}

func (s *Store) Search(q string, limit int) ([]*Msg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(q)
	rows, err := s.db.Query(`SELECT `+msgCols+` FROM messages WHERE text LIKE ? ESCAPE '\' ORDER BY ts DESC LIMIT ?`, "%"+esc+"%", limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Msg
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// UnreadIncoming: the newest `n` messages from others in a chat, for read
// receipts.
func (s *Store) UnreadIncoming(chat string, n int) ([]*Msg, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT `+msgCols+` FROM messages WHERE chat = ? AND from_me = 0 ORDER BY ts DESC LIMIT ?`, chat, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Msg
	for rows.Next() {
		m, err := scanMsg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func (s *Store) SetStatus(chat, id string, status int) (*Msg, error) {
	s.mu.Lock()
	_, err := s.db.Exec(`UPDATE messages SET status = ? WHERE chat = ? AND id = ? AND (status < ? OR ? = -1)`, status, chat, id, status, status)
	s.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return s.Message(chat, id)
}

func (s *Store) SetMedia(chat, id string, media *Media) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE messages SET media = ? WHERE chat = ? AND id = ?`, jsonOf(media), chat, id)
	return err
}

func (s *Store) SetReactions(chat, id string, r []Reaction) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`UPDATE messages SET reactions = ? WHERE chat = ? AND id = ?`, jsonOf(r), chat, id)
	return err
}

// ── chats ────────────────────────────────────────────────────────────────

const chatCols = `jid, name, is_group, last_ts, preview, preview_kind, preview_me, preview_who, unread, muted_until, pinned, archived, avatar,
	COALESCE((SELECT status FROM messages m WHERE m.chat = chats.jid ORDER BY ts DESC LIMIT 1), 0)`

func scanChat(sc interface{ Scan(...any) error }) (*Chat, error) {
	var c Chat
	var g, me, pin, arch int
	if err := sc.Scan(&c.JID, &c.Name, &g, &c.LastTs, &c.Preview, &c.PreviewKind, &me, &c.PreviewWho,
		&c.Unread, &c.MutedUntil, &pin, &arch, &c.Avatar, &c.PreviewStatus); err != nil {
		return nil, err
	}
	c.IsGroup, c.PreviewMe, c.Pinned, c.Archived = g != 0, me != 0, pin != 0, arch != 0
	return &c, nil
}

func (s *Store) Chats() ([]*Chat, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT ` + chatCols + ` FROM chats WHERE last_ts > 0 OR pinned = 1 ORDER BY pinned DESC, last_ts DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Chat
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) Chat(jid string) (*Chat, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return scanChat(s.db.QueryRow(`SELECT `+chatCols+` FROM chats WHERE jid = ?`, jid))
}

// EnsureChat makes the row if there isn't one.
func (s *Store) EnsureChat(jid string, isGroup bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`INSERT OR IGNORE INTO chats (jid, is_group) VALUES (?, ?)`, jid, b2i(isGroup))
}

func (s *Store) SetChatName(jid, name string) {
	if name == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET name = ? WHERE jid = ?`, name, jid)
}

// Touch moves a chat's preview to a message, if it is the newest.
func (s *Store) Touch(m *Msg, preview, kind string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	who := ""
	if !m.FromMe {
		who = m.SenderName
	}
	_, _ = s.db.Exec(`UPDATE chats SET last_ts = ?, preview = ?, preview_kind = ?, preview_me = ?, preview_who = ?
		WHERE jid = ? AND last_ts <= ?`, m.Ts, preview, kind, b2i(m.FromMe), who, m.Chat, m.Ts)
}

// Bump puts a chat with nothing in it yet at the top (a new chat).
func (s *Store) Bump(jid string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET last_ts = ? WHERE jid = ? AND last_ts = 0`, time.Now().UnixMilli(), jid)
}

func (s *Store) AddUnread(jid string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET unread = unread + ? WHERE jid = ?`, n, jid)
}

func (s *Store) SetUnread(jid string, n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET unread = ? WHERE jid = ?`, n, jid)
}

func (s *Store) SetFlag(jid, col string, v int64) {
	switch col {
	case "pinned", "archived", "muted_until":
	default:
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET `+col+` = ? WHERE jid = ?`, v, jid)
}

func (s *Store) SetAvatar(jid, path, id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, _ = s.db.Exec(`UPDATE chats SET avatar = ?, avatar_id = ?, avatar_at = ? WHERE jid = ?`, path, id, time.Now().Unix(), jid)
}

func (s *Store) AvatarState(jid string) (path, id string, at int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.db.QueryRow(`SELECT avatar, avatar_id, avatar_at FROM chats WHERE jid = ?`, jid).Scan(&path, &id, &at)
	return
}

func (s *Store) TotalUnread() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int
	_ = s.db.QueryRow(`SELECT COALESCE(SUM(unread), 0) FROM chats WHERE archived = 0 AND muted_until < ?`, time.Now().UnixMilli()).Scan(&n)
	return n
}

func (s *Store) Wipe() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.Exec(`DELETE FROM messages; DELETE FROM chats;`)
	return err
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
