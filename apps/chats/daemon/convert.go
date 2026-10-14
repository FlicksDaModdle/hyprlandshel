package main

// What a WhatsApp message says, in the daemon's terms: a kind, its text,
// its media's details and what it was replying to.

import (
	"fmt"
	"strings"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
)

type content struct {
	kind  string
	text  string
	media *Media
	ctx   *waE2E.ContextInfo
	thumb []byte // a JPEG preview carried in the message itself
}

func extract(m *waE2E.Message) content {
	if m == nil {
		return content{kind: "unsupported"}
	}
	switch {
	case m.GetConversation() != "":
		return content{kind: "text", text: m.GetConversation()}
	case m.ExtendedTextMessage != nil:
		x := m.ExtendedTextMessage
		return content{kind: "text", text: x.GetText(), ctx: x.GetContextInfo()}
	case m.ImageMessage != nil:
		x := m.ImageMessage
		return content{kind: "image", text: x.GetCaption(), ctx: x.GetContextInfo(), thumb: x.GetJPEGThumbnail(),
			media: &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Width: int(x.GetWidth()), Height: int(x.GetHeight())}}
	case m.VideoMessage != nil:
		x := m.VideoMessage
		kind := "video"
		if x.GetGifPlayback() {
			kind = "gif"
		}
		return content{kind: kind, text: x.GetCaption(), ctx: x.GetContextInfo(), thumb: x.GetJPEGThumbnail(),
			media: &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Width: int(x.GetWidth()), Height: int(x.GetHeight()), Seconds: int(x.GetSeconds())}}
	case m.PtvMessage != nil:
		x := m.PtvMessage
		return content{kind: "video", text: x.GetCaption(), ctx: x.GetContextInfo(), thumb: x.GetJPEGThumbnail(),
			media: &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Width: int(x.GetWidth()), Height: int(x.GetHeight()), Seconds: int(x.GetSeconds())}}
	case m.AudioMessage != nil:
		x := m.AudioMessage
		kind := "audio"
		if x.GetPTT() {
			kind = "voice"
		}
		md := &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Seconds: int(x.GetSeconds())}
		for _, b := range x.GetWaveform() {
			md.Waveform = append(md.Waveform, int(b))
		}
		return content{kind: kind, ctx: x.GetContextInfo(), media: md}
	case m.DocumentMessage != nil:
		x := m.DocumentMessage
		name := x.GetFileName()
		if name == "" {
			name = x.GetTitle()
		}
		return content{kind: "document", text: x.GetCaption(), ctx: x.GetContextInfo(), thumb: x.GetJPEGThumbnail(),
			media: &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Name: name}}
	case m.StickerMessage != nil:
		x := m.StickerMessage
		return content{kind: "sticker", ctx: x.GetContextInfo(),
			media: &Media{Mime: x.GetMimetype(), Size: int64(x.GetFileLength()), Width: int(x.GetWidth()), Height: int(x.GetHeight())}}
	case m.LocationMessage != nil:
		x := m.LocationMessage
		t := strings.TrimSpace(x.GetName() + "\n" + x.GetAddress())
		if t == "" {
			t = fmt.Sprintf("%.5f, %.5f", x.GetDegreesLatitude(), x.GetDegreesLongitude())
		}
		return content{kind: "location", text: t + fmt.Sprintf("\nhttps://maps.google.com/?q=%f,%f", x.GetDegreesLatitude(), x.GetDegreesLongitude()),
			ctx: x.GetContextInfo(), thumb: x.GetJPEGThumbnail()}
	case m.LiveLocationMessage != nil:
		x := m.LiveLocationMessage
		return content{kind: "location", text: fmt.Sprintf("Live location\nhttps://maps.google.com/?q=%f,%f", x.GetDegreesLatitude(), x.GetDegreesLongitude()), ctx: x.GetContextInfo()}
	case m.ContactMessage != nil:
		return content{kind: "contact", text: m.ContactMessage.GetDisplayName(), ctx: m.ContactMessage.GetContextInfo()}
	case m.ContactsArrayMessage != nil:
		var names []string
		for _, c := range m.ContactsArrayMessage.GetContacts() {
			names = append(names, c.GetDisplayName())
		}
		return content{kind: "contact", text: strings.Join(names, ", "), ctx: m.ContactsArrayMessage.GetContextInfo()}
	case m.PollCreationMessage != nil || m.PollCreationMessageV2 != nil || m.PollCreationMessageV3 != nil:
		p := m.PollCreationMessage
		if p == nil {
			p = m.PollCreationMessageV2
		}
		if p == nil {
			p = m.PollCreationMessageV3
		}
		t := p.GetName()
		for _, o := range p.GetOptions() {
			t += "\n○ " + o.GetOptionName()
		}
		return content{kind: "poll", text: t, ctx: p.GetContextInfo()}
	case m.EventMessage != nil:
		return content{kind: "event", text: m.EventMessage.GetName(), ctx: m.EventMessage.GetContextInfo()}
	case m.GroupInviteMessage != nil:
		return content{kind: "invite", text: "Invitation to join " + m.GroupInviteMessage.GetGroupName()}
	case m.ButtonsMessage != nil:
		return content{kind: "text", text: m.ButtonsMessage.GetContentText()}
	case m.TemplateMessage != nil && m.TemplateMessage.GetHydratedTemplate() != nil:
		return content{kind: "text", text: m.TemplateMessage.GetHydratedTemplate().GetHydratedContentText()}
	case m.ListMessage != nil:
		return content{kind: "text", text: m.ListMessage.GetDescription()}
	case m.ViewOnceMessage != nil:
		return extract(m.ViewOnceMessage.GetMessage())
	case m.ViewOnceMessageV2 != nil:
		return extract(m.ViewOnceMessageV2.GetMessage())
	case m.EphemeralMessage != nil:
		return extract(m.EphemeralMessage.GetMessage())
	case m.DocumentWithCaptionMessage != nil:
		return extract(m.DocumentWithCaptionMessage.GetMessage())
	}
	return content{kind: "unsupported"}
}

// The one line a chat list shows for a message.
func previewOf(kind, text string, media *Media) string {
	first := strings.SplitN(strings.TrimSpace(text), "\n", 2)[0]
	switch kind {
	case "text", "poll", "event", "invite", "contact", "location":
		if first != "" {
			return first
		}
	}
	label := map[string]string{
		"image": "Photo", "video": "Video", "gif": "GIF", "voice": "Voice message", "audio": "Audio",
		"document": "Document", "sticker": "Sticker", "location": "Location", "contact": "Contact",
		"poll": "Poll", "event": "Event", "deleted": "This message was deleted",
		"unsupported": "Message not supported here", "waiting": "Waiting for this message",
	}[kind]
	if kind == "document" && media != nil && media.Name != "" {
		label = media.Name
	}
	if (kind == "voice" || kind == "audio" || kind == "video") && media != nil && media.Seconds > 0 {
		label += fmt.Sprintf(" (%d:%02d)", media.Seconds/60, media.Seconds%60)
	}
	if first != "" && (kind == "image" || kind == "video" || kind == "gif" || kind == "document") {
		return first
	}
	if label == "" {
		label = first
	}
	return label
}

// Every message type with media to download, as whatsmeow takes it.
func mediaOf(m *waE2E.Message) whatsmeow.DownloadableMessage {
	if m == nil {
		return nil
	}
	switch {
	case m.ImageMessage != nil:
		return m.ImageMessage
	case m.VideoMessage != nil:
		return m.VideoMessage
	case m.PtvMessage != nil:
		return m.PtvMessage
	case m.AudioMessage != nil:
		return m.AudioMessage
	case m.DocumentMessage != nil:
		return m.DocumentMessage
	case m.StickerMessage != nil:
		return m.StickerMessage
	case m.ViewOnceMessage != nil:
		return mediaOf(m.ViewOnceMessage.GetMessage())
	case m.ViewOnceMessageV2 != nil:
		return mediaOf(m.ViewOnceMessageV2.GetMessage())
	case m.EphemeralMessage != nil:
		return mediaOf(m.EphemeralMessage.GetMessage())
	case m.DocumentWithCaptionMessage != nil:
		return mediaOf(m.DocumentWithCaptionMessage.GetMessage())
	}
	return nil
}

// A file name's extension for a MIME type, for what is saved.
func extFor(mime, kind string) string {
	mime = strings.ToLower(strings.TrimSpace(strings.SplitN(mime, ";", 2)[0]))
	switch mime {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "video/mp4":
		return ".mp4"
	case "video/3gpp":
		return ".3gp"
	case "audio/ogg":
		return ".ogg"
	case "audio/mpeg":
		return ".mp3"
	case "audio/mp4", "audio/aac":
		return ".m4a"
	case "application/pdf":
		return ".pdf"
	}
	switch kind {
	case "image":
		return ".jpg"
	case "video", "gif":
		return ".mp4"
	case "voice":
		return ".ogg"
	case "sticker":
		return ".webp"
	}
	return ""
}
