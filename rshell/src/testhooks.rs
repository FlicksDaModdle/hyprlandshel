//! What the automated tests (tools/test) need of the shell, and nothing
//! else gets: a clock that stands still, PAM and face unlock stood in for.
//! Only in a build made with `--features test-hooks` (which the tests make
//! for themselves, in a target folder of their own); in every other build
//! these are fixed to the real thing, so no environment variable can change
//! how the lock screen checks a password.

/// The time it is: the real one, or HYPRSHELL_TEST_CLOCK (seconds since the
/// epoch) in a test build.
pub fn now() -> libc::time_t {
    #[cfg(feature = "test-hooks")]
    if let Some(t) = std::env::var("HYPRSHELL_TEST_CLOCK").ok().and_then(|v| v.parse().ok()) {
        return t;
    }
    // SAFETY: time() with a null pointer only returns the time.
    unsafe { libc::time(std::ptr::null_mut()) }
}

/// The program a PAM attempt runs: this one, or a stand-in in a test build.
pub fn pam_helper() -> Option<std::path::PathBuf> {
    #[cfg(feature = "test-hooks")]
    if let Some(p) = std::env::var_os("HYPRSHELL_TEST_PAM") {
        return Some(p.into());
    }
    Some(own_exe())
}

/// This running program, as something that can be started again. Not
/// `current_exe()`: when the file on disk is replaced while the shell runs (an
/// update, a rebuild), that says "…/hyprshell-rs (deleted)", which cannot be
/// started, and the lock screen then had no way to check a password ("Could
/// not start authentication"). /proc/self/exe always names the program that is
/// running, whatever has happened to its file.
pub fn own_exe() -> std::path::PathBuf {
    let proc = std::path::PathBuf::from("/proc/self/exe");
    if proc.exists() {
        proc
    } else {
        std::env::current_exe().unwrap_or_else(|_| "hyprshell-rs".into())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_helper_is_started_from_the_running_program_not_a_path_that_may_be_gone() {
        assert_eq!(super::own_exe(), std::path::PathBuf::from("/proc/self/exe"));
        // And that does start a program: this one, as a child.
        let out = std::process::Command::new(super::own_exe()).arg("--list").output();
        assert!(out.is_ok(), "it can be started: {out:?}");
    }
}

/// Face unlock set up, as a test says (HYPRSHELL_TEST_FACE=1 or 0); None
/// to look at the real PAM file.
pub fn face() -> Option<bool> {
    #[cfg(feature = "test-hooks")]
    if let Ok(v) = std::env::var("HYPRSHELL_TEST_FACE") {
        return Some(v == "1");
    }
    None
}
