use std::{
    collections::HashMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;
use serde_json::Value;
use tokio::{io::AsyncWriteExt, process::Command, sync::Mutex, time::timeout};

use crate::{
    config::SlackConfig,
    model::{SlackChannel, SlackMessage, SlackNotification, SlackSnapshot},
};

const API_BASE: &str = "https://slack.com/api/";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const CHANNEL_DIRECTORY_TTL: Duration = Duration::from_secs(600);
const HISTORY_LIMIT: usize = 20;
// DMs are checked round-robin so a long DM list stays inside rate limits.
const DM_CHECKS_PER_SAMPLE: usize = 30;
const MENTION_LIMIT: usize = 10;
const MAX_NOTIFICATIONS: usize = 10;
const MAX_TEXT_CHARS: usize = 500;
const MAX_NAME_CHARS: usize = 48;
// Message subtypes that are conversation, not channel housekeeping.
const SHOWN_SUBTYPES: [&str; 4] = ["", "bot_message", "thread_broadcast", "file_share"];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenFile {
    token: String,
}

#[derive(Debug, Clone)]
struct Identity {
    user_id: String,
    /// Workspace URL from auth.test, e.g. `https://acme.slack.com/`.
    team_url: String,
}

#[derive(Debug, Default)]
struct SlackCache {
    identity: Option<Identity>,
    channel_ids: HashMap<String, String>,
    channel_ids_at: Option<Instant>,
    user_names: HashMap<String, String>,
    dm_cursor: usize,
    dm_unread: HashMap<String, SlackNotification>,
}

/// One Slack sample: the published snapshot plus the permalinks the daemon
/// keeps private and opens by id.
#[derive(Debug, Default)]
pub struct SlackSample {
    pub snapshot: SlackSnapshot,
    pub urls: HashMap<String, String>,
}

/// Reads watched channels, DMs, and @-mentions with the user's own Slack
/// user token through `curl`. Only fixed read-only Web API methods are used,
/// and the token reaches curl on stdin, never on its command line.
#[derive(Debug, Clone)]
pub struct SlackClient {
    config: SlackConfig,
    curl_bin: PathBuf,
    cache: Arc<Mutex<SlackCache>>,
}

impl SlackClient {
    pub fn new(config: SlackConfig) -> Self {
        Self::with_curl(config, "curl")
    }

    pub fn with_curl(config: SlackConfig, curl_bin: impl Into<PathBuf>) -> Self {
        Self {
            config,
            curl_bin: curl_bin.into(),
            cache: Arc::new(Mutex::new(SlackCache::default())),
        }
    }

    /// A missing token or a failing API is an unavailable snapshot; one
    /// unreadable channel only marks that channel.
    pub async fn sample(&self) -> SlackSample {
        let mut sample = SlackSample::default();
        let token = match self.config.token_file.as_deref().map(read_token) {
            Some(Ok(token)) => token,
            Some(Err(error)) => {
                tracing::debug!(%error, "Slack token unavailable");
                return sample;
            }
            None => return sample,
        };
        let api = Api {
            curl_bin: &self.curl_bin,
            token: &token,
        };
        let mut cache = self.cache.lock().await;
        let identity = match self.identity(&api, &mut cache).await {
            Ok(identity) => identity,
            Err(error) => {
                tracing::debug!(%error, "Slack auth.test failed");
                return sample;
            }
        };
        sample.snapshot.available = true;

        if let Err(error) = self.refresh_channel_directory(&api, &mut cache).await {
            tracing::debug!(%error, "Slack channel directory unavailable");
        }
        for name in &self.config.channels {
            let channel = match cache.channel_ids.get(name).cloned() {
                Some(id) => self
                    .channel(&api, &mut cache, &identity, name, &id, &mut sample.urls)
                    .await
                    .unwrap_or_else(|error| {
                        tracing::debug!(%error, channel = %name, "Slack channel unavailable");
                        unavailable_channel(name)
                    }),
                None => unavailable_channel(name),
            };
            sample.snapshot.channels.push(channel);
        }

        if let Err(error) = self.refresh_dms(&api, &mut cache).await {
            tracing::debug!(%error, "Slack DM check failed");
        }
        let mut notifications: Vec<_> = cache.dm_unread.values().cloned().collect();
        notifications.sort_by_key(|notification| std::cmp::Reverse(notification.at));
        match self.mentions(&api, &mut cache, &identity).await {
            Ok(mentions) => notifications.extend(mentions),
            Err(error) => tracing::debug!(%error, "Slack mention search failed"),
        }
        notifications.truncate(MAX_NOTIFICATIONS);
        for notification in &notifications {
            if let Some((channel, ts)) = notification.id.split_once('-') {
                sample
                    .urls
                    .insert(notification.id.clone(), permalink(&identity, channel, ts));
            }
        }
        sample.snapshot.notifications = notifications;
        sample
    }

    async fn identity(&self, api: &Api<'_>, cache: &mut SlackCache) -> Result<Identity> {
        if let Some(identity) = &cache.identity {
            return Ok(identity.clone());
        }
        let response = api.call("auth.test", &[]).await?;
        let user_id = response["user_id"]
            .as_str()
            .filter(|id| is_slack_id(id))
            .ok_or_else(|| anyhow!("auth.test returned no user"))?;
        let team_url = response["url"]
            .as_str()
            .filter(|url| is_workspace_url(url))
            .ok_or_else(|| anyhow!("auth.test returned no workspace URL"))?;
        let identity = Identity {
            user_id: user_id.to_owned(),
            team_url: team_url.to_owned(),
        };
        cache.identity = Some(identity.clone());
        Ok(identity)
    }

    async fn refresh_channel_directory(&self, api: &Api<'_>, cache: &mut SlackCache) -> Result<()> {
        let fresh = cache
            .channel_ids_at
            .is_some_and(|at| at.elapsed() < CHANNEL_DIRECTORY_TTL);
        let complete = self
            .config
            .channels
            .iter()
            .all(|name| cache.channel_ids.contains_key(name));
        if fresh && complete {
            return Ok(());
        }
        let mut ids = HashMap::new();
        let mut cursor = String::new();
        // A few pages covers every channel a person is in.
        for _ in 0..5 {
            let mut params = vec![
                ("types", "public_channel,private_channel"),
                ("exclude_archived", "true"),
                ("limit", "999"),
            ];
            if !cursor.is_empty() {
                params.push(("cursor", cursor.as_str()));
            }
            let response = api.call("users.conversations", &params).await?;
            for channel in response["channels"].as_array().into_iter().flatten() {
                if let (Some(id), Some(name)) = (channel["id"].as_str(), channel["name"].as_str())
                    && is_slack_id(id)
                {
                    ids.insert(name.to_owned(), id.to_owned());
                }
            }
            cursor = response["response_metadata"]["next_cursor"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            if cursor.is_empty() {
                break;
            }
        }
        cache.channel_ids = ids;
        cache.channel_ids_at = Some(Instant::now());
        Ok(())
    }

    async fn channel(
        &self,
        api: &Api<'_>,
        cache: &mut SlackCache,
        identity: &Identity,
        name: &str,
        id: &str,
        urls: &mut HashMap<String, String>,
    ) -> Result<SlackChannel> {
        let info = api.call("conversations.info", &[("channel", id)]).await?;
        let last_read = info["channel"]["last_read"]
            .as_str()
            .and_then(parse_ts)
            .unwrap_or(f64::MAX);
        let limit = HISTORY_LIMIT.to_string();
        let history = api
            .call(
                "conversations.history",
                &[("channel", id), ("limit", &limit)],
            )
            .await?;
        let raw: Vec<Value> = history["messages"].as_array().cloned().unwrap_or_default();
        let mut messages = Vec::new();
        let mut unread = 0;
        for message in &raw {
            let subtype = message["subtype"].as_str().unwrap_or_default();
            let Some(ts) = message["ts"].as_str().filter(|ts| parse_ts(ts).is_some()) else {
                continue;
            };
            if !SHOWN_SUBTYPES.contains(&subtype) {
                continue;
            }
            let at = parse_ts(ts).unwrap_or_default();
            let is_unread =
                at > last_read && message["user"].as_str() != Some(identity.user_id.as_str());
            if is_unread {
                unread += 1;
            }
            let author = self.author(api, cache, message).await;
            let text = self
                .render(api, cache, message["text"].as_str().unwrap_or(""))
                .await;
            let item_id = format!("{id}-{ts}");
            urls.insert(item_id.clone(), permalink(identity, id, ts));
            messages.push(SlackMessage {
                id: item_id,
                author,
                text,
                at: at as u64,
                replies: message["reply_count"].as_u64().unwrap_or(0).min(9_999) as u32,
                unread: is_unread,
            });
        }
        // History is newest first; the feed reads top to bottom, oldest first.
        messages.reverse();
        Ok(SlackChannel {
            name: bounded(name, MAX_NAME_CHARS),
            available: true,
            unread,
            unread_capped: !raw.is_empty() && unread == raw.len() as u32,
            messages,
        })
    }

    async fn refresh_dms(&self, api: &Api<'_>, cache: &mut SlackCache) -> Result<()> {
        let response = api
            .call(
                "users.conversations",
                &[
                    ("types", "im"),
                    ("exclude_archived", "true"),
                    ("limit", "200"),
                ],
            )
            .await?;
        let dms: Vec<(String, String)> = response["channels"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|dm| dm["is_user_deleted"].as_bool() != Some(true))
            .filter_map(|dm| {
                Some((
                    dm["id"].as_str().filter(|id| is_slack_id(id))?.to_owned(),
                    dm["user"].as_str().filter(|id| is_slack_id(id))?.to_owned(),
                ))
            })
            .collect();
        cache
            .dm_unread
            .retain(|id, _| dms.iter().any(|(dm, _)| id.starts_with(dm.as_str())));
        if dms.is_empty() {
            return Ok(());
        }
        let start = cache.dm_cursor % dms.len();
        for offset in 0..DM_CHECKS_PER_SAMPLE.min(dms.len()) {
            let (dm, user) = &dms[(start + offset) % dms.len()];
            let info = api.call("conversations.info", &[("channel", dm)]).await?;
            let channel = &info["channel"];
            let unread = channel["unread_count_display"].as_u64().unwrap_or(0);
            cache
                .dm_unread
                .retain(|id, _| !id.starts_with(&format!("{dm}-")));
            let latest = &channel["latest"];
            let Some(ts) = latest["ts"].as_str().filter(|ts| parse_ts(ts).is_some()) else {
                continue;
            };
            if unread == 0 {
                continue;
            }
            let name = self.user_name(api, cache, user).await;
            let text = self
                .render(api, cache, latest["text"].as_str().unwrap_or(""))
                .await;
            let id = format!("{dm}-{ts}");
            cache.dm_unread.insert(
                id.clone(),
                SlackNotification {
                    id,
                    kind: "dm".into(),
                    source: name.clone(),
                    author: name,
                    text,
                    at: parse_ts(ts).unwrap_or_default() as u64,
                    unread: unread.min(9_999) as u32,
                },
            );
        }
        cache.dm_cursor = (start + DM_CHECKS_PER_SAMPLE) % dms.len();
        Ok(())
    }

    async fn mentions(
        &self,
        api: &Api<'_>,
        cache: &mut SlackCache,
        identity: &Identity,
    ) -> Result<Vec<SlackNotification>> {
        let query = format!("<@{}>", identity.user_id);
        let count = MENTION_LIMIT.to_string();
        let response = api
            .call(
                "search.messages",
                &[("query", &query), ("sort", "timestamp"), ("count", &count)],
            )
            .await?;
        let mut mentions = Vec::new();
        for item in response["messages"]["matches"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let (Some(channel), Some(ts)) = (
                item["channel"]["id"].as_str().filter(|id| is_slack_id(id)),
                item["ts"].as_str().filter(|ts| parse_ts(ts).is_some()),
            ) else {
                continue;
            };
            let source = match item["channel"]["name"].as_str() {
                Some(name) if !name.starts_with('U') && !name.starts_with('D') => {
                    format!("#{}", bounded(name, MAX_NAME_CHARS))
                }
                _ => "DM".into(),
            };
            let author = self.author(api, cache, item).await;
            let text = self
                .render(api, cache, item["text"].as_str().unwrap_or(""))
                .await;
            mentions.push(SlackNotification {
                id: format!("{channel}-{ts}"),
                kind: "mention".into(),
                source,
                author,
                text,
                at: parse_ts(ts).unwrap_or_default() as u64,
                unread: 0,
            });
        }
        Ok(mentions)
    }

    async fn author(&self, api: &Api<'_>, cache: &mut SlackCache, message: &Value) -> String {
        if let Some(user) = message["user"].as_str().filter(|id| is_slack_id(id)) {
            return self.user_name(api, cache, user).await;
        }
        let fallback = message["username"]
            .as_str()
            .or_else(|| message["bot_profile"]["name"].as_str())
            .unwrap_or("Slack");
        bounded(fallback, MAX_NAME_CHARS)
    }

    async fn user_name(&self, api: &Api<'_>, cache: &mut SlackCache, user: &str) -> String {
        if let Some(name) = cache.user_names.get(user) {
            return name.clone();
        }
        let name = match api.call("users.info", &[("user", user)]).await {
            Ok(response) => {
                let profile = &response["user"]["profile"];
                [
                    profile["display_name"].as_str(),
                    profile["real_name"].as_str(),
                    response["user"]["name"].as_str(),
                ]
                .into_iter()
                .flatten()
                .find(|name| !name.trim().is_empty())
                .map(|name| bounded(name, MAX_NAME_CHARS))
                .unwrap_or_else(|| user.to_owned())
            }
            // Leave it uncached so the next sample retries.
            Err(_) => return user.to_owned(),
        };
        cache.user_names.insert(user.to_owned(), name.clone());
        name
    }

    /// Slack mrkdwn to plain text: user and channel references become names,
    /// links their labels, and HTML entities their characters.
    async fn render(&self, api: &Api<'_>, cache: &mut SlackCache, text: &str) -> String {
        let mut rendered = String::new();
        let mut rest = text;
        while let Some(start) = rest.find('<') {
            rendered.push_str(&rest[..start]);
            let Some(end) = rest[start..].find('>') else {
                rendered.push_str(&rest[start..]);
                rest = "";
                break;
            };
            let token = &rest[start + 1..start + end];
            let (target, label) = match token.split_once('|') {
                Some((target, label)) => (target, Some(label)),
                None => (token, None),
            };
            let replacement = if let Some(user) = target.strip_prefix('@') {
                if is_slack_id(user) {
                    format!("@{}", self.user_name(api, cache, user).await)
                } else {
                    format!("@{user}")
                }
            } else if let Some(channel) = target.strip_prefix('#') {
                format!("#{}", label.unwrap_or(channel))
            } else if let Some(special) = target.strip_prefix('!') {
                match label {
                    Some(label) => label.to_owned(),
                    None => format!("@{}", special.split('^').next().unwrap_or(special)),
                }
            } else {
                label.unwrap_or(target).to_owned()
            };
            rendered.push_str(&replacement);
            rest = &rest[start + end + 1..];
        }
        rendered.push_str(rest);
        let decoded = rendered
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&");
        bounded(&decoded, MAX_TEXT_CHARS)
    }
}

struct Api<'a> {
    curl_bin: &'a Path,
    token: &'a str,
}

impl Api<'_> {
    async fn call(&self, method: &str, params: &[(&str, &str)]) -> Result<Value> {
        let query = params
            .iter()
            .map(|(key, value)| format!("{key}={}", percent_encode(value)))
            .collect::<Vec<_>>()
            .join("&");
        // curl reads its URL and the Authorization header from a config on
        // stdin, so the token never appears in the process list.
        let config = format!(
            "url = \"{API_BASE}{method}?{query}\"\nheader = \"Authorization: Bearer {}\"\n",
            self.token
        );
        let mut child = Command::new(self.curl_bin)
            .args([
                "--silent",
                "--show-error",
                "--max-time",
                "15",
                "--config",
                "-",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("running {}", self.curl_bin.display()))?;
        let mut stdin = child.stdin.take().context("curl stdin unavailable")?;
        stdin.write_all(config.as_bytes()).await?;
        drop(stdin);
        let output = timeout(REQUEST_TIMEOUT, child.wait_with_output())
            .await
            .context("timed out waiting for Slack")??;
        if !output.status.success() {
            bail!("Slack request failed for {method}");
        }
        let response: Value =
            serde_json::from_slice(&output.stdout).context("parsing Slack response")?;
        if response["ok"].as_bool() != Some(true) {
            bail!(
                "Slack {method} error: {}",
                response["error"].as_str().unwrap_or("unknown")
            );
        }
        Ok(response)
    }
}

/// The token file must belong to the user alone and hold a user token.
fn read_token(path: &Path) -> Result<String> {
    let metadata = fs::metadata(path).with_context(|| format!("reading {}", path.display()))?;
    if metadata.permissions().mode() & 0o077 != 0 {
        bail!(
            "{} must be readable by its owner only (chmod 600)",
            path.display()
        );
    }
    let file: TokenFile = toml::from_str(&fs::read_to_string(path)?)
        .with_context(|| format!("parsing {}", path.display()))?;
    let valid = file.token.starts_with("xoxp-")
        && file.token.len() <= 256
        && file
            .token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-');
    if !valid {
        bail!("{} must hold a Slack user token (xoxp-...)", path.display());
    }
    Ok(file.token)
}

fn unavailable_channel(name: &str) -> SlackChannel {
    SlackChannel {
        name: bounded(name, MAX_NAME_CHARS),
        available: false,
        unread: 0,
        unread_capped: false,
        messages: Vec::new(),
    }
}

fn permalink(identity: &Identity, channel: &str, ts: &str) -> String {
    format!(
        "{}archives/{channel}/p{}",
        identity.team_url,
        ts.replace('.', "")
    )
}

fn parse_ts(ts: &str) -> Option<f64> {
    let (seconds, micros) = ts.split_once('.')?;
    let valid = !seconds.is_empty()
        && seconds.len() <= 12
        && micros.len() <= 8
        && seconds
            .bytes()
            .chain(micros.bytes())
            .all(|byte| byte.is_ascii_digit());
    valid.then(|| ts.parse().ok()).flatten()
}

fn is_slack_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 24
        && id
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

fn is_workspace_url(url: &str) -> bool {
    url.strip_prefix("https://")
        .and_then(|rest| rest.strip_suffix('/'))
        .and_then(|host| host.strip_suffix(".slack.com"))
        .is_some_and(|workspace| {
            !workspace.is_empty()
                && workspace
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
}

/// Only permalinks into the signed-in workspace are opened.
pub fn is_slack_url(url: &str) -> bool {
    url.len() <= 512
        && url
            .find("/archives/")
            .is_some_and(|split| is_workspace_url(&url[..=split]))
        && !url
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
}

fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

fn bounded(value: &str, limit: usize) -> String {
    value
        .chars()
        .filter(|character| *character == '\n' || !character.is_control())
        .take(limit)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // A stand-in curl that checks the token arrived on stdin and answers
    // each Web API method with recorded output.
    fn fake_curl(dir: &Path) -> PathBuf {
        let path = dir.join("curl");
        fs::write(
            &path,
            r#"#!/bin/sh
config=$(cat)
case "$config" in *"Bearer xoxp-1-test"*) ;; *) exit 22 ;; esac
case "$*" in *xoxp*) exit 23 ;; esac
url=$(printf '%s\n' "$config" | sed -n 's/^url = "\(.*\)"$/\1/p')
case "$url" in
  *auth.test*) echo '{"ok":true,"user_id":"UME","url":"https://acme.slack.com/"}' ;;
  *users.conversations*types=im*) echo '{"ok":true,"channels":[{"id":"D1","user":"UKARI"}]}' ;;
  *users.conversations*) echo '{"ok":true,"channels":[{"id":"CDEV","name":"dev"}],"response_metadata":{"next_cursor":""}}' ;;
  *conversations.info*channel=D1*) echo '{"ok":true,"channel":{"id":"D1","unread_count_display":2,"latest":{"ts":"1700000300.000200","text":"lunch?"}}}' ;;
  *conversations.info*) echo '{"ok":true,"channel":{"id":"CDEV","last_read":"1700000100.000100"}}' ;;
  *conversations.history*) echo '{"ok":true,"messages":[{"ts":"1700000200.000300","user":"UKARI","text":"hi <@UME> see <https://x.dev|docs> &amp; <#CDEV|dev>","reply_count":3},{"ts":"1700000150.000100","subtype":"channel_join","user":"UOLA","text":"joined"},{"ts":"1700000050.000100","user":"UME","text":"older"}]}' ;;
  *users.info*user=UKARI*) echo '{"ok":true,"user":{"name":"kari","profile":{"display_name":"Kari","real_name":"Kari N"}}}' ;;
  *users.info*user=UME*) echo '{"ok":true,"user":{"name":"me","profile":{"display_name":"","real_name":"Jon"}}}' ;;
  *search.messages*) echo '{"ok":true,"messages":{"matches":[{"channel":{"id":"CDEV","name":"dev"},"user":"UKARI","ts":"1700000200.000300","text":"hi <@UME>"}]}}' ;;
  *) echo '{"ok":false,"error":"unknown_method"}' ;;
esac
"#,
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn token_file(dir: &Path, mode: u32) -> PathBuf {
        let path = dir.join("slack.toml");
        fs::write(&path, "token = \"xoxp-1-test\"\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    fn client(dir: &Path, mode: u32) -> SlackClient {
        SlackClient::with_curl(
            SlackConfig {
                channels: vec!["dev".into(), "gone".into()],
                token_file: Some(token_file(dir, mode)),
            },
            fake_curl(dir),
        )
    }

    #[tokio::test]
    async fn samples_channels_dms_and_mentions() {
        let temp = tempfile::tempdir().unwrap();
        let sample = client(temp.path(), 0o600).sample().await;
        let snapshot = &sample.snapshot;
        assert!(snapshot.available);

        let dev = &snapshot.channels[0];
        assert!(dev.available);
        assert_eq!(dev.unread, 1);
        let texts: Vec<_> = dev.messages.iter().map(|m| m.text.as_str()).collect();
        assert_eq!(texts, ["older", "hi @Jon see docs & #dev"]);
        assert_eq!(dev.messages[1].author, "Kari");
        assert_eq!(dev.messages[1].replies, 3);
        assert!(dev.messages[1].unread && !dev.messages[0].unread);
        assert!(!snapshot.channels[1].available);

        let kinds: Vec<_> = snapshot
            .notifications
            .iter()
            .map(|n| n.kind.as_str())
            .collect();
        assert_eq!(kinds, ["dm", "mention"]);
        assert_eq!(snapshot.notifications[0].unread, 2);
        assert_eq!(snapshot.notifications[0].source, "Kari");
        assert_eq!(snapshot.notifications[1].source, "#dev");

        let id = &dev.messages[1].id;
        assert_eq!(
            sample.urls[id],
            "https://acme.slack.com/archives/CDEV/p1700000200000300"
        );
        assert!(is_slack_url(&sample.urls[id]));
        let published = serde_json::to_string(snapshot).unwrap();
        assert!(!published.contains("https://") && !published.contains("xoxp"));
    }

    #[tokio::test]
    async fn a_token_readable_by_others_is_refused() {
        let temp = tempfile::tempdir().unwrap();
        let sample = client(temp.path(), 0o644).sample().await;
        assert!(!sample.snapshot.available);
        assert!(sample.urls.is_empty());
    }

    #[test]
    fn only_workspace_permalinks_are_openable() {
        assert!(is_slack_url(
            "https://acme.slack.com/archives/C1/p1700000200000300"
        ));
        assert!(!is_slack_url(
            "https://acme.slack.com.evil.example/archives/C1/p1"
        ));
        assert!(!is_slack_url("https://evil.example/archives/C1/p1"));
        assert!(!is_slack_url("http://acme.slack.com/archives/C1/p1"));
        assert!(!is_slack_url("https://acme.slack.com/archives/C1/p1 --x"));
    }
}
