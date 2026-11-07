//! Reproducible, test-only comparison with the unmodified fst 0.4.7 crate.
//!
//! Dataset preparation, sorting, reference verification, owned-entry hashes,
//! JSON serialization, and destruction of the final result are outside the
//! timer. Lookup sums/counts consume lookup results inside the timer, without
//! allocating a result array.
//! Each measurement performs one complete operation; there is no adaptive
//! batching. Run this binary with `cargo run --release --bin fst_bench`.

use fst::{IntoStreamer, Map, MapBuilder, Streamer};
use serde_json::{json, Value};
use std::env;
use std::hint::black_box;
use std::time::Instant;

const SEED: u32 = 0x00c0_ffee;
const FNV_OFFSET: u64 = 14_695_981_039_346_656_037;
const FNV_PRIME: u64 = 1_099_511_628_211;
type Entry = (Vec<u8>, u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Shape {
    Shared,
    Random,
}

impl Shape {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "shared" => Ok(Self::Shared),
            "random" => Ok(Self::Random),
            _ => Err("MOONFST_BENCH_SHAPE must be shared or random".into()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Shared => "shared",
            Self::Random => "random",
        }
    }
}

#[derive(Debug)]
struct Config {
    n: usize,
    shape: Shape,
    samples: usize,
    warmups: usize,
}

impl Config {
    fn validate(&self) -> Result<(), String> {
        if self.n < 2 || self.n % 2 != 0 {
            return Err("MOONFST_BENCH_N must be an even integer of at least 2".into());
        }
        // The specified random suffix and shared hexadecimal index are u32.
        if self.n.checked_add(self.n / 2).is_none()
            || (self.n as u128 + self.n as u128 / 2) > u32::MAX as u128 + 1
        {
            return Err("MOONFST_BENCH_N exceeds the 32-bit dataset index range".into());
        }
        if self.samples == 0 {
            return Err("MOONFST_BENCH_SAMPLES must be at least 1".into());
        }
        Ok(())
    }

    fn from_env() -> Result<Self, String> {
        fn integer(name: &str, default: usize) -> Result<usize, String> {
            match env::var(name) {
                Ok(value) => value
                    .parse::<usize>()
                    .map_err(|_| format!("{name} must be a nonnegative integer")),
                Err(env::VarError::NotPresent) => Ok(default),
                Err(error) => Err(format!("{name}: {error}")),
            }
        }
        let config = Self {
            n: integer("MOONFST_BENCH_N", 10_000)?,
            shape: Shape::parse(
                &env::var("MOONFST_BENCH_SHAPE").unwrap_or_else(|_| "shared".into()),
            )?,
            samples: integer("MOONFST_BENCH_SAMPLES", 7)?,
            warmups: integer("MOONFST_BENCH_WARMUPS", 2)?,
        };
        config.validate()?;
        Ok(config)
    }
}

struct Dataset {
    a: Vec<Entry>,
    b: Vec<Entry>,
    union: Vec<Entry>,
}

fn generate(config: &Config) -> Dataset {
    let mut state = SEED;
    let mut a = Vec::new();
    let mut b = Vec::new();
    let mut union = Vec::new();
    for index in 0..config.n + config.n / 2 {
        let i = index as u32;
        let key = match config.shape {
            Shape::Shared => {
                let mut key = b"catalog/".to_vec();
                key.push((i % 64) as u8);
                key.extend_from_slice(b"/item/");
                key.extend_from_slice(format!("{i:08x}").as_bytes());
                key.extend_from_slice(b"/meta");
                key
            }
            Shape::Random => {
                let mut key = Vec::new();
                for _ in 0..12 {
                    state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    key.push((state >> 24) as u8);
                }
                key.extend_from_slice(&i.to_be_bytes());
                key
            }
        };
        let entry = (
            key,
            ((i as u64) << 32) | i.wrapping_mul(2_654_435_761) as u64,
        );
        if index < config.n {
            a.push(entry.clone());
        }
        if index >= config.n / 2 {
            b.push(entry.clone());
        }
        union.push(entry);
    }
    for entries in [&mut a, &mut b, &mut union] {
        entries.sort_unstable_by(|left, right| left.0.cmp(&right.0));
        assert!(entries.windows(2).all(|pair| pair[0].0 < pair[1].0));
    }
    Dataset { a, b, union }
}

fn fnv_byte(hash: u64, byte: u8) -> u64 {
    (hash ^ byte as u64).wrapping_mul(FNV_PRIME)
}

fn entries_hash(entries: &[Entry]) -> u64 {
    let mut hash = FNV_OFFSET;
    for (key, value) in entries {
        for &byte in key {
            hash = fnv_byte(hash, byte);
        }
        for byte in (key.len() as u32).to_le_bytes() {
            hash = fnv_byte(hash, byte);
        }
        for byte in value.to_le_bytes() {
            hash = fnv_byte(hash, byte);
        }
    }
    hash
}

fn build(entries: &[Entry]) -> Vec<u8> {
    let mut builder = MapBuilder::memory();
    for (key, value) in entries {
        builder.insert(key, *value).expect("sorted unique input");
    }
    // Deliberately exclude Map::new and CRC/full graph validation.
    builder.into_inner().expect("in-memory builder")
}

fn stream_owned(map: &Map<Vec<u8>>) -> Vec<Entry> {
    let mut stream = map.stream();
    let mut result = Vec::new();
    while let Some((key, value)) = stream.next() {
        result.push((key.to_vec(), value));
    }
    result
}

struct PrefixBounds {
    lower: Vec<u8>,
    upper: Vec<u8>,
}

fn prefix_bounds(shape: Shape) -> Vec<PrefixBounds> {
    (0..32)
        .map(|byte| {
            let lower = match shape {
                Shape::Shared => {
                    let mut prefix = b"catalog/".to_vec();
                    prefix.push(byte);
                    prefix.push(b'/');
                    prefix
                }
                Shape::Random => vec![byte],
            };
            let mut upper = lower.clone();
            *upper.last_mut().expect("nonempty prefix") += 1;
            PrefixBounds { lower, upper }
        })
        .collect()
}

fn prefix_owned(map: &Map<Vec<u8>>, bounds: &[PrefixBounds]) -> Vec<Entry> {
    let mut result = Vec::new();
    for bound in bounds {
        let mut stream = map.range().ge(&bound.lower).lt(&bound.upper).into_stream();
        let mut batch = Vec::new();
        while let Some((key, value)) = stream.next() {
            batch.push((key.to_vec(), value));
        }
        result.extend(batch);
    }
    result
}

fn union_owned(a: &Map<Vec<u8>>, b: &Map<Vec<u8>>) -> Vec<Entry> {
    let mut stream = a.op().add(b).union();
    let mut result = Vec::new();
    while let Some((key, values)) = stream.next() {
        // Upstream preserves source indices; do not depend on heap tie order.
        let value = values
            .iter()
            .min_by_key(|value| value.index)
            .expect("union value")
            .value;
        result.push((key.to_vec(), value));
    }
    result
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Summary {
    checksum: u64,
    count: usize,
}

fn owned_summary(entries: &[Entry]) -> Summary {
    Summary {
        checksum: entries_hash(entries),
        count: entries.len(),
    }
}

fn measure<T>(
    name: &str,
    config: &Config,
    expected: Summary,
    mut operation: impl FnMut() -> T,
    summarize: impl Fn(&T) -> Summary,
) -> Value {
    for _ in 0..config.warmups {
        let result = black_box(operation());
        assert_eq!(summarize(&result), expected, "{name} warmup mismatch");
        drop(result);
    }
    let mut samples_us = Vec::new();
    for _ in 0..config.samples {
        let start = Instant::now();
        let result = black_box(operation());
        let elapsed = start.elapsed();
        // Keep ownership alive through the end of timing. Hashes and the final
        // result's destructor run before the next clock starts.
        assert_eq!(summarize(&result), expected, "{name} sample mismatch");
        drop(result);
        samples_us.push(elapsed.as_secs_f64() * 1_000_000.0);
    }
    json!({
        "name": name,
        "samples_us": samples_us,
        "checksum": expected.checksum.to_string(),
        "result_count": expected.count,
    })
}

fn run(config: &Config) -> Value {
    let dataset = generate(config);
    let bytes_a = build(&dataset.a);
    let bytes_b = build(&dataset.b);
    let fst_bytes = bytes_a.len();
    let a = Map::new(bytes_a).expect("reference map A");
    let b = Map::new(bytes_b).expect("reference map B");
    a.as_fst().verify().expect("reference CRC A");
    b.as_fst().verify().expect("reference CRC B");
    assert_eq!(stream_owned(&a), dataset.a);
    assert_eq!(stream_owned(&b), dataset.b);
    let misses: Vec<Vec<u8>> = dataset
        .a
        .iter()
        .map(|(key, _)| {
            let mut key = key.clone();
            key.push(0xff);
            key
        })
        .collect();
    assert!(misses.iter().all(|key| a.get(key).is_none()));
    let bounds = prefix_bounds(config.shape);
    let expected_prefix: Vec<Entry> = dataset
        .a
        .iter()
        .filter(|(key, _)| {
            bounds
                .iter()
                .any(|bound| key >= &bound.lower && key < &bound.upper)
        })
        .cloned()
        .collect();
    assert_eq!(prefix_owned(&a, &bounds), expected_prefix);
    assert_eq!(union_owned(&a, &b), dataset.union);

    let mut metrics = Vec::new();
    metrics.push(measure(
        "build",
        config,
        Summary {
            checksum: fst_bytes as u64,
            count: config.n,
        },
        || build(black_box(&dataset.a)),
        |bytes| {
            // This comparison runs after the timer for every sample and
            // warmup. The reference was opened, CRC-checked, and fully
            // decoded above; matching length alone cannot prove correctness.
            assert_eq!(
                bytes.as_slice(),
                a.as_fst().as_bytes(),
                "build output differs from reference"
            );
            Summary {
                checksum: bytes.len() as u64,
                count: config.n,
            }
        },
    ));
    metrics.push(measure(
        "lookup_hit",
        config,
        Summary {
            checksum: dataset
                .a
                .iter()
                .fold(0u64, |sum, (_, value)| sum.wrapping_add(*value)),
            count: config.n,
        },
        || {
            let map = black_box(&a);
            let mut checksum = 0u64;
            for (key, _) in black_box(&dataset.a) {
                checksum = checksum.wrapping_add(map.get(black_box(key)).expect("lookup hit"));
            }
            Summary {
                checksum,
                count: config.n,
            }
        },
        |summary| *summary,
    ));
    metrics.push(measure(
        "lookup_miss",
        config,
        Summary {
            checksum: 0,
            count: 0,
        },
        || {
            let map = black_box(&a);
            let mut count = 0;
            for key in black_box(&misses) {
                if map.get(black_box(key)).is_some() {
                    count += 1;
                }
            }
            Summary {
                checksum: count as u64,
                count,
            }
        },
        |summary| *summary,
    ));
    metrics.push(measure(
        "stream_owned",
        config,
        owned_summary(&dataset.a),
        || stream_owned(black_box(&a)),
        |entries| owned_summary(entries),
    ));
    metrics.push(measure(
        "prefix_owned",
        config,
        owned_summary(&expected_prefix),
        || prefix_owned(black_box(&a), black_box(&bounds)),
        |entries| owned_summary(entries),
    ));
    metrics.push(measure(
        "union_owned",
        config,
        owned_summary(&dataset.union),
        || union_owned(black_box(&a), black_box(&b)),
        |entries| owned_summary(entries),
    ));
    json!({
        "schema": 1,
        "engine": "rust",
        "shape": config.shape.as_str(),
        "n": config.n,
        "samples": config.samples,
        "warmups": config.warmups,
        "seed": SEED,
        "dataset_hash": entries_hash(&dataset.a).to_string(),
        "input_key_bytes": dataset.a.iter().map(|(key, _)| key.len()).sum::<usize>(),
        "fst_bytes": fst_bytes,
        "metrics": metrics,
    })
}

fn main() {
    match Config::from_env() {
        Ok(config) => println!("{}", run(&config)),
        Err(error) => {
            eprintln!("fst_bench: {error}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(shape: Shape, n: usize) -> Config {
        Config {
            n,
            shape,
            samples: 1,
            warmups: 0,
        }
    }

    #[test]
    fn shared_generator_matches_independent_golden() {
        let dataset = generate(&config(Shape::Shared, 2));
        assert_eq!(dataset.a.len(), 2);
        assert_eq!(dataset.b.len(), 2);
        assert_eq!(dataset.union.len(), 3);
        assert_eq!(
            dataset.a[0],
            (b"catalog/\x00/item/00000000/meta".to_vec(), 0)
        );
        assert_eq!(
            dataset.a[1],
            (b"catalog/\x01/item/00000001/meta".to_vec(), 6_949_403_057)
        );
        assert_eq!(dataset.union[2].1, 9_603_838_818);
        assert_eq!(entries_hash(&dataset.a), 13_146_377_713_594_168_491);
    }

    #[test]
    fn random_generator_matches_independent_golden() {
        let dataset = generate(&config(Shape::Random, 2));
        assert_eq!(
            dataset.a[0].0,
            [0x2a, 0x80, 0x78, 0x94, 0x31, 0x2f, 0x12, 0x3f, 0x43, 0xd4, 0xe6, 0x87, 0, 0, 0, 0]
        );
        assert_eq!(
            dataset.a[1].0,
            [0x99, 0x75, 0x07, 0x55, 0x0a, 0x63, 0xe6, 0x9b, 0xdf, 0xb0, 0xb0, 0xc9, 0, 0, 0, 1]
        );
        assert_eq!(entries_hash(&dataset.a), 10_656_632_618_923_367_303);
    }

    #[test]
    fn configuration_boundaries_are_checked() {
        assert!(config(Shape::Shared, 0).validate().is_err());
        assert!(config(Shape::Shared, 1).validate().is_err());
        assert!(config(Shape::Shared, 3).validate().is_err());
        assert!(config(Shape::Shared, 2).validate().is_ok());
        assert!(Config {
            samples: 0,
            ..config(Shape::Shared, 2)
        }
        .validate()
        .is_err());
        assert!(config(Shape::Shared, usize::MAX - 1).validate().is_err());
        assert_eq!(Shape::parse("random"), Ok(Shape::Random));
        assert!(Shape::parse("unknown").is_err());
    }

    #[test]
    fn tiny_both_shapes_validate_all_operations() {
        for shape in [Shape::Shared, Shape::Random] {
            let report = run(&Config {
                warmups: 1,
                ..config(shape, 2)
            });
            assert_eq!(report["schema"], 1);
            assert_eq!(report["metrics"].as_array().unwrap().len(), 6);
            assert_eq!(report["metrics"][1]["result_count"], 2);
            assert_eq!(report["metrics"][2]["result_count"], 0);
            assert_eq!(report["metrics"][5]["result_count"], 3);
        }
    }
}
