// hyprshell-chatsd: Chats' connection to WhatsApp.
//
// It is a linked device, like WhatsApp Web: it links by QR code (or a code
// typed on the phone), keeps the end-to-end encrypted session, stores the
// conversation and sends notifications, whether or not the Chats window is
// open. The window (hyprshell-chats) talks to it over a Unix socket; see
// server.go for what they say.
//
//	hyprshell-chatsd            run (the window starts it if it isn't running)
//	hyprshell-chatsd --demo     made-up chats and replies, no WhatsApp: for
//	                            trying the window out
//
// Everything is kept in ~/.local/share/hyprshell-chats, readable only by you:
// session.db is the linked device's keys, chats.db the messages, media/ and
// avatars/ the files.
package main

import (
	"flag"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func dataDir() string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "hyprshell-chats")
}

func runtimeDir() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return d
	}
	return os.TempDir()
}

func socketPath() string {
	if p := os.Getenv("HYPRSHELL_CHATS_SOCKET"); p != "" {
		return p
	}
	return filepath.Join(runtimeDir(), "hyprshell-chats.sock")
}

func umask(m int) int { return syscall.Umask(m) }

// The unread count, for the shell: a number in a file it can watch.
func writeUnread(n int) {
	p := filepath.Join(runtimeDir(), "hyprshell-chats.unread")
	tmp := p + ".tmp"
	if os.WriteFile(tmp, []byte(strconv.Itoa(n)+"\n"), 0o600) == nil {
		_ = os.Rename(tmp, p)
	}
}

func (s *Server) focusedNow() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns) > 0 && s.focused
}

// openChat: a notification was clicked. An open window goes to the chat;
// with none open, the window is started on it.
func (s *Server) openChat(chat string) {
	if s.HasWindow() {
		s.Emit(map[string]any{"ev": "open", "chat": chat})
		return
	}
	exe := "hyprshell-chats"
	if self, err := os.Executable(); err == nil {
		if p := filepath.Join(filepath.Dir(self), "hyprshell-chats"); fileExists(p) {
			exe = p
		}
	}
	cmd := exec.Command(exe, "--chat", chat)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err == nil {
		go cmd.Wait()
	}
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func main() {
	demo := flag.Bool("demo", os.Getenv("HYPRSHELL_CHATS_DEMO") != "", "made-up chats, no WhatsApp")
	dir := flag.String("data", "", "where to keep everything (default ~/.local/share/hyprshell-chats)")
	flag.Parse()
	// Keys, messages and media: nothing here is anyone else's to read.
	syscall.Umask(0o077)
	log.SetFlags(0)
	log.SetPrefix("hyprshell-chatsd: ")

	d := *dir
	if d == "" {
		d = dataDir()
		if *demo {
			d = filepath.Join(runtimeDir(), "hyprshell-chats-demo")
		}
	}
	if err := os.MkdirAll(d, 0o700); err != nil {
		log.Fatal(err)
	}
	_ = os.Chmod(d, 0o700)

	db := "chats.db"
	if *demo {
		_ = os.Remove(filepath.Join(d, db))
	}
	st, err := OpenStore(filepath.Join(d, db))
	if err != nil {
		log.Fatalf("opening the message store: %v", err)
	}
	_ = os.Chmod(filepath.Join(d, db), 0o600)

	srv := NewServer(st)
	if *demo {
		srv.be = NewDemo(srv, st, d)
	} else {
		wa, err := NewWA(srv, st, d)
		if err != nil {
			log.Fatalf("opening the WhatsApp session: %v", err)
		}
		srv.be = wa
	}
	srv.notify = NewNotifier(srv.openChat)

	sock := socketPath()
	if err := srv.Listen(sock); err != nil {
		if err == errAlreadyRunning {
			log.Printf("already running")
			return
		}
		log.Fatalf("listening on %s: %v", sock, err)
	}
	srv.be.Start()
	writeUnread(st.TotalUnread())

	// Nothing linked and no window open for a minute: nothing to do, so
	// don't sit there. (Linked, it stays, for the notifications.)
	go func() {
		idle := 0
		for range time.Tick(30 * time.Second) {
			if srv.be.State()["state"] == "pairing" && !srv.HasWindow() {
				idle++
			} else {
				idle = 0
			}
			if idle >= 2 {
				_ = os.Remove(sock)
				os.Exit(0)
			}
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	_ = os.Remove(sock)
}
