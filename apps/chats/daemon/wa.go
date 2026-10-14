package main

// WhatsApp itself, through whatsmeow: the linked-device protocol WhatsApp
// Web speaks, end-to-end encryption included. This file turns its events
// into the store's chats and messages and the window's events, and the
// window's requests into messages sent.

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	_ "image/gif"
	"image/jpeg"
	_ "image/png"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"golang.org/x/image/draw"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

type WA struct {
	srv   *Server
	store *Store
	dir   string
	ctx   context.Context

	container *sqlstore.Container
	cli       *whatsmeow.Client

	mu      sync.Mutex
	state   string // pairing, connecting, online, offline, error
	errText string
	pairing bool
	phone   string // pairing by code: the number asked for

	downloads chan [2]string
	avatars   chan string
	queued    sync.Map
	reloadT   *time.Timer
}

func NewWA(srv *Server, st *Store, dir string) (*WA, error) {
	// What the phone's "Linked devices" list shows for this one.
	store.SetOSInfo("Hyprshell", [3]uint32{1, 0, 0})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()

	ctx := context.Background()
	logger := waLog.Stdout("whatsapp", "WARN", false)
	c, err := sqlstore.New(ctx, "sqlite3", "file:"+filepath.Join(dir, "session.db")+"?_foreign_keys=on&_busy_timeout=5000", logger)
	if err != nil {
		return nil, err
	}
	_ = os.Chmod(filepath.Join(dir, "session.db"), 0o600)
	w := &WA{srv: srv, store: st, dir: dir, ctx: ctx, container: c,
		downloads: make(chan [2]string, 4096), avatars: make(chan string, 4096)}
	if err := w.newClient(); err != nil {
		return nil, err
	}
	for i := 0; i < 2; i++ {
		go w.downloader()
	}
	go w.avatarFetcher()
	return w, nil
}

func (w *WA) newClient() error {
	dev, err := w.container.GetFirstDevice(w.ctx)
	if err != nil {
		return err
	}
	cli := whatsmeow.NewClient(dev, waLog.Stdout("client", "WARN", false))
	cli.AutomaticMessageRerequestFromPhone = true
	cli.InitialAutoReconnect = true
	cli.AddEventHandler(w.handle)
	w.cli = cli
	return nil
}

func (w *WA) setState(state, errText string) {
	w.mu.Lock()
	w.state, w.errText = state, errText
	w.mu.Unlock()
	ev := w.State()
	ev["ev"] = "state"
	w.srv.Emit(ev)
}

func (w *WA) State() map[string]any {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := map[string]any{"state": w.state, "error": w.errText, "demo": false}
	if id := w.cli.Store.ID; id != nil {
		out["me"] = id.ToNonAD().String()
		out["name"] = w.cli.Store.PushName
	}
	return out
}

func (w *WA) Start() {
	if w.cli.Store.ID == nil {
		w.setState("pairing", "")
		return
	}
	w.setState("connecting", "")
	go func() {
		if err := w.cli.Connect(); err != nil {
			w.setState("offline", err.Error())
		}
	}()
}

// ── linking ──────────────────────────────────────────────────────────────

func (w *WA) Pair(phone string) error {
	if w.cli.Store.ID != nil {
		return errors.New("already linked")
	}
	phone = regexp.MustCompile(`\D`).ReplaceAllString(phone, "")
	w.mu.Lock()
	running := w.pairing
	w.phone = phone
	w.mu.Unlock()
	if running {
		// Already showing codes: a number asked for now gets its code now.
		if phone != "" && w.cli.IsConnected() {
			go w.pairPhone(phone)
		}
		return nil
	}
	qr, err := w.cli.GetQRChannel(w.ctx)
	if err != nil {
		return err
	}
	if err := w.cli.Connect(); err != nil {
		return err
	}
	w.mu.Lock()
	w.pairing = true
	w.mu.Unlock()
	w.setState("pairing", "")
	go func() {
		first := true
		for item := range qr {
			switch item.Event {
			case "code":
				w.srv.Emit(map[string]any{"ev": "qr", "code": item.Code, "timeout": item.Timeout.Seconds()})
				if first {
					first = false
					w.mu.Lock()
					p := w.phone
					w.mu.Unlock()
					if p != "" {
						go w.pairPhone(p)
					}
				}
			case "success":
				w.setState("connecting", "")
			case "timeout":
				w.cli.Disconnect()
				if first {
					// Not one code came: WhatsApp was never reached.
					w.setState("pairing", "Couldn't reach WhatsApp. Check your connection and try again.")
				} else {
					w.setState("pairing", "The code ran out before it was scanned. Try again.")
				}
			default:
				w.cli.Disconnect()
				msg := item.Event
				if item.Error != nil {
					msg = item.Error.Error()
				}
				w.setState("pairing", "Linking didn't work: "+msg)
			}
		}
		w.mu.Lock()
		w.pairing = false
		w.mu.Unlock()
	}()
	return nil
}

func (w *WA) pairPhone(phone string) {
	code, err := w.cli.PairPhone(w.ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		w.srv.Emit(map[string]any{"ev": "pairCode", "error": err.Error()})
		return
	}
	w.srv.Emit(map[string]any{"ev": "pairCode", "code": code})
}

// ── names and addresses ──────────────────────────────────────────────────

// canon: the address a chat or person is kept under. WhatsApp is moving
// people to "LIDs", hidden IDs, and sends either; the phone number is
// preferred where it is known, so one person is one chat.
func (w *WA) canon(j types.JID) types.JID {
	j = j.ToNonAD()
	if j.Server == types.HiddenUserServer {
		if pn, err := w.cli.Store.LIDs.GetPNForLID(w.ctx, j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return j
}

func (w *WA) me() types.JID {
	if id := w.cli.Store.ID; id != nil {
		return id.ToNonAD()
	}
	return types.EmptyJID
}

func (w *WA) isMe(j types.JID) bool {
	j = j.ToNonAD()
	return j == w.me() || (!w.cli.Store.LID.IsEmpty() && j == w.cli.Store.LID.ToNonAD())
}

func (w *WA) nameOf(j types.JID, pushName string) string {
	if w.isMe(j) {
		return "You"
	}
	if j.Server == types.GroupServer {
		if c, err := w.store.Chat(j.String()); err == nil && c.Name != "" {
			return c.Name
		}
		return "Group"
	}
	if c, err := w.cli.Store.Contacts.GetContact(w.ctx, j); err == nil && c.Found {
		for _, n := range []string{c.FullName, c.FirstName, c.BusinessName, c.PushName} {
			if n != "" {
				return n
			}
		}
		if pushName == "" && c.RedactedPhone != "" {
			return c.RedactedPhone
		}
	}
	if pushName != "" {
		return "~" + pushName
	}
	if j.Server == types.DefaultUserServer {
		return "+" + j.User
	}
	return "Someone"
}

// The chat's row, made if it isn't there, and named.
func (w *WA) ensureChat(j types.JID) {
	w.store.EnsureChat(j.String(), j.Server == types.GroupServer)
	if c, err := w.store.Chat(j.String()); err == nil && (c.Name == "" || strings.HasPrefix(c.Name, "+") || strings.HasPrefix(c.Name, "~")) {
		if j.Server == types.GroupServer {
			go w.fetchGroupName(j)
		} else if n := w.nameOf(j, ""); n != "" {
			w.store.SetChatName(j.String(), n)
		}
	}
}

var groupNameAsked sync.Map

func (w *WA) fetchGroupName(j types.JID) {
	if _, done := groupNameAsked.LoadOrStore(j, true); done || !w.cli.IsConnected() {
		return
	}
	info, err := w.cli.GetGroupInfo(w.ctx, j)
	if err != nil || info == nil {
		return
	}
	w.store.SetChatName(j.String(), info.Name)
	w.srv.EmitChat(j.String())
}

// Contacts can arrive after the chats they name: names again, from the
// session's contact list.
func (w *WA) refreshNames() {
	cs, err := w.store.Chats()
	if err != nil {
		return
	}
	for _, c := range cs {
		if c.IsGroup {
			continue
		}
		j, err := types.ParseJID(c.JID)
		if err != nil {
			continue
		}
		// A better name than the one kept: the contact's own over a number
		// or a "~push name".
		n := w.nameOf(j, "")
		weak := strings.HasPrefix(n, "+") || strings.HasPrefix(n, "~")
		if n != c.Name && (c.Name == "" || !weak) {
			w.store.SetChatName(c.JID, n)
		}
	}
	w.reloadSoon()
}

func (w *WA) reloadSoon() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.reloadT != nil {
		w.reloadT.Stop()
	}
	w.reloadT = time.AfterFunc(600*time.Millisecond, func() {
		w.srv.Emit(map[string]any{"ev": "reload"})
		w.srv.EmitUnread()
	})
}

// ── events ───────────────────────────────────────────────────────────────

func (w *WA) handle(evt any) {
	switch e := evt.(type) {
	case *events.Connected, *events.KeepAliveRestored:
		w.setState("online", "")
		go w.afterConnect()
	case *events.Disconnected, *events.KeepAliveTimeout:
		w.mu.Lock()
		st := w.state
		w.mu.Unlock()
		if st == "online" || st == "connecting" {
			w.setState("offline", "")
		}
	case *events.PairSuccess:
		w.setState("connecting", "")
	case *events.LoggedOut:
		w.forget("Chats was unlinked from your phone. Link it again to carry on.")
	case *events.StreamReplaced:
		w.setState("error", "This WhatsApp session was opened somewhere else.")
	case *events.ClientOutdated:
		w.setState("error", "WhatsApp says this version is too old. Update Chats (it needs a newer whatsmeow).")
	case *events.TemporaryBan:
		w.setState("error", fmt.Sprintf("WhatsApp has temporarily banned this account (%s), for %s.", e.Code, e.Expire.Round(time.Minute)))
	case *events.ConnectFailure:
		w.setState("error", fmt.Sprintf("WhatsApp refused the connection: %s %s", e.Reason, e.Message))
	case *events.Message:
		w.onMessage(e, true)
	case *events.UndecryptableMessage:
		chat := w.canon(e.Info.Chat)
		if skipChat(chat) {
			return
		}
		w.ensureChat(chat)
		m := &Msg{Chat: chat.String(), ID: e.Info.ID, Sender: w.canon(e.Info.Sender).String(), FromMe: e.Info.IsFromMe,
			Ts: e.Info.Timestamp.UnixMilli(), Kind: "waiting", Status: StatusSent}
		if !m.FromMe {
			m.SenderName = w.nameOf(w.canon(e.Info.Sender), e.Info.PushName)
		}
		if isNew, _ := w.store.PutMessage(m); isNew {
			w.store.Touch(m, previewOf(m.Kind, "", nil), m.Kind)
			w.srv.EmitMessage(m)
			w.srv.EmitChat(m.Chat)
		}
	case *events.Receipt:
		w.onReceipt(e)
	case *events.HistorySync:
		go w.onHistory(e)
	case *events.ChatPresence:
		chat := w.canon(e.Chat)
		ev := map[string]any{"ev": "typing", "chat": chat.String(), "on": e.State == types.ChatPresenceComposing,
			"audio": e.Media == types.ChatPresenceMediaAudio}
		if e.IsGroup {
			ev["who"] = w.nameOf(w.canon(e.Sender), "")
		}
		w.srv.Emit(ev)
	case *events.PushName:
		w.renameIfChat(w.canon(e.JID))
	case *events.Contact:
		w.renameIfChat(w.canon(e.JID))
	case *events.AppStateSyncComplete:
		go w.refreshNames()
	case *events.GroupInfo:
		if e.Name != nil {
			j := w.canon(e.JID)
			w.store.SetChatName(j.String(), e.Name.Name)
			w.srv.EmitChat(j.String())
		}
	case *events.JoinedGroup:
		j := w.canon(e.JID)
		w.store.EnsureChat(j.String(), true)
		w.store.SetChatName(j.String(), e.GroupInfo.Name)
		w.srv.EmitChat(j.String())
	case *events.Picture:
		j := w.canon(e.JID)
		w.store.SetAvatar(j.String(), "", "")
		w.srv.EmitChat(j.String())
	case *events.Archive:
		j := w.canon(e.JID)
		w.store.SetFlag(j.String(), "archived", int64(b2i(e.Action.GetArchived())))
		w.srv.EmitChat(j.String())
	case *events.Pin:
		j := w.canon(e.JID)
		w.store.SetFlag(j.String(), "pinned", int64(b2i(e.Action.GetPinned())))
		w.srv.EmitChat(j.String())
	case *events.Mute:
		j := w.canon(e.JID)
		w.store.SetFlag(j.String(), "muted_until", muteEnd(e.Action.GetMuted(), e.Action.GetMuteEndTimestamp()))
		w.srv.EmitChat(j.String())
	case *events.MarkChatAsRead:
		j := w.canon(e.JID)
		if e.Action.GetRead() {
			w.store.SetUnread(j.String(), 0)
			if w.srv.notify != nil {
				w.srv.notify.Clear(j.String())
			}
		} else if c, err := w.store.Chat(j.String()); err == nil && c.Unread == 0 {
			w.store.SetUnread(j.String(), 1)
		}
		w.srv.EmitChat(j.String())
	}
}

func muteEnd(muted bool, end int64) int64 {
	if !muted {
		return 0
	}
	if end <= 0 {
		return 1 << 60 // for ever
	}
	if end < 1e12 { // seconds, not milliseconds
		end *= 1000
	}
	return end
}

func (w *WA) renameIfChat(j types.JID) {
	if _, err := w.store.Chat(j.String()); err != nil {
		return
	}
	if n := w.nameOf(j, ""); n != "" {
		w.store.SetChatName(j.String(), n)
		w.srv.EmitChat(j.String())
	}
}

func (w *WA) afterConnect() {
	// Group names, in one request rather than one per group.
	if groups, err := w.cli.GetJoinedGroups(w.ctx); err == nil {
		for _, g := range groups {
			j := w.canon(g.JID)
			w.store.EnsureChat(j.String(), true)
			w.store.SetChatName(j.String(), g.Name)
			groupNameAsked.Store(j, true)
		}
		w.reloadSoon()
	}
	// Online only while the window is up and in front, as WhatsApp Web is.
	w.Presence(w.srv.focusedNow())
}

// Status updates and channels aren't shown here.
func skipChat(j types.JID) bool {
	return j.Server == types.BroadcastServer || j.Server == types.NewsletterServer || j.IsEmpty()
}

// Fields a message can carry that are bookkeeping, not something to show.
var quietFields = map[string]bool{
	"senderKeyDistributionMessage": true, "messageContextInfo": true, "pollUpdateMessage": true,
	"encReactionMessage": true, "keepInChatMessage": true, "pinInChatMessage": true,
	"encEventResponseMessage": true, "secretEncryptedMessage": true, "fastRatchetKeySenderKeyDistributionMessage": true,
	"protocolMessage": true, "reactionMessage": true, "callLogMesssage": true, "botInvokeMessage": true,
}

func onlyBookkeeping(m *waE2E.Message) bool {
	quiet := true
	m.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		if !quietFields[string(fd.JSONName())] && !quietFields[string(fd.Name())] {
			quiet = false
			return false
		}
		return true
	})
	return quiet
}

func (w *WA) onMessage(e *events.Message, live bool) {
	info := e.Info
	chat := w.canon(info.Chat)
	if skipChat(chat) || e.Message == nil {
		return
	}
	m := e.Message
	sender := w.canon(info.Sender)
	fromMe := info.IsFromMe || w.isMe(sender)

	if r := m.GetReactionMessage(); r != nil {
		w.onReaction(chat, sender, fromMe, r.GetKey().GetID(), r.GetText())
		return
	}
	if p := m.GetProtocolMessage(); p != nil {
		target := p.GetKey().GetID()
		switch p.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			if old, err := w.store.Message(chat.String(), target); err == nil {
				old.Kind, old.Text, old.Media, old.Quote, old.Reactions = "deleted", "", nil, nil, nil
				w.store.PutMessage(old)
				w.store.SetReactions(old.Chat, old.ID, nil)
				w.store.Touch(old, previewOf("deleted", "", nil), "deleted")
				w.srv.EmitMessage(old)
				w.srv.EmitChat(old.Chat)
			}
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			if old, err := w.store.Message(chat.String(), target); err == nil {
				c := extract(p.GetEditedMessage())
				if c.text != "" {
					old.Text, old.Edited = c.text, true
					w.store.PutMessage(old)
					w.srv.EmitMessage(old)
				}
			}
		}
		return
	}
	if onlyBookkeeping(m) {
		return
	}

	c := extract(m)
	msg := &Msg{
		Chat: chat.String(), ID: info.ID, Sender: sender.String(), FromMe: fromMe,
		Ts: info.Timestamp.UnixMilli(), Kind: c.kind, Text: c.text, Media: c.media,
		Status: StatusSent, Edited: e.IsEdit,
	}
	if !fromMe {
		msg.SenderName = w.nameOf(sender, info.PushName)
	}
	if c.ctx != nil && c.ctx.GetStanzaID() != "" {
		q := &Quote{ID: c.ctx.GetStanzaID()}
		if pj, err := types.ParseJID(c.ctx.GetParticipant()); err == nil && !pj.IsEmpty() {
			pj = w.canon(pj)
			q.Sender, q.FromMe = pj.String(), w.isMe(pj)
			if !q.FromMe {
				q.SenderName = w.nameOf(pj, "")
			}
		}
		qc := extract(c.ctx.GetQuotedMessage())
		q.Kind, q.Text = qc.kind, previewOf(qc.kind, qc.text, qc.media)
		msg.Quote = q
	}
	if mediaOf(m) != nil {
		msg.Raw, _ = proto.Marshal(m)
	}
	if len(c.thumb) > 0 {
		if msg.Media == nil {
			msg.Media = &Media{}
		}
		msg.Media.Thumb = w.saveThumb(msg, c.thumb)
	}
	// Already here (a history sync repeating one), keep what was found out
	// about it since: its download, its reactions.
	if old, err := w.store.Message(msg.Chat, msg.ID); err == nil {
		if old.Media != nil && msg.Media != nil && old.Media.Path != "" {
			msg.Media.Path = old.Media.Path
		}
		msg.Reactions = old.Reactions
		if old.Status > msg.Status {
			msg.Status = old.Status
		}
	}
	if e.SourceWebMsg != nil {
		msg.Status = statusOfWeb(e.SourceWebMsg.GetStatus(), fromMe)
		for _, r := range e.SourceWebMsg.GetReactions() {
			if r.GetText() == "" {
				continue
			}
			rs := Reaction{Emoji: r.GetText()}
			if rj, err := types.ParseJID(r.GetKey().GetParticipant()); err == nil && !rj.IsEmpty() {
				rs.Sender, rs.FromMe = w.canon(rj).String(), w.isMe(rj)
			} else {
				rs.FromMe = r.GetKey().GetFromMe()
			}
			msg.Reactions = append(msg.Reactions, rs)
		}
	}

	w.ensureChat(chat)
	isNew, err := w.store.PutMessage(msg)
	if err != nil {
		log.Printf("store: %v", err)
		return
	}
	w.store.Touch(msg, previewOf(msg.Kind, msg.Text, msg.Media), msg.Kind)
	if !live {
		return
	}
	if fromMe {
		// Written on the phone: WhatsApp counts the chat as read.
		w.store.SetUnread(msg.Chat, 0)
	} else if isNew && !w.srv.Viewing(msg.Chat) {
		w.store.AddUnread(msg.Chat, 1)
		if w.srv.notify != nil {
			if ch, err := w.store.Chat(msg.Chat); err == nil && ch.MutedUntil < time.Now().UnixMilli() && !ch.Archived {
				w.srv.notify.Message(ch, msg)
			}
		}
	}
	w.srv.EmitMessage(msg)
	w.srv.EmitChat(msg.Chat)
	w.autoDownload(msg)
}

func statusOfWeb(s waWeb.WebMessageInfo_Status, fromMe bool) int {
	if !fromMe {
		return StatusSent
	}
	switch s {
	case waWeb.WebMessageInfo_ERROR:
		return StatusFailed
	case waWeb.WebMessageInfo_PENDING:
		return StatusPending
	case waWeb.WebMessageInfo_DELIVERY_ACK:
		return StatusDelivered
	case waWeb.WebMessageInfo_READ:
		return StatusRead
	case waWeb.WebMessageInfo_PLAYED:
		return StatusPlayed
	}
	return StatusSent
}

func (w *WA) onReaction(chat, sender types.JID, fromMe bool, target, emoji string) {
	m, err := w.store.Message(chat.String(), target)
	if err != nil {
		return
	}
	var out []Reaction
	for _, r := range m.Reactions {
		if (fromMe && r.FromMe) || (!fromMe && r.Sender == sender.String()) {
			continue
		}
		out = append(out, r)
	}
	if emoji != "" {
		out = append(out, Reaction{Emoji: emoji, Sender: sender.String(), FromMe: fromMe})
	}
	m.Reactions = out
	_ = w.store.SetReactions(m.Chat, m.ID, out)
	w.srv.EmitMessage(m)
}

func (w *WA) onReceipt(e *events.Receipt) {
	var st int
	switch e.Type {
	case types.ReceiptTypeDelivered:
		st = StatusDelivered
	case types.ReceiptTypeRead:
		st = StatusRead
	case types.ReceiptTypePlayed:
		st = StatusPlayed
	case types.ReceiptTypeReadSelf:
		// Read on the phone.
		chat := w.canon(e.Chat).String()
		w.store.SetUnread(chat, 0)
		if w.srv.notify != nil {
			w.srv.notify.Clear(chat)
		}
		w.srv.EmitChat(chat)
		return
	default:
		return
	}
	chat := w.canon(e.Chat).String()
	for _, id := range e.MessageIDs {
		m, err := w.store.SetStatus(chat, id, st)
		if err != nil {
			if mm, err2 := w.store.MessageByID(id); err2 == nil && mm.FromMe {
				m, err = w.store.SetStatus(mm.Chat, id, st)
			}
		}
		if err == nil && m != nil {
			w.srv.EmitMessage(m)
		}
	}
	w.srv.EmitChat(chat)
}

func (w *WA) onHistory(e *events.HistorySync) {
	for _, conv := range e.Data.GetConversations() {
		raw, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		chat := w.canon(raw)
		if pn := conv.GetPnJID(); pn != "" && raw.Server == types.HiddenUserServer {
			if p, err := types.ParseJID(pn); err == nil {
				chat = p.ToNonAD()
			}
		}
		if skipChat(chat) {
			continue
		}
		w.store.EnsureChat(chat.String(), chat.Server == types.GroupServer)
		if n := conv.GetName(); n != "" {
			w.store.SetChatName(chat.String(), n)
		} else if n := conv.GetDisplayName(); n != "" {
			w.store.SetChatName(chat.String(), n)
		}
		w.ensureChat(chat)
		w.store.SetUnread(chat.String(), int(conv.GetUnreadCount()))
		w.store.SetFlag(chat.String(), "archived", int64(b2i(conv.GetArchived())))
		w.store.SetFlag(chat.String(), "pinned", int64(b2i(conv.GetPinned() > 0)))
		if end := conv.GetMuteEndTime(); end > 0 {
			w.store.SetFlag(chat.String(), "muted_until", muteEnd(true, int64(end)))
		}
		for _, hm := range conv.GetMessages() {
			evt, err := w.cli.ParseWebMessage(raw, hm.GetMessage())
			if err != nil {
				continue
			}
			w.onMessage(evt, false)
		}
	}
	w.refreshNames()
}

// ── media ────────────────────────────────────────────────────────────────

func safeName(s string) string {
	s = regexp.MustCompile(`[^\w.\-]+`).ReplaceAllString(s, "_")
	if len(s) > 80 {
		s = s[:80]
	}
	return s
}

func (w *WA) mediaDir(chat string) string {
	d := filepath.Join(w.dir, "media", safeName(chat))
	_ = os.MkdirAll(d, 0o700)
	return d
}

func (w *WA) saveThumb(m *Msg, jpg []byte) string {
	p := filepath.Join(w.mediaDir(m.Chat), safeName(m.ID)+".thumb.jpg")
	if err := os.WriteFile(p, jpg, 0o600); err != nil {
		return ""
	}
	return p
}

// Pictures, stickers and voice messages come down by themselves (up to a
// size); videos and documents when asked for.
func (w *WA) autoDownload(m *Msg) {
	if m.Media == nil || len(m.Raw) == 0 || m.Media.Path != "" {
		return
	}
	switch m.Kind {
	case "image", "sticker", "voice", "gif":
	default:
		return
	}
	if m.Media.Size > 12<<20 {
		return
	}
	key := m.Chat + "\x00" + m.ID
	if _, dup := w.queued.LoadOrStore(key, true); dup {
		return
	}
	select {
	case w.downloads <- [2]string{m.Chat, m.ID}:
	default:
		w.queued.Delete(key)
	}
}

func (w *WA) downloader() {
	for job := range w.downloads {
		_, _ = w.Download(job[0], job[1])
		w.queued.Delete(job[0] + "\x00" + job[1])
	}
}

func (w *WA) Download(chat, id string) (*Msg, error) {
	m, err := w.store.Message(chat, id)
	if err != nil {
		return nil, err
	}
	if m.Media != nil && m.Media.Path != "" {
		if _, err := os.Stat(m.Media.Path); err == nil {
			return m, nil
		}
	}
	if len(m.Raw) == 0 {
		return nil, errors.New("nothing to download")
	}
	var pm waE2E.Message
	if err := proto.Unmarshal(m.Raw, &pm); err != nil {
		return nil, err
	}
	dm := mediaOf(&pm)
	if dm == nil {
		return nil, errors.New("nothing to download")
	}
	if !w.cli.IsConnected() {
		return nil, errors.New("not connected")
	}
	data, err := w.cli.Download(w.ctx, dm)
	if m.Media == nil {
		m.Media = &Media{}
	}
	if err != nil {
		if errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) || errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) {
			m.Media.Failed = "No longer on WhatsApp's servers"
		} else {
			m.Media.Failed = "Couldn't download it"
		}
		_ = w.store.SetMedia(chat, id, m.Media)
		w.srv.EmitMessage(m)
		return nil, err
	}
	name := safeName(m.ID) + extFor(m.Media.Mime, m.Kind)
	if m.Kind == "document" && m.Media.Name != "" {
		name = safeName(m.ID) + "-" + safeName(m.Media.Name)
	}
	p := filepath.Join(w.mediaDir(chat), name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return nil, err
	}
	m.Media.Path, m.Media.Failed = p, ""
	_ = w.store.SetMedia(chat, id, m.Media)
	w.srv.EmitMessage(m)
	return m, nil
}

// ── sending ──────────────────────────────────────────────────────────────

func (w *WA) online() error {
	if !w.cli.IsConnected() || !w.cli.IsLoggedIn() {
		return errors.New("not connected to WhatsApp")
	}
	return nil
}

func (w *WA) quoteCtx(chat, quote string) (*waE2E.ContextInfo, *Quote) {
	if quote == "" {
		return nil, nil
	}
	q, err := w.store.Message(chat, quote)
	if err != nil {
		return nil, nil
	}
	sender := q.Sender
	if q.FromMe {
		sender = w.me().String()
	}
	quoted := &waE2E.Message{Conversation: proto.String(q.Text)}
	if len(q.Raw) > 0 {
		var pm waE2E.Message
		if proto.Unmarshal(q.Raw, &pm) == nil {
			quoted = &pm
		}
	}
	return &waE2E.ContextInfo{StanzaID: proto.String(q.ID), Participant: proto.String(sender), QuotedMessage: quoted},
		&Quote{ID: q.ID, Sender: q.Sender, SenderName: q.SenderName, FromMe: q.FromMe, Kind: q.Kind, Text: previewOf(q.Kind, q.Text, q.Media)}
}

// record puts a message you're sending in the chat straight away, before
// WhatsApp has it, and returns it.
func (w *WA) record(chat types.JID, m *Msg) {
	m.Chat, m.Sender, m.FromMe, m.Status = chat.String(), w.me().String(), true, StatusPending
	if m.Ts == 0 {
		m.Ts = time.Now().UnixMilli()
	}
	w.ensureChat(chat)
	_, _ = w.store.PutMessage(m)
	w.store.Touch(m, previewOf(m.Kind, m.Text, m.Media), m.Kind)
	w.store.SetUnread(m.Chat, 0)
	w.srv.EmitMessage(m)
	w.srv.EmitChat(m.Chat)
}

func (w *WA) finish(m *Msg, resp whatsmeow.SendResponse, err error) {
	st := StatusSent
	if err != nil {
		log.Printf("send: %v", err)
		st = StatusFailed
	}
	if got, e := w.store.SetStatus(m.Chat, m.ID, st); e == nil {
		w.srv.EmitMessage(got)
		w.srv.EmitChat(m.Chat)
	}
}

func (w *WA) SendText(chat, text, quote string) (*Msg, error) {
	if err := w.online(); err != nil {
		return nil, err
	}
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(text) == "" {
		return nil, errors.New("nothing to send")
	}
	ctxInfo, q := w.quoteCtx(chat, quote)
	msg := &waE2E.Message{Conversation: proto.String(text)}
	if ctxInfo != nil {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text), ContextInfo: ctxInfo}}
	}
	m := &Msg{ID: w.cli.GenerateMessageID(), Kind: "text", Text: text, Quote: q}
	w.record(to, m)
	go func() {
		resp, err := w.cli.SendMessage(w.ctx, to, msg, whatsmeow.SendRequestExtra{ID: m.ID})
		w.finish(m, resp, err)
	}()
	return m, nil
}

func (w *WA) SendFile(chat, path, caption string, voice bool, seconds int, waveform []int) (*Msg, error) {
	if err := w.online(); err != nil {
		return nil, err
	}
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	fi, err := os.Stat(path)
	if err != nil || fi.IsDir() {
		return nil, errors.New("that file can't be read")
	}
	if fi.Size() > 2000<<20 {
		return nil, errors.New("WhatsApp takes files up to 2 GB")
	}
	head := make([]byte, 512)
	if f, err := os.Open(path); err == nil {
		n, _ := f.Read(head)
		head = head[:n]
		f.Close()
	}
	mt := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mt == "" {
		mt = http.DetectContentType(head)
	}
	mt = strings.TrimSpace(strings.SplitN(mt, ";", 2)[0])

	kind := "document"
	switch {
	case voice:
		kind, mt = "voice", "audio/ogg; codecs=opus"
	case mt == "image/jpeg" || mt == "image/png":
		kind = "image"
	case mt == "video/mp4":
		kind = "video"
	case strings.HasPrefix(mt, "audio/"):
		kind = "audio"
	}

	// A copy in Chats' own folder, so the conversation keeps it whatever
	// happens to the original.
	local := filepath.Join(w.mediaDir(chat), safeName(fmt.Sprintf("%d-%s", time.Now().UnixNano(), filepath.Base(path))))
	var data []byte
	if kind == "image" {
		data, err = os.ReadFile(path)
		if err != nil {
			return nil, err
		}
	}
	var thumb []byte
	var width, height int
	if kind == "image" {
		img, _, err := image.Decode(bytes.NewReader(data))
		if err != nil {
			kind = "document"
		} else {
			b := img.Bounds()
			width, height = b.Dx(), b.Dy()
			if mt == "image/png" {
				// WhatsApp's own apps send pictures as JPEG.
				var buf bytes.Buffer
				_ = jpeg.Encode(&buf, flatten(img), &jpeg.Options{Quality: 88})
				data, mt = buf.Bytes(), "image/jpeg"
				local = strings.TrimSuffix(local, filepath.Ext(local)) + ".jpg"
			}
			thumb = thumbnail(img, 72)
		}
	}
	if data != nil {
		err = os.WriteFile(local, data, 0o600)
	} else {
		err = copyFile(path, local)
	}
	if err != nil {
		return nil, err
	}

	m := &Msg{ID: w.cli.GenerateMessageID(), Kind: kind, Text: caption,
		Media: &Media{Mime: mt, Size: fi.Size(), Width: width, Height: height, Seconds: seconds, Name: filepath.Base(path), Path: local, Waveform: waveform}}
	if kind == "image" || kind == "voice" {
		m.Media.Name = ""
	}
	w.record(to, m)

	go func() {
		appType := map[string]whatsmeow.MediaType{"image": whatsmeow.MediaImage, "video": whatsmeow.MediaVideo,
			"audio": whatsmeow.MediaAudio, "voice": whatsmeow.MediaAudio}[kind]
		if appType == "" {
			appType = whatsmeow.MediaDocument
		}
		f, err := os.Open(local)
		if err != nil {
			w.finish(m, whatsmeow.SendResponse{}, err)
			return
		}
		defer f.Close()
		tmp, err := os.CreateTemp(w.dir, "upload-*")
		if err != nil {
			w.finish(m, whatsmeow.SendResponse{}, err)
			return
		}
		defer os.Remove(tmp.Name())
		defer tmp.Close()
		up, err := w.cli.UploadReader(w.ctx, f, tmp, appType)
		if err != nil {
			w.finish(m, whatsmeow.SendResponse{}, err)
			return
		}
		size := up.FileLength
		var msg *waE2E.Message
		switch kind {
		case "image":
			msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(size),
				Mimetype: proto.String(mt), Caption: optional(caption), JPEGThumbnail: thumb,
				Width: proto.Uint32(uint32(width)), Height: proto.Uint32(uint32(height)),
			}}
		case "video":
			msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(size),
				Mimetype: proto.String(mt), Caption: optional(caption),
			}}
		case "audio", "voice":
			wave := make([]byte, 0, len(waveform))
			for _, v := range waveform {
				wave = append(wave, byte(max(0, min(100, v))))
			}
			am := &waE2E.AudioMessage{
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(size),
				Mimetype: proto.String(mt), PTT: proto.Bool(kind == "voice"), Seconds: proto.Uint32(uint32(seconds)),
			}
			if len(wave) > 0 {
				am.Waveform = wave
			}
			msg = &waE2E.Message{AudioMessage: am}
		default:
			msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
				URL: proto.String(up.URL), DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
				FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, FileLength: proto.Uint64(size),
				Mimetype: proto.String(mt), FileName: proto.String(filepath.Base(path)), Title: proto.String(filepath.Base(path)),
				Caption: optional(caption),
			}}
		}
		if raw, err := proto.Marshal(msg); err == nil {
			m.Raw = raw
			_, _ = w.store.PutMessage(m)
		}
		resp, err := w.cli.SendMessage(w.ctx, to, msg, whatsmeow.SendRequestExtra{ID: m.ID})
		w.finish(m, resp, err)
	}()
	return m, nil
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return proto.String(s)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// flatten: a PNG's transparency on white, for JPEG.
func flatten(img image.Image) image.Image {
	b := img.Bounds()
	dst := image.NewRGBA(b)
	draw.Draw(dst, b, image.White, image.Point{}, draw.Src)
	draw.Draw(dst, b, img, b.Min, draw.Over)
	return dst
}

func thumbnail(img image.Image, edge int) []byte {
	b := img.Bounds()
	w, h := edge, edge
	if b.Dx() > b.Dy() {
		h = max(1, edge*b.Dy()/b.Dx())
	} else {
		w = max(1, edge*b.Dx()/b.Dy())
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), flatten(img), b, draw.Src, nil)
	var buf bytes.Buffer
	_ = jpeg.Encode(&buf, dst, &jpeg.Options{Quality: 60})
	return buf.Bytes()
}

func (w *WA) React(chat, id, emoji string) error {
	if err := w.online(); err != nil {
		return err
	}
	m, err := w.store.Message(chat, id)
	if err != nil {
		return err
	}
	cj, _ := types.ParseJID(chat)
	sender := w.me()
	if !m.FromMe {
		sender, _ = types.ParseJID(m.Sender)
	}
	if _, err := w.cli.SendMessage(w.ctx, cj, w.cli.BuildReaction(cj, sender, id, emoji)); err != nil {
		return err
	}
	w.onReaction(cj, w.me(), true, id, emoji)
	return nil
}

func (w *WA) Revoke(chat, id string) error {
	if err := w.online(); err != nil {
		return err
	}
	m, err := w.store.Message(chat, id)
	if err != nil {
		return err
	}
	if !m.FromMe {
		return errors.New("only your own messages can be deleted for everyone")
	}
	cj, _ := types.ParseJID(chat)
	if _, err := w.cli.SendMessage(w.ctx, cj, w.cli.BuildRevoke(cj, types.EmptyJID, id)); err != nil {
		return err
	}
	m.Kind, m.Text, m.Media, m.Quote, m.Reactions = "deleted", "", nil, nil, nil
	_, _ = w.store.PutMessage(m)
	w.srv.EmitMessage(m)
	return nil
}

func (w *WA) Read(chat string) error {
	c, err := w.store.Chat(chat)
	if err != nil {
		return err
	}
	if w.srv.notify != nil {
		w.srv.notify.Clear(chat)
	}
	if c.Unread == 0 {
		return nil
	}
	w.store.SetUnread(chat, 0)
	w.srv.EmitChat(chat)
	if w.online() != nil {
		return nil
	}
	ms, err := w.store.UnreadIncoming(chat, min(c.Unread, 100))
	if err != nil || len(ms) == 0 {
		return err
	}
	cj, _ := types.ParseJID(chat)
	bySender := map[string][]types.MessageID{}
	for _, m := range ms {
		bySender[m.Sender] = append(bySender[m.Sender], m.ID)
	}
	for s, ids := range bySender {
		sj, _ := types.ParseJID(s)
		if !c.IsGroup {
			sj = cj
		}
		_ = w.cli.MarkRead(w.ctx, ids, time.Now(), cj, sj)
	}
	return nil
}

func (w *WA) Typing(chat string, on bool) {
	if w.online() != nil {
		return
	}
	cj, err := types.ParseJID(chat)
	if err != nil {
		return
	}
	st := types.ChatPresencePaused
	if on {
		st = types.ChatPresenceComposing
	}
	_ = w.cli.SendChatPresence(w.ctx, cj, st, types.ChatPresenceMediaText)
}

func (w *WA) Presence(online bool) {
	if w.online() != nil || w.cli.Store.PushName == "" {
		return
	}
	p := types.PresenceUnavailable
	if online {
		p = types.PresenceAvailable
	}
	_ = w.cli.SendPresence(w.ctx, p)
}

// ── profile pictures ─────────────────────────────────────────────────────

// Avatar: the picture's path if there is one already, and a fresh look in
// the background when it's over a day old. One request at a time, spaced
// out: dozens at once is how bots behave.
func (w *WA) Avatar(jid string) string {
	path, _, at := w.store.AvatarState(jid)
	if path != "" {
		if _, err := os.Stat(path); err != nil {
			path = ""
		}
	}
	if time.Since(time.Unix(at, 0)) > 24*time.Hour || (path == "" && at == 0) {
		if _, dup := w.queued.LoadOrStore("avatar:"+jid, true); !dup {
			select {
			case w.avatars <- jid:
			default:
				w.queued.Delete("avatar:" + jid)
			}
		}
	}
	return path
}

func (w *WA) avatarFetcher() {
	for jid := range w.avatars {
		w.fetchAvatar(jid)
		w.queued.Delete("avatar:" + jid)
		time.Sleep(700 * time.Millisecond)
	}
}

func (w *WA) fetchAvatar(jid string) {
	if w.online() != nil {
		return
	}
	j, err := types.ParseJID(jid)
	if err != nil {
		return
	}
	old, oldID, _ := w.store.AvatarState(jid)
	info, err := w.cli.GetProfilePictureInfo(w.ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true, ExistingID: oldID})
	if errors.Is(err, whatsmeow.ErrProfilePictureNotSet) {
		w.store.SetAvatar(jid, "", "")
		if old != "" {
			_ = os.Remove(old)
			w.srv.EmitChat(jid)
		}
		return
	}
	if err != nil {
		return
	}
	if info == nil {
		// Unchanged.
		w.store.SetAvatar(jid, old, oldID)
		return
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		return
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil || resp.StatusCode != 200 {
		return
	}
	dir := filepath.Join(w.dir, "avatars")
	_ = os.MkdirAll(dir, 0o700)
	sum := sha1.Sum([]byte(jid))
	p := filepath.Join(dir, hex.EncodeToString(sum[:8])+"-"+safeName(info.ID)+".jpg")
	if err := os.WriteFile(p, data, 0o600); err != nil {
		return
	}
	if old != "" && old != p {
		_ = os.Remove(old)
	}
	w.store.SetAvatar(jid, p, info.ID)
	w.srv.EmitChat(jid)
}

// ── new chats, signing out ───────────────────────────────────────────────

func (w *WA) NewChat(phone string) (string, error) {
	if err := w.online(); err != nil {
		return "", err
	}
	digits := regexp.MustCompile(`\D`).ReplaceAllString(phone, "")
	if len(digits) < 7 {
		return "", errors.New("that doesn't look like a phone number; include the country code")
	}
	res, err := w.cli.IsOnWhatsApp(w.ctx, []string{"+" + digits})
	if err != nil {
		return "", err
	}
	if len(res) == 0 || !res[0].IsIn {
		return "", errors.New("that number isn't on WhatsApp")
	}
	j := w.canon(res[0].JID)
	w.ensureChat(j)
	w.store.Bump(j.String())
	w.srv.EmitChat(j.String())
	return j.String(), nil
}

func (w *WA) Logout() error {
	if w.cli.Store.ID != nil && w.cli.IsConnected() {
		if err := w.cli.Logout(w.ctx); err != nil {
			log.Printf("logout: %v", err)
		}
	}
	w.forget("")
	return nil
}

// forget: everything of this account gone from the disk, and back to
// linking.
func (w *WA) forget(reason string) {
	w.cli.Disconnect()
	if w.cli.Store.ID != nil {
		_ = w.cli.Store.Delete(w.ctx)
	}
	_ = w.store.Wipe()
	_ = os.RemoveAll(filepath.Join(w.dir, "media"))
	_ = os.RemoveAll(filepath.Join(w.dir, "avatars"))
	if w.srv.notify != nil {
		w.srv.notify.ClearAll()
	}
	if err := w.newClient(); err != nil {
		w.setState("error", err.Error())
		return
	}
	w.setState("pairing", reason)
	w.srv.Emit(map[string]any{"ev": "reload"})
	w.srv.EmitUnread()
}
