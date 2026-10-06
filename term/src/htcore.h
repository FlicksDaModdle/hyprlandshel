#pragma once

// The terminal emulation, from core/ (Rust): alacritty_terminal — the
// parser and grid Alacritty runs on — behind a C interface. See
// core/src/lib.rs for what each call does.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define HT_MAX_CHARS 6

typedef struct HtCore HtCore;

typedef struct HtCell {
    uint32_t chars[HT_MAX_CHARS];   // 0-terminated; chars[0] == 0 is blank
    uint32_t fg, bg;                // 0xRRGGBB
    uint8_t width;                  // 0: the second half of a wide one
    uint8_t fg_default, bg_default; // the theme's own, resolved at paint
    uint8_t bold, italic, underline, strike, reverse, conceal, dim;
} HtCell;

typedef struct HtState {
    int32_t rows, cols, history;
    int32_t cursor_row, cursor_col;
    uint8_t cursor_visible;
    uint8_t cursor_shape;           // 1 block, 2 underline, 3 bar
    uint8_t cursor_blink;
    uint8_t alt_screen, mouse, bracketed_paste, focus_events;
} HtState;

enum {
    HT_EV_WRITE = 1,     // bytes for the pty
    HT_EV_TITLE = 2,     // empty: back to the default
    HT_EV_BELL = 3,
    HT_EV_CWD = 4,       // a path, from OSC 7
    HT_EV_CLIPBOARD = 5, // OSC 52: text a program copied
};

enum {
    HT_KEY_ENTER = 1, HT_KEY_TAB, HT_KEY_BACKSPACE, HT_KEY_ESCAPE,
    HT_KEY_UP, HT_KEY_DOWN, HT_KEY_LEFT, HT_KEY_RIGHT,
    HT_KEY_INSERT, HT_KEY_DELETE, HT_KEY_HOME, HT_KEY_END,
    HT_KEY_PAGE_UP, HT_KEY_PAGE_DOWN, HT_KEY_BACKTAB,
    HT_KEY_F0 = 100,     // F1 is HT_KEY_F0 + 1, up to F20
};
enum { HT_MOD_SHIFT = 1, HT_MOD_ALT = 2, HT_MOD_CTRL = 4 };

typedef void (*HtCallback)(void *user, int32_t kind, const uint8_t *data, size_t len);

HtCore *ht_new(int32_t rows, int32_t cols);
void ht_free(HtCore *c);
void ht_set_callback(HtCore *c, HtCallback cb, void *user);
void ht_set_palette(HtCore *c, uint32_t fg, uint32_t bg, const uint32_t *ansi16);
void ht_feed(HtCore *c, const uint8_t *data, size_t len);
int64_t ht_sync_wait(HtCore *c);
void ht_sync_flush(HtCore *c);
int64_t ht_take_scrolled(HtCore *c);
void ht_resize(HtCore *c, int32_t rows, int32_t cols, int32_t cell_w, int32_t cell_h);
void ht_state(HtCore *c, HtState *out);
bool ht_cell(HtCore *c, int32_t line, int32_t col, HtCell *out);
void ht_key(HtCore *c, int32_t key, int32_t mods, const uint8_t *text, size_t len);
void ht_mouse(HtCore *c, int32_t row, int32_t col, int32_t button, bool pressed, int32_t mods);
void ht_paste(HtCore *c, const uint8_t *text, size_t len);
void ht_focus(HtCore *c, bool focused);

#ifdef __cplusplus
}
#endif
