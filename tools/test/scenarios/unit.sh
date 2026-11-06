# The parts with no screen: each crate's own tests (cargo test).

test_kit() {
    ( cd "$REPO/apps" && CARGO_TARGET_DIR="$TT_CACHE/target" cargo test -q -p hyprshell-kit ) > "$TT_DIR/cargo.txt" 2>&1 \
        || fail "hyprshell-kit: $(grep -m1 -E 'panicked|FAILED|error' "$TT_DIR/cargo.txt")"
}

test_settings() {
    ( cd "$REPO/apps" && CARGO_TARGET_DIR="$TT_CACHE/target" cargo test -q -p hyprshell-settings ) > "$TT_DIR/cargo.txt" 2>&1 \
        || fail "Settings: $(grep -m1 -E 'panicked|FAILED|error' "$TT_DIR/cargo.txt")"
}

test_rshell() {
    ( cd "$REPO/rshell" && CARGO_TARGET_DIR="$TT_CACHE/target" cargo test -q --features test-hooks ) > "$TT_DIR/cargo.txt" 2>&1 \
        || fail "the Rust shell: $(grep -m1 -E 'panicked|FAILED|error' "$TT_DIR/cargo.txt")"
}
