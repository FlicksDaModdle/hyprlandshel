package main

// Desktop notifications for new messages, through the notification
// service (the shell's own, or whichever is running). One per chat,
// replaced as more arrive; clicking it opens the chat. Closed when the chat
// is read, here or on the phone.

import (
	"fmt"
	"sync"

	"github.com/godbus/dbus/v5"
)

const (
	notifyDest  = "org.freedesktop.Notifications"
	notifyPath  = "/org/freedesktop/Notifications"
	notifyIface = "org.freedesktop.Notifications"
)

type Notifier struct {
	conn   *dbus.Conn
	mu     sync.Mutex
	ids    map[string]uint32 // chat → notification
	chats  map[uint32]string
	onOpen func(chat string)
}

func NewNotifier(onOpen func(string)) *Notifier {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return nil
	}
	n := &Notifier{conn: conn, ids: map[string]uint32{}, chats: map[uint32]string{}, onOpen: onOpen}
	_ = conn.AddMatchSignal(dbus.WithMatchInterface(notifyIface), dbus.WithMatchObjectPath(notifyPath))
	sig := make(chan *dbus.Signal, 16)
	conn.Signal(sig)
	go func() {
		for s := range sig {
			switch s.Name {
			case notifyIface + ".ActionInvoked":
				if len(s.Body) < 2 {
					continue
				}
				id, _ := s.Body[0].(uint32)
				n.mu.Lock()
				chat := n.chats[id]
				n.mu.Unlock()
				if chat != "" && n.onOpen != nil {
					n.onOpen(chat)
				}
			case notifyIface + ".NotificationClosed":
				if len(s.Body) < 1 {
					continue
				}
				id, _ := s.Body[0].(uint32)
				n.mu.Lock()
				if chat, ok := n.chats[id]; ok {
					delete(n.chats, id)
					if n.ids[chat] == id {
						delete(n.ids, chat)
					}
				}
				n.mu.Unlock()
			}
		}
	}()
	return n
}

func (n *Notifier) Message(c *Chat, m *Msg) {
	if n == nil {
		return
	}
	summary := c.Name
	if summary == "" {
		summary = "New message"
	}
	if c.Unread > 1 {
		summary = fmt.Sprintf("%s (%d)", summary, c.Unread)
	}
	body := previewOf(m.Kind, m.Text, m.Media)
	if c.IsGroup && m.SenderName != "" {
		body = m.SenderName + ": " + body
	}
	icon := "hyprshell-chats"
	if c.Avatar != "" {
		icon = c.Avatar
	}
	n.mu.Lock()
	replaces := n.ids[c.JID]
	n.mu.Unlock()
	hints := map[string]dbus.Variant{
		"desktop-entry": dbus.MakeVariant("hyprshell-chats"),
		"category":      dbus.MakeVariant("im.received"),
		"sound-name":    dbus.MakeVariant("message-new-instant"),
	}
	call := n.conn.Object(notifyDest, notifyPath).Call(notifyIface+".Notify", 0,
		"Chats", replaces, icon, summary, escape(body), []string{"default", "Open"}, hints, int32(-1))
	if call.Err != nil {
		return
	}
	var id uint32
	if err := call.Store(&id); err != nil {
		return
	}
	n.mu.Lock()
	n.ids[c.JID] = id
	n.chats[id] = c.JID
	n.mu.Unlock()
}

func (n *Notifier) Clear(chat string) {
	if n == nil {
		return
	}
	n.mu.Lock()
	id, ok := n.ids[chat]
	delete(n.ids, chat)
	n.mu.Unlock()
	if ok {
		n.conn.Object(notifyDest, notifyPath).Call(notifyIface+".CloseNotification", 0, id)
	}
}

func (n *Notifier) ClearAll() {
	if n == nil {
		return
	}
	n.mu.Lock()
	var chats []string
	for c := range n.ids {
		chats = append(chats, c)
	}
	n.mu.Unlock()
	for _, c := range chats {
		n.Clear(c)
	}
}

// Notification bodies may be read as markup.
func escape(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		switch r {
		case '<':
			out = append(out, []rune("&lt;")...)
		case '>':
			out = append(out, []rune("&gt;")...)
		case '&':
			out = append(out, []rune("&amp;")...)
		default:
			out = append(out, r)
		}
	}
	return string(out)
}
