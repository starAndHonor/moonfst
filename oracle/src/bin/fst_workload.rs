//! Development-only corpus benchmark. The production crate and fst_bench are unchanged.
//!
//! The binary corpus, sorting, query preparation, checks, owned-output hashes,
//! and destruction of each final result are outside timing. Memory snapshots
//! report process RSS/HWM, including retained input and allocator state.

use fst::{Map, MapBuilder, Streamer};
use serde_json::{json, Value};
use std::env;
use std::fs;
use std::hint::black_box;
use std::path::PathBuf;
use std::time::Instant;

type Entry = (Vec<u8>, u64);
const MAGIC: &[u8; 8] = b"MFSTW001";
const FNV_OFFSET: u64 = 14_695_981_039_346_656_037;
const FNV_PRIME: u64 = 1_099_511_628_211;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Order {
    Sorted,
    Shuffled,
}

impl Order {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "sorted" => Ok(Self::Sorted),
            "shuffled" => Ok(Self::Shuffled),
            _ => Err("MOONFST_WORKLOAD_ORDER must be sorted or shuffled".into()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Sorted => "sorted",
            Self::Shuffled => "shuffled",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Timing,
    MemoryBaseline,
    MemoryBuild,
    MemoryLoad,
    MemoryUnion,
}

impl Mode {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "timing" => Ok(Self::Timing),
            "memory-baseline" => Ok(Self::MemoryBaseline),
            "memory-build" => Ok(Self::MemoryBuild),
            "memory-load" => Ok(Self::MemoryLoad),
            "memory-union" => Ok(Self::MemoryUnion),
            _ => Err("MOONFST_WORKLOAD_MODE is not a supported workload mode".into()),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Timing => "timing",
            Self::MemoryBaseline => "memory-baseline",
            Self::MemoryBuild => "memory-build",
            Self::MemoryLoad => "memory-load",
            Self::MemoryUnion => "memory-union",
        }
    }
}

struct Config {
    mode: Mode,
    order: Order,
    query_seed: u32,
    samples: usize,
    warmups: usize,
}

fn integer(name: &str, default: usize) -> Result<usize, String> {
    match env::var(name) {
        Ok(value) => value
            .parse()
            .map_err(|_| format!("{name} must be a nonnegative integer")),
        Err(env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(format!("{name}: {error}")),
    }
}

fn required_path(name: &str) -> Result<PathBuf, String> {
    env::var_os(name)
        .map(PathBuf::from)
        .ok_or_else(|| format!("{name} is required"))
}

impl Config {
    fn from_env() -> Result<Self, String> {
        let samples = integer("MOONFST_WORKLOAD_SAMPLES", 7)?;
        let warmups = integer("MOONFST_WORKLOAD_WARMUPS", 2)?;
        if samples == 0 || samples.checked_add(warmups).is_none() {
            return Err("SAMPLES must be positive and SAMPLES + WARMUPS must fit usize".into());
        }
        let seed = integer("MOONFST_WORKLOAD_QUERY_SEED", 305_419_896)?;
        let query_seed = u32::try_from(seed).map_err(|_| "QUERY_SEED must fit u32")?;
        Ok(Self {
            mode: Mode::parse(
                &env::var("MOONFST_WORKLOAD_MODE").unwrap_or_else(|_| "timing".into()),
            )?,
            order: Order::parse(
                &env::var("MOONFST_WORKLOAD_ORDER").unwrap_or_else(|_| "sorted".into()),
            )?,
            query_seed,
            samples,
            warmups,
        })
    }
}

struct Dataset {
    // Retained through memory snapshots; the parser does not consume the file.
    raw: Vec<u8>,
    a: Vec<Entry>,
    b: Vec<Entry>,
    union: Vec<Entry>,
}

fn take<'a>(data: &'a [u8], at: &mut usize, count: usize) -> Result<&'a [u8], String> {
    let end = at.checked_add(count).ok_or("corpus offset overflow")?;
    let bytes = data.get(*at..end).ok_or("truncated workload corpus")?;
    *at = end;
    Ok(bytes)
}

fn read_u32(data: &[u8], at: &mut usize) -> Result<u32, String> {
    Ok(u32::from_le_bytes(take(data, at, 4)?.try_into().unwrap()))
}

fn read_u64(data: &[u8], at: &mut usize) -> Result<u64, String> {
    Ok(u64::from_le_bytes(take(data, at, 8)?.try_into().unwrap()))
}

fn check_n(n: usize) -> Result<(), String> {
    if n < 2 || n % 2 != 0 {
        return Err("workload N must be even and at least 2".into());
    }
    Ok(())
}

fn parse_dataset(raw: Vec<u8>) -> Result<Dataset, String> {
    let mut at = 0;
    if take(&raw, &mut at, 8)? != MAGIC {
        return Err("invalid workload corpus magic".into());
    }
    let n = read_u32(&raw, &mut at)? as usize;
    let total = read_u32(&raw, &mut at)? as usize;
    check_n(n)?;
    if n.checked_add(n / 2) != Some(total) {
        return Err("corpus total must equal 3*N/2".into());
    }
    // Each record has a 12-byte prefix even when its key is empty.
    if total > (raw.len() - at) / 12 {
        return Err("record count exceeds remaining corpus bytes".into());
    }
    let mut all = Vec::new();
    for _ in 0..total {
        let length = read_u32(&raw, &mut at)? as usize;
        let value = read_u64(&raw, &mut at)?;
        let key = take(&raw, &mut at, length)?.to_vec();
        all.push((key, value));
    }
    if at != raw.len() {
        return Err("trailing workload corpus bytes".into());
    }
    let mut a = all[..n].to_vec();
    let mut b = all[n / 2..].to_vec();
    for records in [&mut a, &mut b, &mut all] {
        records.sort_unstable_by(|left, right| left.0.cmp(&right.0));
    }
    if !all.windows(2).all(|pair| pair[0].0 < pair[1].0) {
        return Err("workload corpus keys must be globally unique".into());
    }
    Ok(Dataset {
        raw,
        a,
        b,
        union: all,
    })
}

fn read_dataset() -> Result<Dataset, String> {
    let input = required_path("MOONFST_WORKLOAD_INPUT")?;
    parse_dataset(fs::read(&input).map_err(|error| format!("{}: {error}", input.display()))?)
}

fn fnv_byte(hash: u64, byte: u8) -> u64 {
    (hash ^ byte as u64).wrapping_mul(FNV_PRIME)
}

fn hash_record(mut hash: u64, key: &[u8], value: u64) -> u64 {
    for &byte in key {
        hash = fnv_byte(hash, byte);
    }
    for byte in (key.len() as u32).to_le_bytes() {
        hash = fnv_byte(hash, byte);
    }
    for byte in value.to_le_bytes() {
        hash = fnv_byte(hash, byte);
    }
    hash
}

fn entries_hash(records: &[Entry]) -> u64 {
    records.iter().fold(FNV_OFFSET, |hash, (key, value)| {
        hash_record(hash, key, *value)
    })
}

fn query_order(n: usize, order: Order, mut state: u32) -> Vec<usize> {
    let mut indices: Vec<usize> = (0..n).collect();
    if order == Order::Shuffled {
        for i in (1..n).rev() {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let j = state as usize % (i + 1);
            indices.swap(i, j);
        }
    }
    indices
}

struct Queries {
    hits: Vec<Vec<u8>>,
    misses: Vec<Vec<u8>>,
    mixed: Vec<Vec<u8>>,
    order_hash: u64,
    hit_sum: u64,
    mixed_sum: u64,
}

fn prepare_queries(dataset: &Dataset, config: &Config) -> Queries {
    let order = query_order(dataset.a.len(), config.order, config.query_seed);
    let mut hits = Vec::new();
    let mut misses = Vec::new();
    let mut mixed = Vec::new();
    let mut order_hash = FNV_OFFSET;
    let mut hit_sum = 0u64;
    let mut mixed_sum = 0u64;
    for (position, &index) in order.iter().enumerate() {
        let (key, value) = &dataset.a[index];
        order_hash = hash_record(order_hash, key, *value);
        hit_sum = hit_sum.wrapping_add(*value);
        if position % 2 == 0 {
            mixed_sum = mixed_sum.wrapping_add(*value);
        }
        let mut miss = key.clone();
        miss.push(0xff);
        mixed.push(if position % 2 == 0 {
            key.clone()
        } else {
            miss.clone()
        });
        hits.push(key.clone());
        misses.push(miss);
    }
    Queries {
        hits,
        misses,
        mixed,
        order_hash,
        hit_sum,
        mixed_sum,
    }
}

fn build(records: &[Entry]) -> Vec<u8> {
    let mut builder = MapBuilder::memory();
    for (key, value) in records {
        builder.insert(key, *value).expect("sorted unique corpus");
    }
    builder.into_inner().expect("in-memory builder")
}

fn stream_owned(map: &Map<Vec<u8>>) -> Vec<Entry> {
    let mut stream = map.stream();
    let mut output = Vec::new();
    while let Some((key, value)) = stream.next() {
        output.push((key.to_vec(), value));
    }
    output
}

fn union_owned(a: &Map<Vec<u8>>, b: &Map<Vec<u8>>) -> Vec<Entry> {
    let mut stream = a.op().add(b).union();
    let mut output = Vec::new();
    while let Some((key, values)) = stream.next() {
        let value = values
            .iter()
            .min_by_key(|value| value.index)
            .expect("nonempty union group")
            .value;
        output.push((key.to_vec(), value));
    }
    output
}

fn validated_map(bytes: Vec<u8>, expected: &[Entry]) -> Map<Vec<u8>> {
    let map = Map::new(bytes).expect("reference map");
    map.as_fst().verify().expect("reference CRC");
    assert_eq!(stream_owned(&map), expected, "reference full records");
    map
}

fn write_fst(map: &Map<Vec<u8>>) -> Result<(), String> {
    if let Some(path) = env::var_os("MOONFST_WORKLOAD_WRITE_FST") {
        let path = PathBuf::from(path);
        fs::write(&path, map.as_fst().as_bytes())
            .map_err(|error| format!("{}: {error}", path.display()))?;
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Summary {
    checksum: u64,
    count: usize,
}

fn owned_summary(records: &[Entry]) -> Summary {
    Summary {
        checksum: entries_hash(records),
        count: records.len(),
    }
}

fn lookup(map: &Map<Vec<u8>>, keys: &[Vec<u8>]) -> Summary {
    let map = black_box(map);
    let mut checksum = 0u64;
    let mut count = 0;
    for key in black_box(keys) {
        if let Some(value) = map.get(black_box(key)) {
            checksum = checksum.wrapping_add(value);
            count += 1;
        }
    }
    Summary { checksum, count }
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
        assert_eq!(summarize(&result), expected, "{name} sample mismatch");
        drop(result);
        samples_us.push(elapsed.as_secs_f64() * 1_000_000.0);
    }
    json!({"name": name, "samples_us": samples_us,
        "checksum": expected.checksum.to_string(), "result_count": expected.count})
}

fn timing(config: &Config, dataset: &Dataset) -> Result<Value, String> {
    let a = validated_map(build(&dataset.a), &dataset.a);
    let b = validated_map(build(&dataset.b), &dataset.b);
    let queries = prepare_queries(dataset, config);
    let indices = query_order(dataset.a.len(), config.order, config.query_seed);
    for (position, &index) in indices.iter().enumerate() {
        let (key, value) = &dataset.a[index];
        assert_eq!(&queries.hits[position], key, "prepared hit order");
        assert_eq!(a.get(&queries.hits[position]), Some(*value));
        let mut miss = key.clone();
        miss.push(0xff);
        assert_eq!(queries.misses[position], miss, "prepared miss order");
        assert_eq!(a.get(&queries.misses[position]), None, "FF key must miss");
        let expected_key = if position % 2 == 0 {
            key
        } else {
            &queries.misses[position]
        };
        assert_eq!(
            &queries.mixed[position], expected_key,
            "prepared mixed order"
        );
        assert_eq!(
            a.get(&queries.mixed[position]),
            if position % 2 == 0 {
                Some(*value)
            } else {
                None
            }
        );
    }
    assert!(
        queries.misses.iter().all(|key| a.get(key).is_none()),
        "appending FF must produce a missing key for this corpus"
    );
    assert_eq!(union_owned(&a, &b), dataset.union);
    write_fst(&a)?;
    let n = dataset.a.len();
    let fst_bytes = a.as_fst().as_bytes().len();
    let metrics = vec![
        measure(
            "build",
            config,
            Summary {
                checksum: fst_bytes as u64,
                count: n,
            },
            || build(black_box(&dataset.a)),
            |bytes| {
                assert_eq!(
                    bytes.as_slice(),
                    a.as_fst().as_bytes(),
                    "build reference bytes"
                );
                Summary {
                    checksum: bytes.len() as u64,
                    count: n,
                }
            },
        ),
        measure(
            "lookup_hit",
            config,
            Summary {
                checksum: queries.hit_sum,
                count: n,
            },
            || lookup(&a, &queries.hits),
            |summary| *summary,
        ),
        measure(
            "lookup_miss",
            config,
            Summary {
                checksum: 0,
                count: 0,
            },
            || lookup(&a, &queries.misses),
            |summary| *summary,
        ),
        measure(
            "lookup_mixed",
            config,
            Summary {
                checksum: queries.mixed_sum,
                count: n / 2,
            },
            || lookup(&a, &queries.mixed),
            |summary| *summary,
        ),
        measure(
            "stream_owned",
            config,
            owned_summary(&dataset.a),
            || stream_owned(black_box(&a)),
            |records| {
                assert_eq!(
                    records.as_slice(),
                    dataset.a.as_slice(),
                    "stream sample records"
                );
                owned_summary(records)
            },
        ),
        measure(
            "union_owned",
            config,
            owned_summary(&dataset.union),
            || union_owned(black_box(&a), black_box(&b)),
            |records| {
                assert_eq!(
                    records.as_slice(),
                    dataset.union.as_slice(),
                    "union sample records"
                );
                owned_summary(records)
            },
        ),
    ];
    Ok(
        json!({"schema": 1, "engine": "rust", "mode": "timing", "n": n,
        "total": dataset.union.len(), "order": config.order.as_str(), "query_seed": config.query_seed,
        "order_hash": queries.order_hash.to_string(), "dataset_hash": entries_hash(&dataset.a).to_string(),
        "b_hash": entries_hash(&dataset.b).to_string(),
        "union_hash": entries_hash(&dataset.union).to_string(), "fst_bytes": fst_bytes,
        "input_key_bytes": dataset.a.iter().map(|(key, _)| key.len()).sum::<usize>(),
        "samples": config.samples, "warmups": config.warmups, "metrics": metrics}),
    )
}

#[derive(Clone, Copy)]
struct Rss {
    current: u64,
    peak: u64,
}

fn rss_snapshot() -> Result<Rss, String> {
    let status = fs::read_to_string("/proc/self/status")
        .map_err(|error| format!("Linux RSS snapshot: {error}"))?;
    let mut current = None;
    let mut peak = None;
    for line in status.lines() {
        let target = if line.starts_with("VmRSS:") {
            &mut current
        } else if line.starts_with("VmHWM:") {
            &mut peak
        } else {
            continue;
        };
        let mut fields = line.split_whitespace();
        fields.next();
        let number = fields.next().ok_or("missing RSS value")?;
        if fields.next() != Some("kB") {
            return Err("RSS snapshot must use Linux KiB units".into());
        }
        *target = Some(number.parse::<u64>().map_err(|_| "invalid RSS value")?);
    }
    Ok(Rss {
        current: current.ok_or("VmRSS unavailable")?,
        peak: peak.ok_or("VmHWM unavailable")?,
    })
}

fn memory_report(
    mode: Mode,
    n: usize,
    fst_bytes: usize,
    summary: Summary,
    baseline: Rss,
    after: Rss,
    validation: Rss,
) -> Value {
    json!({"schema": 1, "engine": "rust", "mode": mode.as_str(), "n": n,
        "memory_source": "proc-self-status",
        "fst_bytes": fst_bytes, "checksum": summary.checksum.to_string(), "result_count": summary.count,
        "baseline_rss_kib": baseline.current, "baseline_peak_rss_kib": baseline.peak,
        "after_rss_kib": after.current, "peak_rss_kib": after.peak,
        "validation_after_rss_kib": validation.current, "validation_peak_rss_kib": validation.peak})
}

fn memory_dataset(mode: Mode, dataset: &Dataset) -> Result<Value, String> {
    let n = dataset.a.len();
    match mode {
        Mode::MemoryBaseline => {
            let baseline = rss_snapshot()?;
            let summary = owned_summary(&dataset.a);
            black_box((&dataset.raw, &dataset.a, &dataset.b, &dataset.union));
            Ok(memory_report(
                mode, n, 0, summary, baseline, baseline, baseline,
            ))
        }
        Mode::MemoryBuild => {
            let baseline = rss_snapshot()?;
            let bytes = build(&dataset.a);
            let fst_bytes = bytes.len();
            let after = rss_snapshot()?;
            black_box(&bytes);
            let map = Map::new(bytes).expect("memory build map");
            map.as_fst().verify().expect("memory build CRC");
            let records = stream_owned(&map);
            assert_eq!(records, dataset.a, "memory build reference");
            let summary = owned_summary(&records);
            let validation = rss_snapshot()?;
            write_fst(&map)?;
            black_box((
                &dataset.raw,
                &dataset.a,
                &dataset.b,
                &dataset.union,
                &map,
                &records,
            ));
            Ok(memory_report(
                mode, n, fst_bytes, summary, baseline, after, validation,
            ))
        }
        Mode::MemoryUnion => {
            let a = validated_map(build(&dataset.a), &dataset.a);
            let b = validated_map(build(&dataset.b), &dataset.b);
            let fst_bytes = a.as_fst().as_bytes().len();
            let baseline = rss_snapshot()?;
            let output = union_owned(&a, &b);
            let after = rss_snapshot()?;
            let summary = owned_summary(&output);
            assert_eq!(output, dataset.union, "memory union reference");
            let validation = rss_snapshot()?;
            black_box((
                &dataset.raw,
                &dataset.a,
                &dataset.b,
                &dataset.union,
                &a,
                &b,
                &output,
            ));
            Ok(memory_report(
                mode, n, fst_bytes, summary, baseline, after, validation,
            ))
        }
        _ => Err("dataset memory mode expected".into()),
    }
}

fn memory_load() -> Result<Value, String> {
    let path = required_path("MOONFST_WORKLOAD_FST_PATH")?;
    let n = integer("MOONFST_WORKLOAD_N", 0)?;
    check_n(n)?;
    let bytes = fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))?;
    let fst_bytes = bytes.len();
    let baseline = rss_snapshot()?;
    let map = Map::new(bytes).expect("memory load map");
    map.as_fst().verify().expect("memory load CRC");
    let after = rss_snapshot()?;
    let records = stream_owned(&map);
    assert_eq!(records.len(), n, "loaded record count");
    let summary = owned_summary(&records);
    let validation = rss_snapshot()?;
    black_box((&map, &records));
    Ok(memory_report(
        Mode::MemoryLoad,
        n,
        fst_bytes,
        summary,
        baseline,
        after,
        validation,
    ))
}

fn run() -> Result<Value, String> {
    let config = Config::from_env()?;
    if config.mode == Mode::MemoryLoad {
        return memory_load();
    }
    let dataset = read_dataset()?;
    match config.mode {
        Mode::Timing => timing(&config, &dataset),
        mode => memory_dataset(mode, &dataset),
    }
}

fn main() {
    match run() {
        Ok(report) => println!("{report}"),
        Err(error) => {
            eprintln!("fst_workload: {error}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn corpus(n: u32, entries: &[(&[u8], u64)]) -> Vec<u8> {
        let mut bytes = MAGIC.to_vec();
        bytes.extend_from_slice(&n.to_le_bytes());
        bytes.extend_from_slice(&(entries.len() as u32).to_le_bytes());
        for &(key, value) in entries {
            bytes.extend_from_slice(&(key.len() as u32).to_le_bytes());
            bytes.extend_from_slice(&value.to_le_bytes());
            bytes.extend_from_slice(key);
        }
        bytes
    }

    #[test]
    fn parse_slices_original_order_before_sorting() {
        let raw = corpus(2, &[(b"z", u64::MAX), (b"", 0), (b"a", 7)]);
        let dataset = parse_dataset(raw.clone()).unwrap();
        assert_eq!(dataset.raw, raw);
        assert_eq!(
            dataset.a,
            vec![(b"".to_vec(), 0), (b"z".to_vec(), u64::MAX)]
        );
        assert_eq!(dataset.b, vec![(b"".to_vec(), 0), (b"a".to_vec(), 7)]);
        assert_eq!(dataset.union.len(), 3);
    }

    #[test]
    fn parse_rejects_truncation_trailing_duplicates_and_invalid_counts() {
        let good = corpus(2, &[(b"a", 1), (b"b", 2), (b"c", 3)]);
        for length in 0..good.len() {
            assert!(parse_dataset(good[..length].to_vec()).is_err());
        }
        let mut trailing = good.clone();
        trailing.push(0);
        assert!(parse_dataset(trailing).is_err());
        let mut magic = good;
        magic[0] ^= 1;
        assert!(parse_dataset(magic).is_err());
        assert!(parse_dataset(corpus(2, &[(b"a", 0), (b"b", 0), (b"a", 1)])).is_err());
        assert!(parse_dataset(corpus(3, &[(b"a", 0), (b"b", 0), (b"c", 0)])).is_err());
        assert!(parse_dataset(corpus(2, &[(b"a", 0), (b"b", 0)])).is_err());
    }

    #[test]
    fn shuffle_is_a_stable_permutation_and_mixed_positions_use_query_order() {
        assert_eq!(
            query_order(8, Order::Sorted, 123),
            (0..8).collect::<Vec<_>>()
        );
        let order = query_order(8, Order::Shuffled, 305_419_896);
        let mut sorted = order.clone();
        sorted.sort_unstable();
        assert_eq!(sorted, (0..8).collect::<Vec<_>>());
        assert_eq!(order, query_order(8, Order::Shuffled, 305_419_896));
        assert_ne!(order, sorted);
        assert_eq!(
            query_order(4, Order::Shuffled, 305_419_896),
            vec![2, 1, 0, 3]
        );
        let dataset = parse_dataset(corpus(
            4,
            &[
                (b"a", 1),
                (b"b", 2),
                (b"c", 4),
                (b"d", 8),
                (b"e", 16),
                (b"f", 32),
            ],
        ))
        .unwrap();
        let config = Config {
            mode: Mode::Timing,
            order: Order::Shuffled,
            query_seed: 305_419_896,
            samples: 1,
            warmups: 0,
        };
        let queries = prepare_queries(&dataset, &config);
        let indices = query_order(dataset.a.len(), config.order, config.query_seed);
        let expected = indices
            .iter()
            .enumerate()
            .filter(|(position, _)| position % 2 == 0)
            .fold(0u64, |sum, (_, &index)| {
                sum.wrapping_add(dataset.a[index].1)
            });
        assert_eq!(queries.mixed_sum, expected);
        assert_eq!(queries.mixed_sum, 5);
        assert_eq!(queries.hit_sum, 15);
        assert_eq!(queries.misses[0].last(), Some(&0xff));
    }

    #[test]
    fn streamed_union_matches_owned_reference_and_full_unsigned_values() {
        let dataset = parse_dataset(corpus(
            2,
            &[(b"\x00", u64::MAX), (b"\xff", 0), (b"\x00\x00", 9)],
        ))
        .unwrap();
        let a = validated_map(build(&dataset.a), &dataset.a);
        let b = validated_map(build(&dataset.b), &dataset.b);
        assert_eq!(union_owned(&a, &b), dataset.union);
        assert_eq!(entries_hash(&stream_owned(&a)), entries_hash(&dataset.a));
    }
}
