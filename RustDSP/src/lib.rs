use std::f64::consts::PI;
use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::sync::Mutex;

// MARK: - C ABI Structs

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScChordSegment {
    pub root: i32,
    pub quality: i32,
    pub confidence: f64,
    pub start_time: f64,
    pub end_time: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScBeatCell {
    pub bar_index: i32,
    pub beat_index: i32,
    pub root: i32,
    pub quality: i32,
    pub is_chord_change: u8,
    pub start_time: f64,
    pub end_time: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScSection {
    pub kind: i32,
    pub start_time: f64,
    pub end_time: f64,
}

#[repr(C)]
#[derive(Debug)]
pub struct ScTimelineResult {
    pub segments: *mut ScChordSegment,
    pub segment_count: usize,
    pub beats: *mut ScBeatCell,
    pub beat_count: usize,
    pub sections: *mut ScSection,
    pub section_count: usize,
    pub key_root: i32,
    pub key_is_minor: u8,
    pub has_key: u8,
    pub bpm: f64,
    pub beats_per_bar: i32,
    pub duration: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ScRealtimeSnapshot {
    pub root: i32,
    pub quality: i32,
    pub confidence: f64,
    pub key_root: i32,
    pub key_is_minor: u8,
    pub has_key: u8,
    pub chroma: [f32; 12],
    pub has_chord: u8,
}

impl Default for ScRealtimeSnapshot {
    fn default() -> Self {
        Self {
            root: 0,
            quality: 0,
            confidence: 0.0,
            key_root: 0,
            key_is_minor: 0,
            has_key: 0,
            chroma: [0.0; 12],
            has_chord: 0,
        }
    }
}

// MARK: - Constants & Profiles

const OFFLINE_FFT_SIZE: usize = 8192;
const OFFLINE_HOP_SIZE: usize = 2048;
const ONSET_FFT_SIZE: usize = 2048;
const ONSET_HOP_SIZE: usize = 512;
const REALTIME_FFT_SIZE: usize = 16384;
const SILENCE_RMS_THRESHOLD: f64 = 0.002;
const MIN_SEGMENT_DURATION_SEC: f64 = 0.40;

// Krumhansl-Schmuckler key profiles
const MAJOR_KEY_PROFILE: [f64; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const MINOR_KEY_PROFILE: [f64; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
];

// MARK: - Pure Rust Iterative Radix-2 Cooley-Tukey FFT

struct FftPlan {
    n: usize,
    bit_rev: Vec<usize>,
    hann: Vec<f64>,
    twiddles_re: Vec<f64>,
    twiddles_im: Vec<f64>,
}

impl FftPlan {
    fn new(n: usize) -> Self {
        assert!(n.is_power_of_two() && n >= 2);
        let log2n = n.trailing_zeros() as usize;
        let mut bit_rev = vec![0usize; n];
        for (i, slot) in bit_rev.iter_mut().enumerate() {
            let mut x = i;
            let mut rev = 0usize;
            for _ in 0..log2n {
                rev = (rev << 1) | (x & 1);
                x >>= 1;
            }
            *slot = rev;
        }

        let denom = (n - 1) as f64;
        let hann: Vec<f64> = (0..n)
            .map(|i| 0.5 * (1.0 - (2.0 * PI * (i as f64) / denom).cos()))
            .collect();

        // Precompute half-N twiddles for the largest stage; stage step m uses stride n / m.
        let half = n / 2;
        let mut twiddles_re = Vec::with_capacity(half);
        let mut twiddles_im = Vec::with_capacity(half);
        for k in 0..half {
            let angle = -2.0 * PI * (k as f64) / (n as f64);
            twiddles_re.push(angle.cos());
            twiddles_im.push(angle.sin());
        }

        Self {
            n,
            bit_rev,
            hann,
            twiddles_re,
            twiddles_im,
        }
    }

    fn compute_magnitudes_into(
        &self,
        samples: &[f32],
        re: &mut [f64],
        im: &mut [f64],
        out_mag: &mut [f64],
    ) {
        let n = self.n;
        let copy_len = samples.len().min(n);

        for i in 0..n {
            let s = if i < copy_len {
                let v = samples[i] as f64;
                if v.is_finite() { v } else { 0.0 }
            } else {
                0.0
            };
            let dst = self.bit_rev[i];
            re[dst] = s * self.hann[i];
            im[dst] = 0.0;
        }

        let mut m = 2usize;
        while m <= n {
            let half_m = m >> 1;
            let stride = n / m;
            let mut k = 0usize;
            while k < n {
                for j in 0..half_m {
                    let tw_idx = j * stride;
                    let w_re = self.twiddles_re[tw_idx];
                    let w_im = self.twiddles_im[tw_idx];

                    let idx_even = k + j;
                    let idx_odd = idx_even + half_m;

                    let o_re = re[idx_odd];
                    let o_im = im[idx_odd];
                    let t_re = w_re * o_re - w_im * o_im;
                    let t_im = w_re * o_im + w_im * o_re;

                    let e_re = re[idx_even];
                    let e_im = im[idx_even];
                    re[idx_even] = e_re + t_re;
                    im[idx_even] = e_im + t_im;
                    re[idx_odd] = e_re - t_re;
                    im[idx_odd] = e_im - t_im;
                }
                k += m;
            }
            m <<= 1;
        }

        let bins = n / 2 + 1;
        for (i, slot) in out_mag.iter_mut().take(bins).enumerate() {
            let r = re[i];
            let im_v = im[i];
            *slot = (r * r + im_v * im_v).sqrt();
        }
    }
}

// MARK: - Chroma Extraction

struct MidiNoteBin {
    pitch_class: usize,
    low_bin: usize,
    high_bin: usize,
    center_bin: f64,
    weight: f64,
    is_bass: bool,
}

struct ChromaExtractor {
    notes: Vec<MidiNoteBin>,
}

impl ChromaExtractor {
    fn new(sample_rate: f64, fft_size: usize) -> Self {
        let df = sample_rate / (fft_size as f64);
        let max_bin = fft_size / 2;
        let mut notes = Vec::with_capacity(61);

        // MIDI 36 (C2 = 65.41 Hz) through MIDI 96 (C7 = 2093.0 Hz)
        for midi in 36..=96 {
            let freq = 440.0 * 2f64.powf((midi as f64 - 69.0) / 12.0);
            if !(65.0..=2200.0).contains(&freq) {
                continue;
            }
            let low_freq = freq * 2f64.powf(-0.42 / 12.0);
            let high_freq = freq * 2f64.powf(0.42 / 12.0);
            let center_bin = freq / df;

            let low_bin = ((low_freq / df).floor() as usize).clamp(1, max_bin);
            let high_bin = ((high_freq / df).ceil() as usize).clamp(low_bin, max_bin);

            let is_bass = freq <= 260.0;
            let weight = if is_bass {
                1.35
            } else if freq <= 880.0 {
                1.0
            } else {
                0.72
            };

            notes.push(MidiNoteBin {
                pitch_class: (midi as usize) % 12,
                low_bin,
                high_bin,
                center_bin,
                weight,
                is_bass,
            });
        }

        Self { notes }
    }

    fn extract(&self, mag: &[f64]) -> ([f64; 12], [f64; 12]) {
        let mut chroma = [0.0f64; 12];
        let mut bass = [0.0f64; 12];

        let mut sum_sq = 0.0f64;
        for &m in mag.iter().skip(1) {
            sum_sq += m * m;
        }
        let spec_norm = sum_sq.sqrt().max(1e-9);

        for note in &self.notes {
            let mut peak = 0.0f64;
            for (b, &val) in mag
                .iter()
                .enumerate()
                .take(note.high_bin + 1)
                .skip(note.low_bin)
            {
                let dist = (b as f64 - note.center_bin).abs();
                let shape = (-0.5 * dist * dist).exp();
                let weighted = val * shape.max(0.35);
                if weighted > peak {
                    peak = weighted;
                }
            }
            let norm_mag = peak / spec_norm;
            let log_mag = (1.0 + 18.0 * norm_mag).ln();
            let contrib = log_mag * note.weight;
            chroma[note.pitch_class] += contrib;
            if note.is_bass {
                bass[note.pitch_class] += log_mag;
            }
        }

        l2_normalize_12(&mut chroma);
        l2_normalize_12(&mut bass);
        (chroma, bass)
    }
}

fn l2_normalize_12(v: &mut [f64; 12]) {
    let norm = v.iter().map(|x| x * x).sum::<f64>().sqrt();
    if norm > 1e-12 {
        let inv = 1.0 / norm;
        for item in v.iter_mut() {
            *item *= inv;
        }
    }
}

fn compute_rms(samples: &[f32]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let mut sum = 0.0f64;
    for &s in samples {
        let v = s as f64;
        if v.is_finite() {
            sum += v * v;
        }
    }
    (sum / samples.len() as f64).sqrt()
}

// MARK: - Chord Templates & Scoring

#[derive(Clone)]
struct ChordTemplate {
    root: i32,
    quality: i32,
    weights: [f64; 12],
    is_seventh: bool,
    seventh_pc: usize,
}

fn build_templates(simple_mode: bool) -> Vec<ChordTemplate> {
    let qualities: &[(i32, &[usize], &[f64], bool)] = if simple_mode {
        &[
            (0, &[0, 4, 7], &[1.0, 0.82, 0.86], false),
            (1, &[0, 3, 7], &[1.0, 0.84, 0.86], false),
        ]
    } else {
        &[
            (0, &[0, 4, 7], &[1.0, 0.82, 0.86], false),
            (1, &[0, 3, 7], &[1.0, 0.84, 0.86], false),
            (2, &[0, 4, 7, 10], &[1.0, 0.78, 0.72, 0.82], true),
            (3, &[0, 4, 7, 11], &[1.0, 0.78, 0.72, 0.82], true),
            (4, &[0, 3, 7, 10], &[1.0, 0.78, 0.72, 0.82], true),
        ]
    };

    let mut out = Vec::with_capacity(12 * qualities.len());
    for root in 0..12 {
        for &(quality, intervals, iweights, is_seventh) in qualities {
            let mut weights = [0.0f64; 12];
            for (&iv, &w) in intervals.iter().zip(iweights.iter()) {
                weights[(root + iv) % 12] = w;
            }
            l2_normalize_12(&mut weights);
            let seventh_pc = if is_seventh {
                (root + intervals[3]) % 12
            } else {
                root
            };
            out.push(ChordTemplate {
                root: root as i32,
                quality,
                weights,
                is_seventh,
                seventh_pc,
            });
        }
    }
    out
}

fn template_similarity(
    tpl: &ChordTemplate,
    chroma: &[f64; 12],
    bass: &[f64; 12],
) -> f64 {
    let mut dot = 0.0f64;
    for i in 0..12 {
        dot += tpl.weights[i] * chroma[i];
    }
    let bass_bonus = 0.08 * bass[tpl.root as usize];
    let parsimony = if tpl.is_seventh {
        if chroma[tpl.seventh_pc] < 0.14 {
            -0.06
        } else {
            -0.01
        }
    } else {
        0.0
    };
    (dot + bass_bonus + parsimony).clamp(0.0, 1.15)
}

// MARK: - Key Estimation (Krumhansl-Schmuckler)

fn estimate_key(chroma_sum: &[f64; 12], tonic_votes: &[f64; 24]) -> Option<(i32, bool)> {
    let total: f64 = chroma_sum.iter().sum();
    if total <= 1e-9 {
        return None;
    }

    let c_mean = total / 12.0;
    let mut c_centered = [0.0f64; 12];
    let mut c_ss = 0.0f64;
    for i in 0..12 {
        let d = chroma_sum[i] - c_mean;
        c_centered[i] = d;
        c_ss += d * d;
    }
    if c_ss <= 1e-12 {
        return None;
    }

    let vote_total: f64 = tonic_votes.iter().sum();

    let mut best_score = f64::NEG_INFINITY;
    let mut best_root = 0i32;
    let mut best_minor = false;

    for is_minor in [false, true] {
        let profile = if is_minor {
            &MINOR_KEY_PROFILE
        } else {
            &MAJOR_KEY_PROFILE
        };
        let p_mean = profile.iter().sum::<f64>() / 12.0;
        let p_ss: f64 = profile.iter().map(|x| (x - p_mean) * (x - p_mean)).sum();
        let denom = (c_ss * p_ss).sqrt();
        if denom <= 1e-12 {
            continue;
        }

        for root in 0..12 {
            let mut num = 0.0f64;
            for i in 0..12 {
                let p_val = profile[(i + 12 - root) % 12] - p_mean;
                num += c_centered[i] * p_val;
            }
            let corr = num / denom;
            let vote_idx = root + if is_minor { 12 } else { 0 };
            let vote_bonus = if vote_total > 0.0 {
                0.10 * (tonic_votes[vote_idx] / vote_total)
            } else {
                0.0
            };
            let score = corr + vote_bonus;
            if score > best_score {
                best_score = score;
                best_root = root as i32;
                best_minor = is_minor;
            }
        }
    }

    Some((best_root, best_minor))
}

// MARK: - Anti-Aliased Downsampling for Offline > 28 kHz

fn downsample_if_needed(samples: &[f32], sample_rate: f64) -> (Vec<f32>, f64) {
    if sample_rate <= 28_000.0 || samples.len() < 16 {
        return (samples.to_vec(), sample_rate);
    }
    let factor = (sample_rate / 22_050.0).floor().max(2.0) as usize;
    let eff_sr = sample_rate / (factor as f64);

    // 7-tap Hamming-windowed lowpass kernel
    const KERNEL: [f32; 7] = [0.036, 0.112, 0.214, 0.276, 0.214, 0.112, 0.036];
    let out_len = samples.len() / factor;
    let mut out = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let center = i * factor;
        let mut acc = 0.0f32;
        for (k, &w) in KERNEL.iter().enumerate() {
            let idx = (center as isize + k as isize - 3).clamp(0, (samples.len() - 1) as isize) as usize;
            let s = samples[idx];
            if s.is_finite() {
                acc += w * s;
            }
        }
        out.push(acc);
    }

    (out, eff_sr)
}

// MARK: - Spectral Flux Onset Autocorrelation BPM & Meter Estimator

struct RhythmEstimate {
    bpm: f64,
    phase: f64,
    beats_per_bar: i32,
}

fn estimate_rhythm(samples: &[f32], sample_rate: f64) -> RhythmEstimate {
    if samples.len() < ONSET_FFT_SIZE + ONSET_HOP_SIZE {
        return RhythmEstimate {
            bpm: 120.0,
            phase: 0.0,
            beats_per_bar: 4,
        };
    }

    let plan = FftPlan::new(ONSET_FFT_SIZE);
    let bins = ONSET_FFT_SIZE / 2 + 1;
    let mut re = vec![0.0f64; ONSET_FFT_SIZE];
    let mut im = vec![0.0f64; ONSET_FFT_SIZE];
    let mut mag = vec![0.0f64; bins];
    let mut prev_log = vec![0.0f64; bins];

    let frame_count = (samples.len() - ONSET_FFT_SIZE) / ONSET_HOP_SIZE + 1;
    let mut raw_flux = Vec::with_capacity(frame_count);

    for f in 0..frame_count {
        let start = f * ONSET_HOP_SIZE;
        let slice = &samples[start..start + ONSET_FFT_SIZE];
        plan.compute_magnitudes_into(slice, &mut re, &mut im, &mut mag);

        let mut flux = 0.0f64;
        for b in 1..bins {
            let lm = (1.0 + 12.0 * mag[b]).ln();
            if f > 0 {
                let diff = lm - prev_log[b];
                if diff > 0.0 {
                    flux += diff;
                }
            }
            prev_log[b] = lm;
        }
        raw_flux.push(flux);
    }

    let dt = (ONSET_HOP_SIZE as f64) / sample_rate;
    let half_win = ((0.28 / dt).round() as usize).max(2);
    let mut onset = vec![0.0f64; raw_flux.len()];
    let mut max_onset = 0.0f64;

    for i in 0..raw_flux.len() {
        let lo = i.saturating_sub(half_win);
        let hi = (i + half_win + 1).min(raw_flux.len());
        let mean = raw_flux[lo..hi].iter().sum::<f64>() / ((hi - lo) as f64);
        let val = (raw_flux[i] - 1.05 * mean).max(0.0);
        onset[i] = val;
        if val > max_onset {
            max_onset = val;
        }
    }

    if max_onset <= 1e-6 || onset.len() < 16 {
        return RhythmEstimate {
            bpm: 120.0,
            phase: 0.0,
            beats_per_bar: 4,
        };
    }

    for v in &mut onset {
        *v /= max_onset;
    }

    let energy: f64 = onset.iter().map(|x| x * x).sum();
    if energy <= 1e-9 {
        return RhythmEstimate {
            bpm: 120.0,
            phase: 0.0,
            beats_per_bar: 4,
        };
    }

    let max_lag = ((4.5 / dt).ceil() as usize).min(onset.len().saturating_sub(1));
    if max_lag < 4 {
        return RhythmEstimate {
            bpm: 120.0,
            phase: 0.0,
            beats_per_bar: 4,
        };
    }

    let mut acf = vec![0.0f64; max_lag + 1];
    for (lag, slot) in acf.iter_mut().enumerate().skip(1) {
        let mut s = 0.0f64;
        for i in 0..(onset.len() - lag) {
            s += onset[i] * onset[i + lag];
        }
        *slot = s / energy;
    }

    let sample_acf = |lag_f: f64| -> f64 {
        if lag_f < 1.0 || lag_f >= (max_lag as f64) {
            return 0.0;
        }
        let lo = lag_f.floor() as usize;
        let frac = lag_f - (lo as f64);
        let hi = (lo + 1).min(max_lag);
        acf[lo] * (1.0 - frac) + acf[hi] * frac
    };

    let mut best_bpm = 120.0f64;
    let mut best_score = f64::NEG_INFINITY;

    let mut bpm = 60.0f64;
    while bpm <= 180.0 + 1e-6 {
        let lag = 60.0 / (bpm * dt);
        let comb = sample_acf(lag)
            + 0.48 * sample_acf(2.0 * lag)
            + 0.22 * sample_acf(0.5 * lag)
            + if bpm >= 95.0 {
                0.15 * sample_acf(4.0 * lag)
            } else {
                0.0
            };
        let prior = (-0.5 * ((bpm / 116.0).log2() / 0.70).powi(2)).exp();
        let score = comb * prior;
        if score > best_score {
            best_score = score;
            best_bpm = bpm;
        }
        bpm += 0.5;
    }

    if best_score <= 0.01 {
        best_bpm = 120.0;
    }

    let beat_period = 60.0 / best_bpm;
    let total_dur = (onset.len() as f64) * dt;

    // Beat-phase sweep across [0, beat_period)
    let phase_steps = 50usize;
    let mut best_phase = 0.0f64;
    let mut best_phase_score = f64::NEG_INFINITY;
    for p_idx in 0..phase_steps {
        let phase = (p_idx as f64 / phase_steps as f64) * beat_period;
        let mut score = 0.0f64;
        let mut t = phase;
        while t < total_dur {
            let center = (t / dt).round() as isize;
            for delta in -1..=1 {
                let idx = center + delta;
                if idx >= 0 && (idx as usize) < onset.len() {
                    let w = if delta == 0 { 1.0 } else { 0.45 };
                    score += w * onset[idx as usize];
                }
            }
            t += beat_period;
        }
        if score > best_phase_score {
            best_phase_score = score;
            best_phase = phase;
        }
    }

    // Meter estimation: 4/4 default, 3/4 when triple-meter periodicity clearly wins
    let beat_lag = 60.0 / (best_bpm * dt);
    let score_3 = sample_acf(3.0 * beat_lag) + 0.35 * sample_acf(6.0 * beat_lag);
    let score_4 = sample_acf(4.0 * beat_lag) + 0.35 * sample_acf(8.0 * beat_lag);
    let beats_per_bar = if score_3 > score_4 * 1.18 && score_3 > 0.08 {
        3
    } else {
        4
    };

    RhythmEstimate {
        bpm: (best_bpm * 10.0).round() / 10.0,
        phase: best_phase,
        beats_per_bar,
    }
}

// MARK: - Offline Timeline Analysis (Viterbi + Beat Grid + Sections)

struct FrameFeature {
    start_time: f64,
    end_time: f64,
    rms: f64,
    chroma: [f64; 12],
    bass: [f64; 12],
}

fn analyze_pcm_internal(
    samples: &[f32],
    sample_rate: f64,
    simple_mode: bool,
    known_duration: f64,
) -> ScTimelineResult {
    let raw_duration = if known_duration.is_finite() && known_duration > 0.0 {
        known_duration
    } else if sample_rate > 0.0 {
        (samples.len() as f64) / sample_rate
    } else {
        0.0
    };

    if samples.is_empty() || !sample_rate.is_finite() || sample_rate <= 0.0 {
        return empty_timeline(raw_duration);
    }

    let (work_samples, eff_sr) = downsample_if_needed(samples, sample_rate);
    let rhythm = estimate_rhythm(&work_samples, eff_sr);

    let plan = FftPlan::new(OFFLINE_FFT_SIZE);
    let extractor = ChromaExtractor::new(eff_sr, OFFLINE_FFT_SIZE);
    let bins = OFFLINE_FFT_SIZE / 2 + 1;
    let mut re = vec![0.0f64; OFFLINE_FFT_SIZE];
    let mut im = vec![0.0f64; OFFLINE_FFT_SIZE];
    let mut mag = vec![0.0f64; bins];

    let mut frames: Vec<FrameFeature> = Vec::new();
    let total_len = work_samples.len();
    let mut pos = 0usize;

    while pos < total_len {
        let center_end = (pos + OFFLINE_FFT_SIZE).min(total_len);
        let slice = &work_samples[pos..center_end];
        let rms_end = (pos + OFFLINE_HOP_SIZE).min(total_len);
        let rms = compute_rms(&work_samples[pos..rms_end]);

        plan.compute_magnitudes_into(slice, &mut re, &mut im, &mut mag);
        let (chroma, bass) = extractor.extract(&mag);

        let start_time = (pos as f64) / eff_sr;
        let end_time = ((pos + OFFLINE_HOP_SIZE).min(total_len) as f64) / eff_sr;

        frames.push(FrameFeature {
            start_time,
            end_time: end_time.min(raw_duration.max(end_time)),
            rms,
            chroma,
            bass,
        });

        if pos + OFFLINE_HOP_SIZE >= total_len {
            break;
        }
        pos += OFFLINE_HOP_SIZE;
    }

    if frames.is_empty() {
        return empty_timeline(raw_duration);
    }

    let templates = build_templates(simple_mode);
    let n_chords = templates.len();
    let nc_state = n_chords; // N.C. / silence state
    let n_states = n_chords + 1;
    let n_frames = frames.len();

    // Viterbi decoding over chord templates + N.C.
    let mut emissions = vec![vec![0.0f64; n_states]; n_frames];
    let mut frame_best_conf = vec![0.0f64; n_frames];
    let mut global_chroma = [0.0f64; 12];
    let mut tonic_votes = [0.0f64; 24];
    let mut voiced_count = 0usize;

    for t in 0..n_frames {
        let f = &frames[t];
        if f.rms < SILENCE_RMS_THRESHOLD {
            for s in 0..n_chords {
                emissions[t][s] = -4.0;
            }
            emissions[t][nc_state] = 6.0;
            frame_best_conf[t] = 0.0;
        } else {
            voiced_count += 1;
            let mut max_sim = 0.0f64;
            let mut best_s = 0usize;
            for (s, tpl) in templates.iter().enumerate() {
                let sim = template_similarity(tpl, &f.chroma, &f.bass);
                emissions[t][s] = 6.5 * sim;
                if sim > max_sim {
                    max_sim = sim;
                    best_s = s;
                }
            }
            // Allow N.C. only if tonal clarity is genuinely weak
            emissions[t][nc_state] = 6.5 * 0.44;
            frame_best_conf[t] = max_sim.clamp(0.0, 1.0);

            let w = f.rms.sqrt() * max_sim;
            for pc in 0..12 {
                global_chroma[pc] += w * f.chroma[pc];
            }
            let best_tpl = &templates[best_s];
            let vote_idx = (best_tpl.root as usize)
                + if best_tpl.quality == 1 || best_tpl.quality == 4 {
                    12
                } else {
                    0
                };
            tonic_votes[vote_idx] += w;
        }
    }

    let mut dp = vec![vec![f64::NEG_INFINITY; n_states]; n_frames];
    let mut back = vec![vec![0usize; n_states]; n_frames];

    for s in 0..n_states {
        dp[0][s] = emissions[0][s];
    }

    for t in 1..n_frames {
        let mut dot = 0.0f64;
        for pc in 0..12 {
            dot += frames[t].chroma[pc] * frames[t - 1].chroma[pc];
        }
        let chroma_change = (1.0 - dot).clamp(0.0, 1.0);
        let switch_penalty = if chroma_change > 0.22 { 1.45 } else { 2.95 };

        // O(n_states) optimization: find best and second-best previous state
        let mut best1_val = f64::NEG_INFINITY;
        let mut best1_idx = 0usize;
        let mut best2_val = f64::NEG_INFINITY;
        for (s, &val) in dp[t - 1].iter().enumerate() {
            if val > best1_val {
                best2_val = best1_val;
                best1_val = val;
                best1_idx = s;
            } else if val > best2_val {
                best2_val = val;
            }
        }

        for s in 0..n_states {
            let stay_val = dp[t - 1][s];
            let (other_val, other_idx) = if s == best1_idx {
                (best2_val, best1_idx) // if equal, switch check picks s if stay >= switch
            } else {
                (best1_val, best1_idx)
            };
            let switch_val = other_val - switch_penalty;
            if stay_val >= switch_val {
                dp[t][s] = stay_val + emissions[t][s];
                back[t][s] = s;
            } else {
                dp[t][s] = switch_val + emissions[t][s];
                back[t][s] = other_idx;
            }
        }
        // Fix edge case where s == best1_idx and best2_val happened to be the chosen switch source
        if best1_idx < n_states {
            let mut alt_best_val = f64::NEG_INFINITY;
            let mut alt_best_idx = 0usize;
            for (p, &val) in dp[t - 1].iter().enumerate() {
                if p != best1_idx && val > alt_best_val {
                    alt_best_val = val;
                    alt_best_idx = p;
                }
            }
            let stay_val = dp[t - 1][best1_idx];
            let switch_val = alt_best_val - switch_penalty;
            if stay_val >= switch_val {
                dp[t][best1_idx] = stay_val + emissions[t][best1_idx];
                back[t][best1_idx] = best1_idx;
            } else {
                dp[t][best1_idx] = switch_val + emissions[t][best1_idx];
                back[t][best1_idx] = alt_best_idx;
            }
        }
    }

    let mut path = vec![0usize; n_frames];
    let mut best_last_state = 0usize;
    let mut best_last_score = f64::NEG_INFINITY;
    for (s, &val) in dp[n_frames - 1].iter().enumerate() {
        if val > best_last_score {
            best_last_score = val;
            best_last_state = s;
        }
    }
    path[n_frames - 1] = best_last_state;
    for t in (1..n_frames).rev() {
        path[t - 1] = back[t][path[t]];
    }

    // Build raw segments including N.C. spans initially for clean smoothing
    #[derive(Clone)]
    struct RawSpan {
        state: usize,
        start_time: f64,
        end_time: f64,
        conf_sum: f64,
        count: usize,
    }

    let mut spans: Vec<RawSpan> = Vec::new();
    for t in 0..n_frames {
        let st = path[t];
        let f = &frames[t];
        let conf = if st == nc_state { 0.0 } else { frame_best_conf[t] };
        if let Some(last) = spans.last_mut() {
            if last.state == st {
                last.end_time = f.end_time;
                last.conf_sum += conf;
                last.count += 1;
                continue;
            }
        }
        spans.push(RawSpan {
            state: st,
            start_time: f.start_time,
            end_time: f.end_time,
            conf_sum: conf,
            count: 1,
        });
    }

    if let Some(last) = spans.last_mut() {
        last.end_time = raw_duration.max(last.end_time);
    }

    // Absorb micro-blips shorter than MIN_SEGMENT_DURATION_SEC (< 0.40s)
    loop {
        if spans.len() <= 1 {
            break;
        }
        let mut blip_idx: Option<usize> = None;
        for (i, sp) in spans.iter().enumerate() {
            if sp.end_time - sp.start_time < MIN_SEGMENT_DURATION_SEC {
                blip_idx = Some(i);
                break;
            }
        }
        let Some(idx) = blip_idx else {
            break;
        };

        let merge_into_prev = if idx == 0 {
            false
        } else if idx + 1 >= spans.len() {
            true
        } else {
            let prev = &spans[idx - 1];
            let next = &spans[idx + 1];
            if prev.state == next.state {
                true
            } else {
                let prev_dur = prev.end_time - prev.start_time;
                let next_dur = next.end_time - next.start_time;
                prev_dur >= next_dur
            }
        };

        let removed = spans.remove(idx);
        if merge_into_prev {
            spans[idx - 1].end_time = removed.end_time;
        } else {
            spans[idx].start_time = removed.start_time;
        }

        // Coalesce adjacent identical states
        let mut merged: Vec<RawSpan> = Vec::with_capacity(spans.len());
        for sp in spans {
            if let Some(last) = merged.last_mut() {
                if last.state == sp.state {
                    last.end_time = sp.end_time;
                    last.conf_sum += sp.conf_sum;
                    last.count += sp.count;
                    continue;
                }
            }
            merged.push(sp);
        }
        spans = merged;
    }

    // Beat grid quantization
    let beat_period = (60.0 / rhythm.bpm).max(0.25);
    let mut grid_start = rhythm.phase;
    while grid_start - beat_period >= -0.05 {
        grid_start -= beat_period;
    }
    grid_start = grid_start.max(0.0);

    // Snap segment boundaries within 0.20s of a beat line for clean Chordify beat-tile alignment
    for i in 0..spans.len().saturating_sub(1) {
        let boundary = spans[i].end_time;
        let k = ((boundary - grid_start) / beat_period).round();
        let beat_time = grid_start + k * beat_period;
        if (beat_time - boundary).abs() <= 0.20
            && beat_time > spans[i].start_time + 0.20
            && beat_time < spans[i + 1].end_time - 0.20
        {
            spans[i].end_time = beat_time;
            spans[i + 1].start_time = beat_time;
        }
    }

    let mut segments: Vec<ScChordSegment> = Vec::new();
    for sp in &spans {
        if sp.state == nc_state {
            continue;
        }
        let tpl = &templates[sp.state];
        let avg_conf = (sp.conf_sum / (sp.count.max(1) as f64)).clamp(0.0, 1.0);
        segments.push(ScChordSegment {
            root: tpl.root,
            quality: tpl.quality,
            confidence: avg_conf,
            start_time: sp.start_time,
            end_time: sp.end_time,
        });
    }

    // Build ScBeatCell grid covering [0, raw_duration]
    let mut beats: Vec<ScBeatCell> = Vec::new();
    let mut beat_idx = 0i32;
    let mut prev_chord: Option<(i32, i32)> = None;

    if raw_duration > 0.05 {
        loop {
            let b_start = if beat_idx == 0 {
                0.0
            } else {
                grid_start + (beat_idx as f64) * beat_period
            };
            if b_start >= raw_duration - 0.04 {
                break;
            }
            let b_end = (grid_start + ((beat_idx + 1) as f64) * beat_period).min(raw_duration);
            if b_end <= b_start + 0.01 {
                break;
            }

            // Dominant chord inside [b_start, b_end]
            let mut best_root = -1i32;
            let mut best_quality = 0i32;
            let mut best_overlap = 0.0f64;

            for sp in &spans {
                let ov_start = b_start.max(sp.start_time);
                let ov_end = b_end.min(sp.end_time);
                let ov = ov_end - ov_start;
                if ov > best_overlap {
                    best_overlap = ov;
                    if sp.state == nc_state {
                        best_root = -1;
                        best_quality = 0;
                    } else {
                        let tpl = &templates[sp.state];
                        best_root = tpl.root;
                        best_quality = tpl.quality;
                    }
                }
            }

            let is_change = if best_root >= 0 {
                match prev_chord {
                    Some((pr, pq)) => {
                        if pr != best_root || pq != best_quality {
                            1
                        } else {
                            0
                        }
                    }
                    None => 1,
                }
            } else {
                0
            };
            prev_chord = if best_root >= 0 {
                Some((best_root, best_quality))
            } else {
                None
            };

            beats.push(ScBeatCell {
                bar_index: beat_idx / rhythm.beats_per_bar,
                beat_index: beat_idx % rhythm.beats_per_bar,
                root: best_root,
                quality: best_quality,
                is_chord_change: is_change,
                start_time: b_start,
                end_time: b_end,
            });

            beat_idx += 1;
            if beat_idx > 20_000 {
                break;
            }
        }
    }

    // Section boundary heuristic
    let sections = estimate_sections(&frames, &beats, rhythm.beats_per_bar, raw_duration);

    let key_est = if voiced_count > 0 {
        estimate_key(&global_chroma, &tonic_votes)
    } else {
        None
    };

    let (key_root, key_is_minor, has_key) = match key_est {
        Some((r, is_min)) => (r, if is_min { 1 } else { 0 }, 1),
        None => (0, 0, 0),
    };

    let (seg_ptr, seg_count) = vec_to_raw(segments);
    let (beat_ptr, beat_count) = vec_to_raw(beats);
    let (sec_ptr, sec_count) = vec_to_raw(sections);

    ScTimelineResult {
        segments: seg_ptr,
        segment_count: seg_count,
        beats: beat_ptr,
        beat_count,
        sections: sec_ptr,
        section_count: sec_count,
        key_root,
        key_is_minor,
        has_key,
        bpm: rhythm.bpm,
        beats_per_bar: rhythm.beats_per_bar,
        duration: raw_duration,
    }
}

fn estimate_sections(
    frames: &[FrameFeature],
    beats: &[ScBeatCell],
    beats_per_bar: i32,
    duration: f64,
) -> Vec<ScSection> {
    if duration <= 0.01 {
        return Vec::new();
    }
    if duration < 14.0 || beats.is_empty() {
        return vec![ScSection {
            kind: 1, // Verse
            start_time: 0.0,
            end_time: duration,
        }];
    }

    let total_bars = beats.last().map(|b| b.bar_index + 1).unwrap_or(1);
    if total_bars < 8 {
        return vec![ScSection {
            kind: 1,
            start_time: 0.0,
            end_time: duration,
        }];
    }

    let mut bar_rms = vec![0.0f64; total_bars as usize];
    let mut bar_start = vec![duration; total_bars as usize];
    let mut bar_end = vec![0.0f64; total_bars as usize];
    let mut bar_chroma = vec![[0.0f64; 12]; total_bars as usize];

    for b in beats {
        let bi = b.bar_index as usize;
        if bi < total_bars as usize {
            if b.start_time < bar_start[bi] {
                bar_start[bi] = b.start_time;
            }
            if b.end_time > bar_end[bi] {
                bar_end[bi] = b.end_time;
            }
        }
    }

    for f in frames {
        let mid = 0.5 * (f.start_time + f.end_time);
        if let Some(cell) = beats.iter().find(|c| mid >= c.start_time && mid <= c.end_time) {
            let bi = cell.bar_index as usize;
            if bi < total_bars as usize {
                bar_rms[bi] += f.rms;
                for pc in 0..12 {
                    bar_chroma[bi][pc] += f.chroma[pc];
                }
            }
        }
    }

    for c in &mut bar_chroma {
        l2_normalize_12(c);
    }

    let _ = beats_per_bar;
    let phrase_bars: usize = if total_bars >= 32 { 8 } else { 4 };
    let mut boundaries: Vec<usize> = vec![0];
    let mut b_idx = phrase_bars;
    while b_idx + 2 < total_bars as usize {
        boundaries.push(b_idx);
        b_idx += phrase_bars;
    }

    let n_sec = boundaries.len();
    let mut sec_energy = vec![0.0f64; n_sec];
    let mut max_energy = 1e-9f64;

    for s in 0..n_sec {
        let b0 = boundaries[s];
        let b1 = if s + 1 < n_sec {
            boundaries[s + 1]
        } else {
            total_bars as usize
        };
        let count = (b1 - b0).max(1) as f64;
        let e = bar_rms[b0..b1].iter().sum::<f64>() / count;
        sec_energy[s] = e;
        if e > max_energy {
            max_energy = e;
        }
    }

    let mut sections = Vec::with_capacity(n_sec);
    for s in 0..n_sec {
        let b0 = boundaries[s];
        let b1 = if s + 1 < n_sec {
            boundaries[s + 1]
        } else {
            total_bars as usize
        };
        let st = if s == 0 { 0.0 } else { bar_start[b0] };
        let en = if s + 1 == n_sec {
            duration
        } else {
            bar_start[b1]
        };

        let rel_e = sec_energy[s] / max_energy;
        let kind = if s == 0 && n_sec >= 3 && rel_e < 0.78 {
            0 // Intro
        } else if s + 1 == n_sec && n_sec >= 3 && rel_e < 0.78 {
            5 // Outro
        } else if rel_e >= 0.85 {
            3 // Chorus
        } else if s > 0 && s + 1 < n_sec && sec_energy[s + 1] / max_energy >= 0.85 && rel_e >= 0.65 {
            2 // PreChorus
        } else if n_sec >= 5 && s == n_sec - 2 && rel_e < 0.82 {
            4 // Bridge
        } else {
            1 // Verse
        };

        sections.push(ScSection {
            kind,
            start_time: st,
            end_time: en,
        });
    }

    sections
}

fn empty_timeline(duration: f64) -> ScTimelineResult {
    ScTimelineResult {
        segments: ptr::null_mut(),
        segment_count: 0,
        beats: ptr::null_mut(),
        beat_count: 0,
        sections: ptr::null_mut(),
        section_count: 0,
        key_root: 0,
        key_is_minor: 0,
        has_key: 0,
        bpm: 120.0,
        beats_per_bar: 4,
        duration,
    }
}

fn vec_to_raw<T>(vec: Vec<T>) -> (*mut T, usize) {
    if vec.is_empty() {
        return (ptr::null_mut(), 0);
    }
    let mut boxed = vec.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    (ptr, len)
}

unsafe fn free_raw_slice<T>(ptr: *mut T, len: usize) {
    if !ptr.is_null() && len > 0 {
        let slice_ptr = ptr::slice_from_raw_parts_mut(ptr, len);
        drop(Box::from_raw(slice_ptr));
    }
}

// MARK: - Realtime Ring Buffer State

struct RealtimeState {
    ring: Vec<f32>,
    write_pos: usize,
    filled: usize,
    sample_rate: f64,
    fft_plan: FftPlan,
    extractor: Option<(f64, ChromaExtractor)>,
    re_buf: Vec<f64>,
    im_buf: Vec<f64>,
    mag_buf: Vec<f64>,
    ema_chroma: [f64; 12],
    ema_bass: [f64; 12],
    has_ema: bool,
    key_chroma_sum: [f64; 12],
    key_tonic_votes: [f64; 24],
    held_chord: Option<(i32, i32)>,
    held_score: f64,
    candidate_chord: Option<(i32, i32)>,
    candidate_frames: usize,
}

impl RealtimeState {
    fn new() -> Self {
        Self {
            ring: vec![0.0; REALTIME_FFT_SIZE],
            write_pos: 0,
            filled: 0,
            sample_rate: 44_100.0,
            fft_plan: FftPlan::new(REALTIME_FFT_SIZE),
            extractor: None,
            re_buf: vec![0.0; REALTIME_FFT_SIZE],
            im_buf: vec![0.0; REALTIME_FFT_SIZE],
            mag_buf: vec![0.0; REALTIME_FFT_SIZE / 2 + 1],
            ema_chroma: [0.0; 12],
            ema_bass: [0.0; 12],
            has_ema: false,
            key_chroma_sum: [0.0; 12],
            key_tonic_votes: [0.0; 24],
            held_chord: None,
            held_score: 0.0,
            candidate_chord: None,
            candidate_frames: 0,
        }
    }

    fn reset(&mut self) {
        self.ring.fill(0.0);
        self.write_pos = 0;
        self.filled = 0;
        self.ema_chroma = [0.0; 12];
        self.ema_bass = [0.0; 12];
        self.has_ema = false;
        self.key_chroma_sum = [0.0; 12];
        self.key_tonic_votes = [0.0; 24];
        self.held_chord = None;
        self.held_score = 0.0;
        self.candidate_chord = None;
        self.candidate_frames = 0;
    }

    fn ingest(&mut self, samples: &[f32], sample_rate: f64) {
        if sample_rate.is_finite() && sample_rate > 0.0 {
            if (self.sample_rate - sample_rate).abs() > 1.0 {
                self.sample_rate = sample_rate;
                self.extractor = None;
            }
        }
        let cap = self.ring.len();
        for &s in samples {
            let v = if s.is_finite() { s } else { 0.0 };
            self.ring[self.write_pos] = v;
            self.write_pos = (self.write_pos + 1) % cap;
            if self.filled < cap {
                self.filled += 1;
            }
        }
    }

    fn analyze(&mut self, simple_mode: bool) -> ScRealtimeSnapshot {
        if self.filled < 1024 {
            return ScRealtimeSnapshot::default();
        }

        let cap = self.ring.len();
        let mut ordered = vec![0.0f32; self.filled];
        if self.filled < cap {
            ordered.copy_from_slice(&self.ring[0..self.filled]);
        } else {
            let tail = cap - self.write_pos;
            ordered[0..tail].copy_from_slice(&self.ring[self.write_pos..cap]);
            ordered[tail..cap].copy_from_slice(&self.ring[0..self.write_pos]);
        }

        let rms = compute_rms(&ordered);
        if rms < SILENCE_RMS_THRESHOLD {
            self.held_chord = None;
            self.held_score = 0.0;
            self.candidate_chord = None;
            self.candidate_frames = 0;
            self.has_ema = false;
            let key_est = estimate_key(&self.key_chroma_sum, &self.key_tonic_votes);
            let (kr, km, hk) = match key_est {
                Some((r, m)) => (r, if m { 1 } else { 0 }, 1),
                None => (0, 0, 0),
            };
            return ScRealtimeSnapshot {
                root: 0,
                quality: 0,
                confidence: 0.0,
                key_root: kr,
                key_is_minor: km,
                has_key: hk,
                chroma: [0.0; 12],
                has_chord: 0,
            };
        }

        let sr = self.sample_rate;
        let need_rebuild = match &self.extractor {
            Some((cached_sr, _)) => (*cached_sr - sr).abs() > 1.0,
            None => true,
        };
        if need_rebuild {
            self.extractor = Some((sr, ChromaExtractor::new(sr, REALTIME_FFT_SIZE)));
        }

        self.fft_plan.compute_magnitudes_into(
            &ordered,
            &mut self.re_buf,
            &mut self.im_buf,
            &mut self.mag_buf,
        );

        let (raw_chroma, raw_bass) = self.extractor.as_ref().unwrap().1.extract(&self.mag_buf);
        let alpha = 0.38f64;
        if !self.has_ema {
            self.ema_chroma = raw_chroma;
            self.ema_bass = raw_bass;
            self.has_ema = true;
        } else {
            for i in 0..12 {
                self.ema_chroma[i] = alpha * raw_chroma[i] + (1.0 - alpha) * self.ema_chroma[i];
                self.ema_bass[i] = alpha * raw_bass[i] + (1.0 - alpha) * self.ema_bass[i];
            }
        }

        let mut norm_chroma = self.ema_chroma;
        l2_normalize_12(&mut norm_chroma);
        let mut norm_bass = self.ema_bass;
        l2_normalize_12(&mut norm_bass);

        let templates = build_templates(simple_mode);
        let mut best_tpl = &templates[0];
        let mut best_sim = f64::NEG_INFINITY;
        let mut held_sim = 0.0f64;

        for tpl in &templates {
            let sim = template_similarity(tpl, &norm_chroma, &norm_bass);
            if let Some((hr, hq)) = self.held_chord {
                if tpl.root == hr && tpl.quality == hq {
                    held_sim = sim;
                }
            }
            if sim > best_sim {
                best_sim = sim;
                best_tpl = tpl;
            }
        }

        // Accumulate global key evidence
        for i in 0..12 {
            self.key_chroma_sum[i] += rms * best_sim.max(0.0) * norm_chroma[i];
        }
        let vote_idx = (best_tpl.root as usize)
            + if best_tpl.quality == 1 || best_tpl.quality == 4 {
                12
            } else {
                0
            };
        self.key_tonic_votes[vote_idx] += rms * best_sim.max(0.0);

        // Hysteresis hold frames
        let cand = (best_tpl.root, best_tpl.quality);
        let (final_root, final_quality, final_conf) = match self.held_chord {
            None => {
                self.held_chord = Some(cand);
                self.held_score = best_sim;
                self.candidate_chord = None;
                self.candidate_frames = 0;
                (cand.0, cand.1, best_sim.clamp(0.0, 1.0))
            }
            Some((hr, hq)) => {
                if cand == (hr, hq) {
                    self.held_score = best_sim;
                    self.candidate_chord = None;
                    self.candidate_frames = 0;
                    (hr, hq, best_sim.clamp(0.0, 1.0))
                } else {
                    let strong_override = best_sim > held_sim + 0.10;
                    if self.candidate_chord == Some(cand) {
                        self.candidate_frames += 1;
                    } else {
                        self.candidate_chord = Some(cand);
                        self.candidate_frames = 1;
                    }
                    if strong_override || self.candidate_frames >= 2 {
                        self.held_chord = Some(cand);
                        self.held_score = best_sim;
                        self.candidate_chord = None;
                        self.candidate_frames = 0;
                        (cand.0, cand.1, best_sim.clamp(0.0, 1.0))
                    } else {
                        (hr, hq, held_sim.clamp(0.0, 1.0))
                    }
                }
            }
        };

        let key_est = estimate_key(&self.key_chroma_sum, &self.key_tonic_votes);
        let (kr, km, hk) = match key_est {
            Some((r, m)) => (r, if m { 1 } else { 0 }, 1),
            None => (0, 0, 0),
        };

        let max_c = norm_chroma.iter().copied().fold(0.0f64, f64::max).max(1e-9);
        let mut out_chroma = [0.0f32; 12];
        for i in 0..12 {
            out_chroma[i] = (norm_chroma[i] / max_c).clamp(0.0, 1.0) as f32;
        }

        ScRealtimeSnapshot {
            root: final_root,
            quality: final_quality,
            confidence: final_conf,
            key_root: kr,
            key_is_minor: km,
            has_key: hk,
            chroma: out_chroma,
            has_chord: 1,
        }
    }
}

// MARK: - C ABI Exports

#[no_mangle]
pub unsafe extern "C" fn sc_analyze_pcm(
    samples: *const f32,
    len: usize,
    sample_rate: f64,
    simple_mode: u8,
    known_duration: f64,
) -> *mut ScTimelineResult {
    let slice = if samples.is_null() || len == 0 {
        &[]
    } else {
        slice::from_raw_parts(samples, len)
    };
    let res = analyze_pcm_internal(slice, sample_rate, simple_mode != 0, known_duration);
    Box::into_raw(Box::new(res))
}

#[no_mangle]
pub unsafe extern "C" fn sc_free_timeline(res: *mut ScTimelineResult) {
    if res.is_null() {
        return;
    }
    let boxed = Box::from_raw(res);
    free_raw_slice(boxed.segments, boxed.segment_count);
    free_raw_slice(boxed.beats, boxed.beat_count);
    free_raw_slice(boxed.sections, boxed.section_count);
}

#[no_mangle]
pub extern "C" fn sc_realtime_new() -> *mut c_void {
    let state = Mutex::new(RealtimeState::new());
    Box::into_raw(Box::new(state)) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn sc_realtime_ingest(
    handle: *mut c_void,
    samples: *const f32,
    count: usize,
    sample_rate: f64,
) {
    if handle.is_null() || samples.is_null() || count == 0 {
        return;
    }
    let mutex = &*(handle as *const Mutex<RealtimeState>);
    let slice = slice::from_raw_parts(samples, count);
    if let Ok(mut guard) = mutex.lock() {
        guard.ingest(slice, sample_rate);
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_realtime_analyze(
    handle: *mut c_void,
    simple_mode: u8,
) -> ScRealtimeSnapshot {
    if handle.is_null() {
        return ScRealtimeSnapshot::default();
    }
    let mutex = &*(handle as *const Mutex<RealtimeState>);
    match mutex.lock() {
        Ok(mut guard) => guard.analyze(simple_mode != 0),
        Err(_) => ScRealtimeSnapshot::default(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_realtime_reset(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let mutex = &*(handle as *const Mutex<RealtimeState>);
    if let Ok(mut guard) = mutex.lock() {
        guard.reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn sc_realtime_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let ptr = handle as *mut Mutex<RealtimeState>;
    drop(Box::from_raw(ptr));
}

// MARK: - Unit Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn synth_chord(midi_notes: &[i32], sample_rate: f64, seconds: f64, amp: f32) -> Vec<f32> {
        let count = (sample_rate * seconds) as usize;
        let mut out = vec![0.0f32; count];
        let note_amp = amp / (midi_notes.len().max(1) as f32);
        for (i, slot) in out.iter_mut().enumerate() {
            let t = i as f64 / sample_rate;
            let mut sum = 0.0f64;
            for &m in midi_notes {
                let freq = 440.0 * 2f64.powf((m as f64 - 69.0) / 12.0);
                // Mild envelope attack at chord onset to mimic plucked/strummed transient
                let env = if t < 0.03 { t / 0.03 } else { 1.0 };
                sum += env * ((2.0 * PI * freq * t).sin() + 0.25 * (4.0 * PI * freq * t).sin());
            }
            *slot = (sum as f32) * note_amp;
        }
        out
    }

    #[test]
    fn test_progression_c_g_am_f_and_key() {
        let sr = 22_050.0;
        let mut pcm = Vec::new();
        // C -> G -> Am -> F (2.0s each)
        pcm.extend(synth_chord(&[48, 55, 60, 64, 67], sr, 2.0, 0.5)); // C
        pcm.extend(synth_chord(&[43, 55, 59, 62, 67], sr, 2.0, 0.5)); // G
        pcm.extend(synth_chord(&[45, 57, 60, 64, 69], sr, 2.0, 0.5)); // Am
        pcm.extend(synth_chord(&[41, 53, 57, 60, 65], sr, 2.0, 0.5)); // F

        unsafe {
            let res_ptr = sc_analyze_pcm(pcm.as_ptr(), pcm.len(), sr, 1, 8.0);
            assert!(!res_ptr.is_null());
            let res = &*res_ptr;
            let segs = slice::from_raw_parts(res.segments, res.segment_count);

            let simplified: Vec<(i32, i32)> = segs.iter().map(|s| (s.root, s.quality)).collect();
            assert_eq!(
                simplified,
                vec![(0, 0), (7, 0), (9, 1), (5, 0)],
                "expected C -> G -> Am -> F, got {:?}",
                segs
            );
            assert_eq!(res.has_key, 1);
            assert_eq!(res.key_root, 0); // C
            assert_eq!(res.key_is_minor, 0); // Major

            let beats = slice::from_raw_parts(res.beats, res.beat_count);
            assert!(!beats.is_empty());
            assert_eq!(beats[0].bar_index, 0);
            assert_eq!(beats[0].beat_index, 0);
            assert_eq!(beats[0].is_chord_change, 1);
            assert!(beats.iter().any(|b| b.root == 7));

            sc_free_timeline(res_ptr);
        }
    }

    #[test]
    fn test_extended_g7_and_simple_g() {
        let sr = 22_050.0;
        let pcm = synth_chord(&[43, 55, 59, 62, 65], sr, 2.5, 0.5); // G7: G, B, D, F

        unsafe {
            let ext_ptr = sc_analyze_pcm(pcm.as_ptr(), pcm.len(), sr, 0, 2.5);
            let ext = &*ext_ptr;
            let ext_segs = slice::from_raw_parts(ext.segments, ext.segment_count);
            assert_eq!(ext_segs.len(), 1);
            assert_eq!(ext_segs[0].root, 7); // G
            assert_eq!(ext_segs[0].quality, 2); // dominant 7
            sc_free_timeline(ext_ptr);

            let sim_ptr = sc_analyze_pcm(pcm.as_ptr(), pcm.len(), sr, 1, 2.5);
            let sim = &*sim_ptr;
            let sim_segs = slice::from_raw_parts(sim.segments, sim.segment_count);
            assert_eq!(sim_segs.len(), 1);
            assert_eq!(sim_segs[0].root, 7); // G
            assert_eq!(sim_segs[0].quality, 0); // major
            sc_free_timeline(sim_ptr);
        }
    }

    #[test]
    fn test_silence_gate_offline_and_realtime() {
        let sr = 22_050.0;
        let silence = vec![0.0f32; 44_100];

        unsafe {
            let res_ptr = sc_analyze_pcm(silence.as_ptr(), silence.len(), sr, 1, 2.0);
            let res = &*res_ptr;
            assert_eq!(res.segment_count, 0);
            assert_eq!(res.has_key, 0);
            let beats = slice::from_raw_parts(res.beats, res.beat_count);
            assert!(beats.iter().all(|b| b.root == -1));
            sc_free_timeline(res_ptr);

            let rt = sc_realtime_new();
            sc_realtime_ingest(rt, silence.as_ptr(), silence.len(), sr);
            let snap = sc_realtime_analyze(rt, 0);
            assert_eq!(snap.has_chord, 0);
            assert_eq!(snap.has_key, 0);
            assert!(snap.chroma.iter().all(|&c| c == 0.0));
            sc_realtime_free(rt);
        }
    }

    #[test]
    fn test_bpm_and_beat_grid_120bpm() {
        let sr = 22_050.0;
        let total_sec = 8.0;
        let total_samples = (sr * total_sec) as usize;
        let mut pcm = vec![0.0f32; total_samples];
        let beat_period = 0.5; // 120 BPM

        // 120 BPM plucked C major stabs every 0.5s
        for b in 0..16 {
            let start_sample = ((b as f64) * beat_period * sr) as usize;
            let stab_len = (0.35 * sr) as usize;
            for i in 0..stab_len {
                if start_sample + i >= total_samples {
                    break;
                }
                let t = i as f64 / sr;
                let decay = (-10.0 * t).exp();
                let sig = (2.0 * PI * 130.81 * t).sin()
                    + (2.0 * PI * 261.63 * t).sin()
                    + (2.0 * PI * 329.63 * t).sin()
                    + (2.0 * PI * 392.00 * t).sin();
                pcm[start_sample + i] += (0.15 * decay * sig) as f32;
            }
        }

        unsafe {
            let res_ptr = sc_analyze_pcm(pcm.as_ptr(), pcm.len(), sr, 1, total_sec);
            let res = &*res_ptr;
            assert!(
                (res.bpm - 120.0).abs() <= 5.0,
                "expected ~120 BPM, got {}",
                res.bpm
            );
            assert_eq!(res.beats_per_bar, 4);
            assert!(res.beat_count >= 14);
            sc_free_timeline(res_ptr);
        }
    }

    #[test]
    fn test_realtime_chord_tracking_and_reset() {
        let sr = 44_100.0;
        let c_maj = synth_chord(&[48, 55, 60, 64, 67], sr, 0.5, 0.5);
        let a_min = synth_chord(&[45, 57, 60, 64, 69], sr, 0.5, 0.5);

        unsafe {
            let rt = sc_realtime_new();
            sc_realtime_ingest(rt, c_maj.as_ptr(), c_maj.len(), sr);
            let snap_c = sc_realtime_analyze(rt, 1);
            assert_eq!(snap_c.has_chord, 1);
            assert_eq!(snap_c.root, 0); // C
            assert_eq!(snap_c.quality, 0); // Maj

            // Feed enough Am to cross EMA + 2-frame hysteresis
            for _ in 0..4 {
                sc_realtime_ingest(rt, a_min.as_ptr(), a_min.len(), sr);
                let _ = sc_realtime_analyze(rt, 1);
            }
            let snap_am = sc_realtime_analyze(rt, 1);
            assert_eq!(snap_am.has_chord, 1);
            assert_eq!(snap_am.root, 9); // A
            assert_eq!(snap_am.quality, 1); // Min

            sc_realtime_reset(rt);
            let snap_reset = sc_realtime_analyze(rt, 1);
            assert_eq!(snap_reset.has_chord, 0);
            sc_realtime_free(rt);
        }
    }
}
