package main

import (
	"path/filepath"
	"testing"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestExtract(t *testing.T) {
	cases := []struct {
		m    *waE2E.Message
		kind string
		text string
	}{
		{&waE2E.Message{Conversation: proto.String("hi")}, "text", "hi"},
		{&waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String("reply"),
			ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("X1")}}}, "text", "reply"},
		{&waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String("view"), Mimetype: proto.String("image/jpeg")}}, "image", "view"},
		{&waE2E.Message{AudioMessage: &waE2E.AudioMessage{PTT: proto.Bool(true), Seconds: proto.Uint32(12)}}, "voice", ""},
		{&waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{FileName: proto.String("a.pdf")}}, "document", ""},
		{&waE2E.Message{EphemeralMessage: &waE2E.FutureProofMessage{Message: &waE2E.Message{Conversation: proto.String("inner")}}}, "text", "inner"},
		{&waE2E.Message{}, "unsupported", ""},
	}
	for _, c := range cases {
		got := extract(c.m)
		if got.kind != c.kind || got.text != c.text {
			t.Errorf("extract(%v) = %q %q, want %q %q", c.m, got.kind, got.text, c.kind, c.text)
		}
	}
	if q := extract(cases[1].m).ctx.GetStanzaID(); q != "X1" {
		t.Errorf("reply's quote = %q", q)
	}
}

func TestPreview(t *testing.T) {
	for _, c := range []struct {
		kind, text string
		media      *Media
		want       string
	}{
		{"text", "first line\nsecond", nil, "first line"},
		{"image", "", nil, "Photo"},
		{"image", "a caption", nil, "a caption"},
		{"voice", "", &Media{Seconds: 75}, "Voice message (1:15)"},
		{"document", "", &Media{Name: "report.pdf"}, "report.pdf"},
		{"deleted", "", nil, "This message was deleted"},
	} {
		if got := previewOf(c.kind, c.text, c.media); got != c.want {
			t.Errorf("previewOf(%q, %q) = %q, want %q", c.kind, c.text, got, c.want)
		}
	}
}

func TestOnlyBookkeeping(t *testing.T) {
	if !onlyBookkeeping(&waE2E.Message{SenderKeyDistributionMessage: &waE2E.SenderKeyDistributionMessage{}}) {
		t.Error("a bare sender key distribution should be skipped")
	}
	if onlyBookkeeping(&waE2E.Message{SenderKeyDistributionMessage: &waE2E.SenderKeyDistributionMessage{}, Conversation: proto.String("x")}) {
		t.Error("a message with text should be kept")
	}
}

func TestStore(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatal(err)
	}
	s.EnsureChat("a@s.whatsapp.net", false)
	s.SetChatName("a@s.whatsapp.net", "A")
	for i, text := range []string{"one", "two", "three"} {
		m := &Msg{Chat: "a@s.whatsapp.net", ID: text, Ts: int64(1000 + i), Kind: "text", Text: text, Sender: "a@s.whatsapp.net"}
		if isNew, err := s.PutMessage(m); err != nil || !isNew {
			t.Fatalf("put %s: %v %v", text, isNew, err)
		}
		s.Touch(m, text, "text")
	}
	if isNew, _ := s.PutMessage(&Msg{Chat: "a@s.whatsapp.net", ID: "two", Ts: 1001, Kind: "text", Text: "two (edited)", Edited: true}); isNew {
		t.Error("putting the same ID again should replace, not add")
	}
	ms, _ := s.Messages("a@s.whatsapp.net", 0, 10)
	if len(ms) != 3 || ms[0].ID != "one" || ms[1].Text != "two (edited)" || !ms[1].Edited {
		t.Fatalf("messages = %+v", ms)
	}
	older, _ := s.Messages("a@s.whatsapp.net", 1002, 10)
	if len(older) != 2 {
		t.Errorf("before 1002: %d messages", len(older))
	}
	c, _ := s.Chat("a@s.whatsapp.net")
	if c.Preview != "three" || c.LastTs != 1002 {
		t.Errorf("chat preview = %q at %d", c.Preview, c.LastTs)
	}
	m, _ := s.SetStatus("a@s.whatsapp.net", "one", StatusRead)
	if m.Status != StatusRead {
		t.Error("status not set")
	}
	m, _ = s.SetStatus("a@s.whatsapp.net", "one", StatusDelivered)
	if m.Status != StatusRead {
		t.Error("a late delivery receipt must not undo read")
	}
	found, _ := s.Search("thr", 10)
	if len(found) != 1 || found[0].ID != "three" {
		t.Errorf("search = %+v", found)
	}
	s.AddUnread("a@s.whatsapp.net", 2)
	if s.TotalUnread() != 2 {
		t.Errorf("unread = %d", s.TotalUnread())
	}
}
