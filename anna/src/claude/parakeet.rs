//! NVIDIA's Parakeet TDT 0.6B v3 (CC-BY-4.0), kept loaded while the user
//! speaks, so the transcript can follow the voice: the recording so far is
//! transcribed again every half second, which only works if each pass is
//! quick. It runs in ONNX Runtime on the processor — no graphics card needed
//! — and detects the language itself among 25 European ones.
//!
//! The ONNX export of onnx-asr (istupakov/parakeet-tdt-0.6b-v3-onnx), four
//! files in one directory:
//!
//!   1. `nemo128.onnx`: 16 kHz samples → 128 log-mel bands every 10 ms,
//!      normalized per band, exactly as NeMo computes them.
//!   2. `encoder-model.int8.onnx` (FastConformer): the bands → one vector of
//!      1 024 every 80 ms, over the recording's real length (Whisper always
//!      encodes 30 s).
//!   3. `decoder_joint-model.int8.onnx`: an encoder vector, the last token
//!      and the decoder's state → the next token's scores, followed by those
//!      of how many vectors to skip (0–4): TDT, the Token-and-Duration
//!      Transducer, jumps over silence and long sounds.
//!   4. `vocab.txt`: the SentencePiece tokens, `▁` for a space, the blank
//!      last.
//!
//! The model is dropped after a while without use: it holds about 1 GB.

use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::TensorRef;
use std::path::Path;
use std::time::{Duration, Instant};

/// Drop the model after this long without a request.
pub const IDLE: Duration = Duration::from_secs(10 * 60);
/// The model's input rate.
pub const RATE: u32 = 16_000;
/// The decoder's LSTM state: layers × hidden units.
const STATE: [usize; 3] = [2, 1, 640];
/// At most this many tokens on one encoder vector.
const MAX_TOKENS_PER_STEP: usize = 10;

fn load(path: &Path, threads: usize) -> Result<Session, String> {
    let err = |e: &dyn std::fmt::Display| format!("{} : {e}", path.display());
    Session::builder()
        .map_err(|e| err(&e))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| err(&e))?
        .with_intra_threads(threads)
        .map_err(|e| err(&e))?
        .with_intra_op_spinning(false)
        .map_err(|e| err(&e))?
        .with_inter_op_spinning(false)
        .map_err(|e| err(&e))?
        .commit_from_file(path)
        .map_err(|e| err(&e))
}

/// `vocab.txt`: one `<token> <id>` per line.
fn read_vocab(text: &str) -> Vec<String> {
    let mut tokens: Vec<(usize, String)> = text
        .lines()
        .filter_map(|l| {
            let (t, id) = l.rsplit_once(' ')?;
            Some((id.trim().parse().ok()?, t.to_string()))
        })
        .collect();
    tokens.sort_by_key(|(id, _)| *id);
    tokens.into_iter().map(|(_, t)| t).collect()
}

/// Tokens → text: `▁` starts a word, `<…>` are control tokens.
fn detokenize<'a>(tokens: impl IntoIterator<Item = &'a str>) -> String {
    tokens
        .into_iter()
        .filter(|t| !(t.starts_with('<') && t.ends_with('>')))
        .collect::<String>()
        .replace('▁', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn index_of_max(v: &[f32]) -> usize {
    v.iter()
        .enumerate()
        .fold(
            (0, f32::NEG_INFINITY),
            |m, (i, &x)| if x > m.1 { (i, x) } else { m },
        )
        .0
}

pub struct Model {
    preprocessor: Session,
    encoder: Session,
    decoder: Session,
    vocab: Vec<String>,
    pub last_use: Instant,
}

impl Model {
    /// Load the four files from `dir` (a few seconds: the encoder is 650 MB).
    pub fn load(dir: &Path) -> Result<Model, String> {
        let vocab = std::fs::read_to_string(dir.join("vocab.txt"))
            .map(|t| read_vocab(&t))
            .map_err(|e| format!("{} : {e}", dir.join("vocab.txt").display()))?;
        // One thread per physical core (hyper-threads only fight over the
        // same units), at most 8.
        let threads = std::thread::available_parallelism()
            .map(|n| (n.get() / 2).clamp(1, 8))
            .unwrap_or(2);
        Ok(Model {
            preprocessor: load(&dir.join("nemo128.onnx"), 1)?,
            encoder: load(&dir.join("encoder-model.int8.onnx"), threads)?,
            decoder: load(&dir.join("decoder_joint-model.int8.onnx"), 1)?,
            vocab,
            last_use: Instant::now(),
        })
    }

    /// Transcribe 16 kHz mono samples.
    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, String> {
        self.last_use = Instant::now();
        let e = |e: ort::Error| format!("parakeet : {e}");
        if samples.is_empty() {
            return Ok(String::new());
        }

        let n = [samples.len() as i64];
        let out = self
            .preprocessor
            .run(ort::inputs! {
                "waveforms" => TensorRef::from_array_view(([1usize, samples.len()], samples)).map_err(e)?,
                "waveforms_lens" => TensorRef::from_array_view(([1usize], &n[..])).map_err(e)?,
            })
            .map_err(e)?;
        let (shape, features) = out["features"].try_extract_tensor::<f32>().map_err(e)?;
        let shape: Vec<usize> = shape.iter().map(|&d| d as usize).collect();
        let features = features.to_vec();
        let (_, lens) = out["features_lens"]
            .try_extract_tensor::<i64>()
            .map_err(e)?;
        let lens = [lens[0]];
        drop(out);

        let out = self
            .encoder
            .run(ort::inputs! {
                "audio_signal" => TensorRef::from_array_view((shape, &features[..])).map_err(e)?,
                "length" => TensorRef::from_array_view(([1usize], &lens[..])).map_err(e)?,
            })
            .map_err(e)?;
        // (1, dim, frames), frames as the inner axis.
        let (shape, encoded) = out["outputs"].try_extract_tensor::<f32>().map_err(e)?;
        let (dim, frames) = (shape[1] as usize, shape[2] as usize);
        let (_, len) = out["encoded_lengths"]
            .try_extract_tensor::<i64>()
            .map_err(e)?;
        let frames = frames.min(len[0] as usize);
        let encoded = encoded.to_vec();
        let total = shape[2] as usize;
        drop(out);

        let tokens = self.decode(&encoded, dim, total, frames)?;
        Ok(detokenize(tokens.iter().map(|&t| self.vocab[t].as_str())))
    }

    /// TDT greedy decoding over the encoder's `frames` vectors.
    fn decode(
        &mut self,
        encoded: &[f32],
        dim: usize,
        total: usize,
        frames: usize,
    ) -> Result<Vec<usize>, String> {
        let e = |e: ort::Error| format!("parakeet : {e}");
        let blank = self.vocab.len() - 1;
        let state_len = STATE.iter().product();
        let (mut h, mut c) = (vec![0f32; state_len], vec![0f32; state_len]);
        let mut last = blank as i32;
        let mut tokens = Vec::new();
        let mut frame = vec![0f32; dim];
        let (mut t, mut emitted) = (0usize, 0usize);
        while t < frames {
            for (d, x) in frame.iter_mut().enumerate() {
                *x = encoded[d * total + t];
            }
            let target = [last];
            let one = [1i32];
            let out = self
                .decoder
                .run(ort::inputs! {
                    "encoder_outputs" => TensorRef::from_array_view(([1usize, dim, 1], &frame[..])).map_err(e)?,
                    "targets" => TensorRef::from_array_view(([1usize, 1], &target[..])).map_err(e)?,
                    "target_length" => TensorRef::from_array_view(([1usize], &one[..])).map_err(e)?,
                    "input_states_1" => TensorRef::from_array_view((STATE, &h[..])).map_err(e)?,
                    "input_states_2" => TensorRef::from_array_view((STATE, &c[..])).map_err(e)?,
                })
                .map_err(e)?;
            let (_, scores) = out["outputs"].try_extract_tensor::<f32>().map_err(e)?;
            let token = index_of_max(&scores[..self.vocab.len()]);
            let skip = index_of_max(&scores[self.vocab.len()..]);
            if token != blank {
                // The decoder moves on only with a real token.
                let (_, s1) = out["output_states_1"]
                    .try_extract_tensor::<f32>()
                    .map_err(e)?;
                let (_, s2) = out["output_states_2"]
                    .try_extract_tensor::<f32>()
                    .map_err(e)?;
                h.copy_from_slice(s1);
                c.copy_from_slice(s2);
                last = token as i32;
                tokens.push(token);
                emitted += 1;
            }
            if skip > 0 {
                t += skip;
                emitted = 0;
            } else if token == blank || emitted >= MAX_TOKENS_PER_STEP {
                t += 1;
                emitted = 0;
            }
        }
        Ok(tokens)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vocab_is_read_in_id_order() {
        let v = read_vocab("<unk> 0\n▁de 2\nb 1\n<blk> 3\n");
        assert_eq!(v, ["<unk>", "b", "▁de", "<blk>"]);
    }

    #[test]
    fn tokens_become_words() {
        assert_eq!(
            detokenize(["▁Ex", "up", "éry", ",", "▁baisse", "▁le", "▁son", "."]),
            "Exupéry, baisse le son."
        );
        assert_eq!(detokenize(["<unk>", "▁Bonjour", "<blk>"]), "Bonjour");
        assert_eq!(detokenize([]), "");
    }

    /// `ANNA_PARAKEET_TEST=<model dir>:<16 kHz WAV>`, with ORT_DYLIB_PATH:
    /// the transcript and how long it took.
    #[test]
    #[ignore]
    fn transcribes_a_file() {
        let arg = std::env::var("ANNA_PARAKEET_TEST").unwrap();
        let (dir, wav) = arg.split_once(':').unwrap();
        let t0 = Instant::now();
        let mut m = Model::load(Path::new(dir)).unwrap();
        eprintln!("chargement : {:?}", t0.elapsed());
        let (samples, rate) = super::super::voice::read_wav(&std::fs::read(wav).unwrap()).unwrap();
        let samples = super::super::voice::resample(&samples, rate);
        for _ in 0..2 {
            let t0 = Instant::now();
            let text = m.transcribe(&samples).unwrap();
            eprintln!("{:?} « {text} »", t0.elapsed());
        }
    }
}
