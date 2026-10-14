//! Recording: a record stream from any of the sound server's sources — a
//! microphone, or a monitor of the speakers (what the computer is playing).
//! Samples arrive as interleaved floats on the sound server's thread.

use crate::engine::connect;
use pulseaudio::{protocol, Client, RecordStream};
use std::ffi::CString;

/// Something to record from.
#[derive(Clone, Debug)]
pub struct Input {
    pub name: String,
    pub label: String,
    /// A monitor: what goes out of a sink, not a microphone.
    pub monitor: bool,
}

fn block<T>(f: impl std::future::Future<Output = T>) -> T {
    futures::executor::block_on(f)
}

fn client() -> Result<Client, String> {
    connect(c"Sound Recorder").ok_or_else(|| "There's no sound server to record from".to_string())
}

/// The inputs, microphones first; and the default one's name.
pub fn inputs() -> Result<(Vec<Input>, String), String> {
    let c = client()?;
    let list = block(c.list_sources()).map_err(|e| e.to_string())?;
    let default = block(c.server_info())
        .ok()
        .and_then(|i| i.default_source_name)
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut out: Vec<Input> = list
        .into_iter()
        .map(|s| {
            let name = s.name.to_string_lossy().into_owned();
            let desc = s.description.map(|d| d.to_string_lossy().into_owned()).unwrap_or_else(|| name.clone());
            let monitor = s.monitor_of_sink_index.is_some();
            let label = if monitor { format!("What's playing — {}", desc.trim_start_matches("Monitor of ")) } else { desc };
            Input { name, label, monitor }
        })
        .collect();
    out.sort_by_key(|i| (i.monitor, i.name != default));
    Ok((out, default))
}

/// A recording in progress. Dropping it ends it.
pub struct Recording {
    _client: Client,
    stream: Option<RecordStream>,
}

impl Recording {
    /// Record `channels` at `rate` from `source` (None: the default), and
    /// hand every block of samples to `sink`.
    pub fn start(source: Option<&str>, channels: u8, rate: u32, mut sink: impl FnMut(&[f32]) + Send + 'static) -> Result<Recording, String> {
        let c = client()?;
        let mut props = protocol::Props::new();
        props.set(protocol::Prop::MediaRole, c"production");
        props.set(protocol::Prop::ApplicationIconName, c"hyprshell-recorder");
        props.set(protocol::Prop::ApplicationId, c"hyprshell-recorder");
        props.set(protocol::Prop::MediaName, c"Recording");
        let bytes_per_sec = rate * channels as u32 * 4;
        let params = protocol::RecordStreamParams {
            sample_spec: protocol::SampleSpec { format: protocol::SampleFormat::Float32Le, channels, sample_rate: rate },
            channel_map: if channels == 1 { protocol::ChannelMap::mono() } else { protocol::ChannelMap::stereo() },
            source_name: Some(match source {
                Some(s) if !s.is_empty() => CString::new(s).map_err(|_| "That input's name is odd".to_string())?,
                _ => protocol::DEFAULT_SOURCE.to_owned(),
            }),
            buffer_attr: protocol::stream::BufferAttr {
                // A twentieth of a second at a time: the level meter keeps up.
                fragment_size: bytes_per_sec / 20 / 4 * 4,
                ..Default::default()
            },
            props,
            ..Default::default()
        };
        // Blocks may split a sample; keep the odd bytes for the next one.
        let mut carry: Vec<u8> = Vec::new();
        let mut floats: Vec<f32> = Vec::new();
        let cb = move |data: &[u8]| {
            carry.extend_from_slice(data);
            let whole = carry.len() / 4 * 4;
            floats.clear();
            floats.extend(carry[..whole].chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])));
            carry.drain(..whole);
            if !floats.is_empty() {
                sink(&floats);
            }
        };
        let stream = block(c.create_record_stream(params, cb)).map_err(|e| format!("The sound server wouldn't record ({e})"))?;
        Ok(Recording { _client: c, stream: Some(stream) })
    }

    pub fn pause(&self) {
        if let Some(s) = &self.stream {
            let _ = block(s.cork());
        }
    }

    pub fn resume(&self) {
        if let Some(s) = &self.stream {
            let _ = block(s.uncork());
        }
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        if let Some(s) = self.stream.take() {
            let _ = block(s.delete());
        }
    }
}
