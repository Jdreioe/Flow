//! Cloud and Piper audio playback through rodio.
//!
//! System speech stays native (Speech Dispatcher / WinRT); everything Flow
//! synthesizes itself (Azure, Google, Piper, previews) plays here. The QML
//! MediaPlayer from the Qt shells is gone: one sink speaks, a second sink
//! previews Piper voices without interrupting playback.

use std::{
    fs::File,
    io::BufReader,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use rodio::{Decoder, OutputStream, OutputStreamBuilder, Sink, Source};

pub struct Player {
    _stream: Option<OutputStream>,
    speech: Option<Arc<Sink>>,
    preview: Option<Arc<Sink>>,
    generation: Arc<AtomicU64>,
}

impl Player {
    pub fn new() -> Self {
        let stream = OutputStreamBuilder::open_default_stream().ok();
        let speech = stream
            .as_ref()
            .map(|stream| Arc::new(Sink::connect_new(stream.mixer())));
        let preview = stream
            .as_ref()
            .map(|stream| Arc::new(Sink::connect_new(stream.mixer())));
        Self {
            _stream: stream,
            speech,
            preview,
            generation: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn available(&self) -> bool {
        self.speech.is_some()
    }

    /// Plays one audio file at the given rate. `on_done` fires when the sink
    /// drains, unless `stop` (or a newer `play_file`) superseded it first.
    pub fn play_file(&mut self, path: &Path, rate: f64, on_done: impl FnOnce() + Send + 'static) {
        let Some(sink) = self.speech.clone() else {
            on_done();
            return;
        };
        self.generation.fetch_add(1, Ordering::SeqCst);
        sink.stop();
        let decoded = File::open(path)
            .map(BufReader::new)
            .map_err(|_| ())
            .and_then(|file| Decoder::new(file).map_err(|_| ()))
            .map(|source| source.speed(rate.clamp(0.5, 4.0) as f32));
        let Ok(source) = decoded else {
            on_done();
            return;
        };
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        sink.append(source);
        let seen = Arc::clone(&self.generation);
        std::thread::spawn(move || {
            // Give the decoder a head start so the first poll does not mistake
            // an empty queue for a finished one, then wait for a stable drain.
            std::thread::sleep(Duration::from_millis(300));
            let mut drained = 0;
            loop {
                if seen.load(Ordering::SeqCst) != generation {
                    return;
                }
                if sink.empty() {
                    drained += 1;
                    if drained >= 3 {
                        break;
                    }
                } else {
                    drained = 0;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            if seen.load(Ordering::SeqCst) == generation {
                on_done();
            }
        });
    }

    pub fn stop(&mut self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Some(sink) = &self.speech {
            sink.stop();
        }
    }

    pub fn set_rate(&self, rate: f64) {
        if let Some(sink) = &self.speech {
            sink.set_speed(rate.clamp(0.5, 4.0) as f32);
        }
    }

    pub fn pause(&self) {
        if let Some(sink) = &self.speech {
            sink.pause();
        }
    }

    pub fn resume(&self) {
        if let Some(sink) = &self.speech {
            sink.play();
        }
    }

    pub fn play_preview(&mut self, path: &Path) {
        let Some(sink) = &self.preview else { return };
        sink.stop();
        let Ok(file) = File::open(path) else { return };
        let Ok(source) = Decoder::new(BufReader::new(file)) else {
            return;
        };
        sink.append(source);
    }
}
