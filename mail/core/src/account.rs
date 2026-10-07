// An account: where its mail is and how to sign in. Everything here is
// safe to keep in the database; passwords and refresh tokens are in the
// keyring (secrets.rs).

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

fn yes() -> bool {
    true
}
fn sixty() -> u32 {
    60
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Account {
    pub id: String,
    /// What the sidebar calls it: "School", "Personal".
    pub name: String,
    pub email: String,
    /// The name mail is sent from.
    pub display_name: String,
    /// gmail | outlook | imap — the provider's own habits (which folders it
    /// has, whether it files sent mail itself).
    pub provider: String,
    pub imap_host: String,
    pub imap_port: u16,
    /// tls | starttls | none (none only to this machine)
    pub imap_security: String,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_security: String,
    pub username: String,
    /// password | oauth
    pub auth: String,
    /// google | microsoft
    pub oauth_provider: String,
    pub signature: String,
    pub color: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// How far back to keep mail here, in days.
    #[serde(default = "sixty")]
    pub sync_days: u32,
}

impl Account {
    pub fn login(&self) -> &str {
        if self.username.is_empty() {
            &self.email
        } else {
            &self.username
        }
    }

    /// Whether the server files a copy of what is sent by SMTP itself, so
    /// appending one to Sent would make two.
    pub fn server_saves_sent(&self) -> bool {
        let h = self.smtp_host.to_ascii_lowercase();
        self.provider == "gmail"
            || self.provider == "outlook"
            || h.ends_with("gmail.com")
            || h.ends_with("googlemail.com")
            || h.contains("office365.com")
            || h.contains("outlook.com")
    }

    pub fn is_local_host(host: &str) -> bool {
        matches!(host, "localhost" | "127.0.0.1" | "::1")
    }
}

/// Server settings for the providers that need no looking up.
pub fn preset(provider: &str) -> Option<Value> {
    match provider {
        "gmail" => Some(json!({
            "provider": "gmail",
            "imapHost": "imap.gmail.com", "imapPort": 993, "imapSecurity": "tls",
            "smtpHost": "smtp.gmail.com", "smtpPort": 465, "smtpSecurity": "tls",
            "oauthProvider": "google",
        })),
        "outlook" => Some(json!({
            "provider": "outlook",
            "imapHost": "outlook.office365.com", "imapPort": 993, "imapSecurity": "tls",
            "smtpHost": "smtp-mail.outlook.com", "smtpPort": 587, "smtpSecurity": "starttls",
            "oauthProvider": "microsoft", "auth": "oauth",
        })),
        _ => None,
    }
}

/// Server settings for an address: the provider's own if its domain or its
/// mail exchanger says who it is (a school on Google Workspace or Microsoft
/// 365 is, for this purpose, Gmail or Outlook), else Thunderbird's database
/// of providers, else the usual guesses.
pub async fn autoconfig(email: &str) -> Value {
    let domain = email.rsplit('@').next().unwrap_or("").trim().to_ascii_lowercase();
    if domain.is_empty() {
        return json!({ "found": false });
    }
    if matches!(domain.as_str(), "gmail.com" | "googlemail.com") {
        let mut v = preset("gmail").unwrap();
        v["found"] = json!(true);
        v["auth"] = json!("password");
        return v;
    }
    if matches!(domain.as_str(), "outlook.com" | "hotmail.com" | "live.com" | "msn.com")
        || domain.starts_with("outlook.")
        || domain.starts_with("hotmail.")
    {
        let mut v = preset("outlook").unwrap();
        v["found"] = json!(true);
        return v;
    }

    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
    {
        Ok(c) => c,
        Err(_) => return guess(&domain),
    };

    // Who handles its mail.
    let mx = client
        .get(format!("https://dns.google/resolve?name={}&type=MX", domain))
        .send()
        .await
        .ok();
    let mx_text = match mx {
        Some(r) => r.text().await.unwrap_or_default().to_ascii_lowercase(),
        None => String::new(),
    };
    if mx_text.contains("google.com") || mx_text.contains("googlemail.com") {
        let mut v = preset("gmail").unwrap();
        v["found"] = json!(true);
        v["hosted"] = json!("google");
        v["auth"] = json!("oauth");
        return v;
    }
    if mx_text.contains("protection.outlook.com") || mx_text.contains("outlook.com") {
        let mut v = preset("outlook").unwrap();
        v["found"] = json!(true);
        v["hosted"] = json!("microsoft");
        v["smtpHost"] = json!("smtp.office365.com");
        return v;
    }

    // Microsoft's own answer: is this domain a Microsoft 365 organisation?
    // Catches the schools and companies whose mail passes through a filter
    // (Proofpoint, Mimecast, the university's own relay) first, which hides
    // Microsoft from the MX record.
    if let Ok(r) = client
        .get(format!(
            "https://login.microsoftonline.com/getuserrealm.srf?login={}&json=1",
            email.replace('+', "%2B")
        ))
        .send()
        .await
    {
        if let Ok(v) = r.json::<Value>().await {
            let kind = v.get("NameSpaceType").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "Managed" || kind == "Federated" {
                let mut out = preset("outlook").unwrap();
                out["found"] = json!(true);
                out["hosted"] = json!("microsoft");
                out["smtpHost"] = json!("smtp.office365.com");
                if let Some(org) = v.get("FederationBrandName").and_then(|x| x.as_str()) {
                    out["organisation"] = json!(org);
                }
                return out;
            }
        }
    }

    // Thunderbird's provider database.
    for url in [
        format!("https://autoconfig.thunderbird.net/v1.1/{}", domain),
        format!("https://autoconfig.{}/mail/config-v1.1.xml?emailaddress={}", domain, email),
    ] {
        if let Ok(r) = client.get(&url).send().await {
            if r.status().is_success() {
                if let Ok(xml) = r.text().await {
                    if let Some(v) = parse_ispdb(&xml, email) {
                        return v;
                    }
                }
            }
        }
    }
    guess(&domain)
}

fn guess(domain: &str) -> Value {
    json!({
        "found": false, "provider": "imap",
        "imapHost": format!("imap.{}", domain), "imapPort": 993, "imapSecurity": "tls",
        "smtpHost": format!("smtp.{}", domain), "smtpPort": 587, "smtpSecurity": "starttls",
        "auth": "password",
    })
}

/// The first IMAP and SMTP servers in a Thunderbird autoconfig document.
fn parse_ispdb(xml: &str, email: &str) -> Option<Value> {
    fn server<'a>(xml: &'a str, tag: &str, kind: &str) -> Option<&'a str> {
        let mut rest = xml;
        while let Some(i) = rest.find(&format!("<{}", tag)) {
            let after = &rest[i..];
            let end = after.find(&format!("</{}>", tag))?;
            let block = &after[..end];
            if block.contains(&format!("type=\"{}\"", kind)) {
                return Some(block);
            }
            rest = &after[end..];
        }
        None
    }
    fn field(block: &str, name: &str) -> String {
        let open = format!("<{}>", name);
        block
            .find(&open)
            .and_then(|i| {
                let s = &block[i + open.len()..];
                s.find('<').map(|j| s[..j].trim().to_string())
            })
            .unwrap_or_default()
    }
    let local = email.split('@').next().unwrap_or("");
    let domain = email.rsplit('@').next().unwrap_or("");
    let subst = |s: String| {
        s.replace("%EMAILADDRESS%", email)
            .replace("%EMAILLOCALPART%", local)
            .replace("%EMAILDOMAIN%", domain)
    };
    let sec = |s: String| match s.as_str() {
        "SSL" => "tls",
        "STARTTLS" => "starttls",
        _ => "none",
    };
    let imap = server(xml, "incomingServer", "imap")?;
    let smtp = server(xml, "outgoingServer", "smtp")?;
    let oauth = imap.contains("OAuth2");
    Some(json!({
        "found": true, "provider": "imap",
        "imapHost": subst(field(imap, "hostname")),
        "imapPort": field(imap, "port").parse::<u16>().unwrap_or(993),
        "imapSecurity": sec(field(imap, "socketType")),
        "smtpHost": subst(field(smtp, "hostname")),
        "smtpPort": field(smtp, "port").parse::<u16>().unwrap_or(587),
        "smtpSecurity": sec(field(smtp, "socketType")),
        "username": subst(field(imap, "username")),
        "auth": if oauth { "oauth" } else { "password" },
    }))
}
