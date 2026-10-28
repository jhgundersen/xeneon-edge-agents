use std::{path::PathBuf, process::Stdio, time::Duration};

use anyhow::{Context, Result, bail};
use serde_json::Value;
use tokio::{process::Command, time::timeout};

use crate::model::{ActionKind, PlaybackStatus, SpotifySnapshot};

const SPOTIFY_BUS_NAME: &str = "org.mpris.MediaPlayer2.spotify";
const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";
const MPRIS_PLAYER: &str = "org.mpris.MediaPlayer2.Player";
// Order matters: parse_properties reads busctl's one-JSON-value-per-line
// output positionally.
const PROPERTIES: [&str; 6] = [
    "PlaybackStatus",
    "Position",
    "CanControl",
    "CanGoNext",
    "CanGoPrevious",
    "Metadata",
];
const COMMAND_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_TEXT_CHARS: usize = 160;
// Cover art is only ever loaded from Spotify's own image CDN.
const ART_URL_PREFIX: &str = "https://i.scdn.co/image/";

/// Reads and controls the Spotify desktop client over its MPRIS D-Bus
/// interface through `busctl`, like the other collectors shell out to their
/// tools. Only fixed, typed calls are ever made.
#[derive(Debug, Clone)]
pub struct SpotifyClient {
    busctl_bin: PathBuf,
}

impl Default for SpotifyClient {
    fn default() -> Self {
        Self::new("busctl")
    }
}

impl SpotifyClient {
    pub fn new(busctl_bin: impl Into<PathBuf>) -> Self {
        Self {
            busctl_bin: busctl_bin.into(),
        }
    }

    /// A missing or unresponsive Spotify client is a normal state, reported
    /// as an unavailable snapshot rather than an error.
    pub async fn sample(&self) -> SpotifySnapshot {
        let mut args = vec![
            "--user",
            "--json=short",
            "get-property",
            SPOTIFY_BUS_NAME,
            MPRIS_PATH,
            MPRIS_PLAYER,
        ];
        args.extend(PROPERTIES);
        match self.busctl(&args).await {
            Ok(stdout) => parse_properties(&stdout).unwrap_or_else(|error| {
                tracing::debug!(%error, "unexpected Spotify MPRIS properties");
                SpotifySnapshot::default()
            }),
            Err(_) => SpotifySnapshot::default(),
        }
    }

    pub async fn control(&self, action: ActionKind) -> Result<()> {
        let method = match action {
            ActionKind::SpotifyPlayPause => "PlayPause",
            ActionKind::SpotifyNext => "Next",
            ActionKind::SpotifyPrevious => "Previous",
            _ => bail!("{action:?} is not a Spotify control"),
        };
        self.busctl(&[
            "--user",
            "call",
            SPOTIFY_BUS_NAME,
            MPRIS_PATH,
            MPRIS_PLAYER,
            method,
        ])
        .await
        .map(|_| ())
    }

    async fn busctl(&self, args: &[&str]) -> Result<String> {
        let output = timeout(
            COMMAND_TIMEOUT,
            Command::new(&self.busctl_bin)
                .kill_on_drop(true)
                .args(args)
                .stdin(Stdio::null())
                .stderr(Stdio::piped())
                .output(),
        )
        .await
        .context("timed out talking to Spotify over D-Bus")?
        .with_context(|| format!("running {}", self.busctl_bin.display()))?;
        if !output.status.success() {
            bail!(
                "Spotify D-Bus call failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        String::from_utf8(output.stdout).context("busctl output was not UTF-8")
    }
}

fn parse_properties(stdout: &str) -> Result<SpotifySnapshot> {
    let values = stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str::<Value>(line).map(|value| value["data"].clone()))
        .collect::<Result<Vec<_>, _>>()
        .context("parsing busctl JSON")?;
    let [
        status,
        position,
        can_control,
        can_go_next,
        can_go_previous,
        metadata,
    ] = <[Value; PROPERTIES.len()]>::try_from(values)
        .map_err(|values| anyhow::anyhow!("expected 6 properties, got {}", values.len()))?;

    let status = match status.as_str() {
        Some("Playing") => PlaybackStatus::Playing,
        Some("Paused") => PlaybackStatus::Paused,
        _ => PlaybackStatus::Stopped,
    };
    let text = |key: &str| bounded(metadata[key]["data"].as_str().unwrap_or_default());
    let artist = metadata["xesam:artist"]["data"]
        .as_array()
        .map(|artists| {
            artists
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default();
    let art_url = metadata["mpris:artUrl"]["data"]
        .as_str()
        .filter(|url| {
            url.starts_with(ART_URL_PREFIX)
                && url.len() <= 256
                && url
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b":/._-".contains(&byte))
        })
        .map(str::to_owned);
    // MPRIS reports microseconds.
    let length_ms = metadata["mpris:length"]["data"].as_u64().unwrap_or(0) / 1000;
    let position_ms = (position.as_i64().unwrap_or(0).max(0) as u64 / 1000).min(length_ms);

    Ok(SpotifySnapshot {
        available: true,
        status,
        title: text("xesam:title"),
        artist: bounded(&artist),
        album: text("xesam:album"),
        art_url,
        length_ms,
        position_ms,
        can_control: can_control.as_bool().unwrap_or(false),
        can_go_next: can_go_next.as_bool().unwrap_or(false),
        can_go_previous: can_go_previous.as_bool().unwrap_or(false),
    })
}

fn bounded(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_control())
        .take(MAX_TEXT_CHARS)
        .collect()
}

/// Whether `next` differs from what the portal already shows. Position is
/// advanced locally by the portal, so only a jump (seek, skip, stall) beyond
/// `tolerance_ms` of where `previous` would be now counts as a change.
pub fn spotify_changed(
    previous: &SpotifySnapshot,
    next: &SpotifySnapshot,
    elapsed_ms: u64,
    tolerance_ms: u64,
) -> bool {
    let without_position = |snapshot: &SpotifySnapshot| SpotifySnapshot {
        position_ms: 0,
        ..snapshot.clone()
    };
    if without_position(previous) != without_position(next) {
        return true;
    }
    let expected = if previous.status == PlaybackStatus::Playing {
        (previous.position_ms + elapsed_ms).min(previous.length_ms)
    } else {
        previous.position_ms
    };
    expected.abs_diff(next.position_ms) > tolerance_ms
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAYING: &str = concat!(
        r#"{"type":"s","data":"Playing"}"#,
        "\n",
        r#"{"type":"x","data":24145000}"#,
        "\n",
        r#"{"type":"b","data":true}"#,
        "\n",
        r#"{"type":"b","data":true}"#,
        "\n",
        r#"{"type":"b","data":false}"#,
        "\n",
        r#"{"type":"a{sv}","data":{"mpris:length":{"type":"t","data":215000000},"#,
        r#""mpris:artUrl":{"type":"s","data":"https://i.scdn.co/image/ab67616d0000b273"},"#,
        r#""xesam:album":{"type":"s","data":"Album"},"#,
        r#""xesam:artist":{"type":"as","data":["One","Two"]},"#,
        r#""xesam:title":{"type":"s","data":"Song\u0007"}}}"#,
        "\n",
    );

    #[test]
    fn parses_spotify_mpris_properties() {
        let snapshot = parse_properties(PLAYING).unwrap();
        assert!(snapshot.available);
        assert_eq!(snapshot.status, PlaybackStatus::Playing);
        assert_eq!(snapshot.title, "Song");
        assert_eq!(snapshot.artist, "One, Two");
        assert_eq!(snapshot.album, "Album");
        assert_eq!(
            snapshot.art_url.as_deref(),
            Some("https://i.scdn.co/image/ab67616d0000b273")
        );
        assert_eq!(snapshot.length_ms, 215_000);
        assert_eq!(snapshot.position_ms, 24_145);
        assert!(snapshot.can_control && snapshot.can_go_next);
        assert!(!snapshot.can_go_previous);
    }

    #[test]
    fn art_from_other_hosts_and_short_output_are_rejected() {
        let elsewhere = PLAYING.replace("https://i.scdn.co/image/", "https://example.com/");
        assert_eq!(parse_properties(&elsewhere).unwrap().art_url, None);
        let first_line = PLAYING.lines().next().unwrap();
        assert!(parse_properties(first_line).is_err());
    }

    #[test]
    fn only_track_changes_or_position_jumps_count_as_changes() {
        let playing = parse_properties(PLAYING).unwrap();
        let later = SpotifySnapshot {
            position_ms: playing.position_ms + 1_000,
            ..playing.clone()
        };
        assert!(!spotify_changed(&playing, &later, 1_000, 1_500));
        let seeked = SpotifySnapshot {
            position_ms: playing.position_ms + 60_000,
            ..playing.clone()
        };
        assert!(spotify_changed(&playing, &seeked, 1_000, 1_500));
        let paused = SpotifySnapshot {
            status: PlaybackStatus::Paused,
            ..playing.clone()
        };
        assert!(spotify_changed(&playing, &paused, 0, 1_500));
    }

    #[tokio::test]
    async fn a_missing_client_is_unavailable_not_an_error() {
        let snapshot = SpotifyClient::new("/nonexistent/busctl").sample().await;
        assert_eq!(snapshot, SpotifySnapshot::default());
        assert!(!snapshot.available);
    }
}
