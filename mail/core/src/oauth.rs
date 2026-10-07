// Signing in with Google or Microsoft (OAuth 2.0 for installed apps).
//
// The browser is sent to the provider's own sign-in page; the provider sends
// it back to a one-off listener on this machine (the "loopback" redirect)
// with a code, which is exchanged for tokens. PKCE ties the exchange to this
// request, so a code seen by anything else is useless. The refresh token is
// kept in the keyring; access tokens, which last an hour, only in memory.
//
// Both providers want an app registration — a client ID — which you make
// once, for free, in their consoles (see the README). Google's "desktop"
// clients also come with a "secret" that is, by Google's own description,
// not secret in an installed app; it is stored with the ID.

use crate::secrets;
use base64::Engine;
use serde_json::{json, Value};
use sha2::Digest;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

pub struct Provider {
    pub auth_url: String,
    pub token_url: String,
    pub scope: &'static str,
    /// Microsoft matches its registered "http://localhost" redirect on the
    /// name; Google wants the address.
    pub host: &'static str,
    pub extra: &'static str,
}

pub fn provider(name: &str) -> Option<Provider> {
    // For tests: a stand-in for both providers' endpoints.
    let base = std::env::var("HYPRSHELL_MAIL_OAUTH_BASE").ok();
    match name {
        "google" => Some(Provider {
            auth_url: base.as_ref().map(|b| format!("{}/auth", b))
                .unwrap_or_else(|| "https://accounts.google.com/o/oauth2/v2/auth".into()),
            token_url: base.as_ref().map(|b| format!("{}/token", b))
                .unwrap_or_else(|| "https://oauth2.googleapis.com/token".into()),
            scope: "https://mail.google.com/ openid email",
            host: "127.0.0.1",
            extra: "&access_type=offline&prompt=consent",
        }),
        "microsoft" => Some(Provider {
            auth_url: base.as_ref().map(|b| format!("{}/auth", b)).unwrap_or_else(|| {
                "https://login.microsoftonline.com/common/oauth2/v2.0/authorize".into()
            }),
            token_url: base.as_ref().map(|b| format!("{}/token", b)).unwrap_or_else(|| {
                "https://login.microsoftonline.com/common/oauth2/v2.0/token".into()
            }),
            scope: "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access openid email",
            host: "localhost",
            extra: "&prompt=select_account",
        }),
        _ => None,
    }
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn random_token() -> String {
    let bytes: [u8; 32] = rand::random();
    b64url(&bytes)
}

fn pct(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn unpct(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// The address an ID token was issued for — read, not verified: it is only
/// for filling in the form, and the token itself came straight from the
/// provider over TLS.
fn email_from_id_token(t: &str) -> Option<String> {
    let payload = t.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get("email")
        .or_else(|| v.get("preferred_username"))
        .and_then(|e| e.as_str())
        .map(|s| s.to_string())
}

pub struct Flow {
    pub url: String,
    listener: tokio::net::TcpListener,
    redirect: String,
    verifier: String,
    state: String,
    provider: Provider,
    client_id: String,
    client_secret: String,
}

/// Starts a sign-in: the URL to open, and what to wait on.
pub async fn begin(provider_name: &str, client_id: &str, client_secret: &str, hint: &str) -> Result<Flow, String> {
    let provider = provider(provider_name).ok_or("No such sign-in provider")?;
    if client_id.trim().is_empty() {
        return Err("A client ID is needed to sign in — see Mail's README for how to make one".into());
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect = format!("http://{}:{}", provider.host, port);
    let verifier = random_token();
    let challenge = b64url(sha2::Sha256::digest(verifier.as_bytes()).as_slice());
    let state = random_token();
    let mut url = format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&state={}&code_challenge={}&code_challenge_method=S256{}",
        provider.auth_url,
        pct(client_id.trim()),
        pct(&redirect),
        pct(provider.scope),
        state,
        challenge,
        provider.extra
    );
    if !hint.is_empty() {
        url.push_str(&format!("&login_hint={}", pct(hint)));
    }
    Ok(Flow {
        url,
        listener,
        redirect,
        verifier,
        state,
        provider,
        client_id: client_id.trim().to_string(),
        client_secret: client_secret.trim().to_string(),
    })
}

const DONE_PAGE: &str = "<!doctype html><meta charset=utf-8><title>Signed in</title>\
<body style=\"font:16px system-ui;display:grid;place-items:center;height:90vh;color:#333\">\
<div><h2>You're signed in.</h2><p>You can close this tab and go back to Mail.</p></div>";
const FAIL_PAGE: &str = "<!doctype html><meta charset=utf-8><title>Not signed in</title>\
<body style=\"font:16px system-ui;display:grid;place-items:center;height:90vh;color:#333\">\
<div><h2>Sign-in didn't finish.</h2><p>Go back to Mail to try again.</p></div>";

pub struct Tokens {
    pub access: String,
    pub expires: i64,
    pub refresh: Option<String>,
    pub email: Option<String>,
}

/// Waits (up to ten minutes) for the browser to come back, and exchanges
/// the code for tokens.
pub async fn finish(flow: Flow) -> Result<Tokens, String> {
    let accept = tokio::time::timeout(Duration::from_secs(600), async {
        loop {
            let (mut sock, _) = flow.listener.accept().await.map_err(|e| e.to_string())?;
            let mut buf = vec![0u8; 8192];
            let n = sock.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            let line = req.lines().next().unwrap_or("");
            let path = line.split_whitespace().nth(1).unwrap_or("");
            let query = path.split_once('?').map(|(_, q)| q).unwrap_or("");
            let mut code = None;
            let mut state = None;
            let mut error = None;
            for kv in query.split('&') {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                match k {
                    "code" => code = Some(unpct(v)),
                    "state" => state = Some(unpct(v)),
                    "error" => error = Some(unpct(v)),
                    _ => {}
                }
            }
            // A favicon request, or anything else that is not the answer.
            if code.is_none() && error.is_none() {
                let _ = sock.write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                continue;
            }
            let ok = code.is_some() && state.as_deref() == Some(flow.state.as_str());
            let page = if ok { DONE_PAGE } else { FAIL_PAGE };
            let _ = sock
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        page.len(),
                        page
                    )
                    .as_bytes(),
                )
                .await;
            if let Some(e) = error {
                return Err(format!("The provider said: {}", e));
            }
            if !ok {
                return Err("The sign-in answer did not match this request".to_string());
            }
            return Ok(code.unwrap());
        }
    })
    .await
    .map_err(|_| "Sign-in timed out".to_string())??;

    let mut form = vec![
        ("grant_type", "authorization_code".to_string()),
        ("code", accept),
        ("redirect_uri", flow.redirect.clone()),
        ("client_id", flow.client_id.clone()),
        ("code_verifier", flow.verifier.clone()),
    ];
    if !flow.client_secret.is_empty() {
        form.push(("client_secret", flow.client_secret.clone()));
    }
    token_request(&flow.provider.token_url, &form).await
}

async fn token_request(url: &str, form: &[(&str, String)]) -> Result<Tokens, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client.post(url).form(form).send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let v: Value = resp.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let code = v.get("error").and_then(|e| e.as_str()).unwrap_or("");
        let said = v
            .get("error_description")
            .or_else(|| v.get("error"))
            .and_then(|e| e.as_str())
            .unwrap_or("The token request was refused");
        // The sign-in itself is over — expired, revoked, a password change,
        // or an organisation that asks for a fresh sign-in every so often
        // (a school's "sign in again every 12 hours"). Retrying can't help;
        // signing in again does. Microsoft's own words follow, first line.
        if matches!(code, "invalid_grant" | "interaction_required" | "consent_required" | "login_required") {
            let first = said.lines().next().unwrap_or(said);
            return Err(format!("Signed out — sign in again from the account's settings. ({})", first));
        }
        return Err(said.to_string());
    }
    let access = v.get("access_token").and_then(|t| t.as_str()).ok_or("No access token in the answer")?;
    let expires_in = v.get("expires_in").and_then(|t| t.as_i64()).unwrap_or(3600);
    Ok(Tokens {
        access: access.to_string(),
        expires: crate::db::now() + expires_in - 60,
        refresh: v.get("refresh_token").and_then(|t| t.as_str()).map(|s| s.to_string()),
        email: v.get("id_token").and_then(|t| t.as_str()).and_then(email_from_id_token),
    })
}

/// A fresh access token from the stored refresh token.
pub async fn refresh(account: &str, provider_name: &str, client_id: &str, client_secret: &str) -> Result<Tokens, String> {
    let provider = provider(provider_name).ok_or("No such sign-in provider")?;
    let refresh = secrets::load(account, "refresh")
        .await?
        .ok_or("Signed out — sign in again from Mail's account settings")?;
    let mut form = vec![
        ("grant_type", "refresh_token".to_string()),
        ("refresh_token", refresh),
        ("client_id", client_id.to_string()),
    ];
    if !client_secret.is_empty() {
        form.push(("client_secret", client_secret.to_string()));
    }
    let t = token_request(&provider.token_url, &form).await?;
    // Microsoft hands out a new refresh token with each use.
    if let Some(r) = &t.refresh {
        secrets::store(account, "refresh", r).await?;
    }
    Ok(t)
}

/// XOAUTH2, as IMAP and SMTP both take it.
pub fn xoauth2(user: &str, token: &str) -> String {
    format!("user={}\x01auth=Bearer {}\x01\x01", user, token)
}

pub fn describe(tokens: &Tokens) -> Value {
    json!({ "email": tokens.email })
}
