//! Test-only bridge to the unmodified, exact-version upstream implementation.
use fst::{Automaton, IntoStreamer, Map, MapBuilder, SetBuilder, Streamer};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

const UPSTREAM_VERSION: &str = "0.4.7";
const UPSTREAM_COMMIT: &str = "fbd5992376f176c35af2644d74efad58f5656e5c";

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 15) as usize] as char);
    }
    out
}

fn hex_decode(input: &str) -> Result<Vec<u8>, String> {
    if input.len() % 2 != 0 {
        return Err("hex input has odd length".into());
    }
    fn nibble(byte: u8) -> Result<u8, String> {
        match byte {
            b'0'..=b'9' => Ok(byte - b'0'),
            b'a'..=b'f' => Ok(byte - b'a' + 10),
            b'A'..=b'F' => Ok(byte - b'A' + 10),
            _ => Err("hex input contains a non-hex byte".into()),
        }
    }
    input
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| Ok(nibble(pair[0])? * 16 + nibble(pair[1])?))
        .collect()
}

fn string<'a>(request: &'a Value, field: &str) -> Result<&'a str, String> {
    request[field]
        .as_str()
        .ok_or_else(|| format!("{field} must be a string"))
}

fn key(request: &Value, field: &str) -> Result<Vec<u8>, String> {
    hex_decode(string(request, field)?)
}

fn array<'a>(request: &'a Value, field: &str) -> Result<&'a [Value], String> {
    request[field]
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| format!("{field} must be an array"))
}

fn entry_json(key: &[u8], value: u64) -> Value {
    json!([hex_encode(key), value.to_string()])
}

#[derive(Clone)]
struct Prefix(Vec<u8>);

impl Automaton for Prefix {
    type State = Option<usize>;

    fn start(&self) -> Self::State {
        Some(0)
    }

    fn is_match(&self, state: &Self::State) -> bool {
        matches!(state, Some(index) if *index == self.0.len())
    }

    fn can_match(&self, state: &Self::State) -> bool {
        state.is_some()
    }

    fn accept(&self, state: &Self::State, byte: u8) -> Self::State {
        match *state {
            Some(index) if index == self.0.len() => Some(index),
            Some(index) if self.0[index] == byte => Some(index + 1),
            _ => None,
        }
    }
}

fn read(request: &Value) -> Result<Value, String> {
    let bytes = key(request, "bytes_hex")?;
    let map = Map::new(bytes).map_err(|error| error.to_string())?;
    if request["verify_checksum"].as_bool().unwrap_or(true) {
        map.as_fst().verify().map_err(|error| error.to_string())?;
    }
    let mut stream = map.stream();
    let mut entries = Vec::with_capacity(map.len());
    while let Some((key, value)) = stream.next() {
        entries.push(entry_json(key, value));
    }
    let mut result = json!({
        "ok": true,
        "len": map.len(),
        "entries": entries,
        "fst_type": map.as_fst().fst_type().to_string(),
    });
    if request.get("lookups").is_some() {
        let mut found = Vec::new();
        for lookup in array(request, "lookups")? {
            let hex = lookup.as_str().ok_or("lookup key must be hex text")?;
            let decoded = hex_decode(hex)?;
            found.push(json!([
                hex_encode(&decoded),
                map.get(decoded).map(|v| v.to_string())
            ]));
        }
        result["lookups"] = Value::Array(found);
    }
    if let Some(bounds) = request.get("range") {
        if !bounds.is_object() {
            return Err("range must be an object".into());
        }
        let mut range = map.range();
        for name in ["ge", "gt", "le", "lt"] {
            if bounds.get(name).is_some() {
                let bound = key(bounds, name)?;
                range = match name {
                    "ge" => range.ge(bound),
                    "gt" => range.gt(bound),
                    "le" => range.le(bound),
                    "lt" => range.lt(bound),
                    _ => unreachable!(),
                };
            }
        }
        let mut stream = range.into_stream();
        let mut found = Vec::new();
        while let Some((key, value)) = stream.next() {
            found.push(entry_json(key, value));
        }
        result["range"] = Value::Array(found);
    }
    if request.get("prefix").is_some() {
        let mut stream = map.search(Prefix(key(request, "prefix")?)).into_stream();
        let mut found = Vec::new();
        while let Some((key, value)) = stream.next() {
            found.push(entry_json(key, value));
        }
        result["prefix"] = Value::Array(found);
    }
    Ok(result)
}

fn build(request: &Value) -> Result<Value, String> {
    let bytes = match string(request, "kind")? {
        "set" => {
            let mut builder = SetBuilder::memory();
            for value in array(request, "keys")? {
                let hex = value.as_str().ok_or("set key must be hex text")?;
                builder
                    .insert(hex_decode(hex)?)
                    .map_err(|error| error.to_string())?;
            }
            builder.into_inner().map_err(|error| error.to_string())?
        }
        "map" => {
            let mut builder = MapBuilder::memory();
            for entry in array(request, "entries")? {
                let pair = entry
                    .as_array()
                    .ok_or("entry must be [hex_key, decimal_u64]")?;
                if pair.len() != 2 {
                    return Err("entry must have exactly two elements".into());
                }
                let key = hex_decode(pair[0].as_str().ok_or("entry key must be hex text")?)?;
                let value: u64 = pair[1]
                    .as_str()
                    .ok_or("entry value must be a decimal string, never a JSON number")?
                    .parse()
                    .map_err(|error| format!("invalid u64 value: {error}"))?;
                builder
                    .insert(key, value)
                    .map_err(|error| error.to_string())?;
            }
            builder.into_inner().map_err(|error| error.to_string())?
        }
        _ => return Err("kind must be set or map".into()),
    };
    let mut response = read(&json!({"bytes_hex": hex_encode(&bytes)}))?;
    response["bytes_hex"] = Value::String(hex_encode(&bytes));
    Ok(response)
}

fn dispatch(request: &Value) -> Result<Value, String> {
    match string(request, "op")? {
        "version" => Ok(json!({
            "ok": true, "protocol": 1, "crate": "fst",
            "version": UPSTREAM_VERSION, "upstream_commit": UPSTREAM_COMMIT,
        })),
        "build" => build(request),
        "read" => read(request),
        _ => Err("op must be version, build or read".into()),
    }
}

fn handle(line: &str) -> Value {
    // Upstream documents that corrupt graph bytes may panic. Keep one bad
    // differential request from killing the reference process.
    let result = std::panic::catch_unwind(|| {
        let request: Value = serde_json::from_str(line).map_err(|error| error.to_string())?;
        dispatch(&request)
    });
    match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok": false, "error": error}),
        Err(_) => json!({"ok": false, "error": "upstream fst panicked on this input"}),
    }
}

fn main() -> io::Result<()> {
    std::panic::set_hook(Box::new(|_| {}));
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut output = io::BufWriter::new(stdout.lock());
    for line in stdin.lock().lines() {
        let line = line?;
        let response = handle(&line);
        serde_json::to_writer(&mut output, &response)?;
        output.write_all(b"\n")?;
        output.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn max_u64_and_raw_keys_round_trip() {
        let built = dispatch(&json!({
            "op": "build", "kind": "map",
            "entries": [["", "18446744073709551615"], ["00ff", "0"], ["ff", "4294967296"]],
        }))
        .unwrap();
        let read = dispatch(&json!({
            "op": "read", "bytes_hex": built["bytes_hex"],
            "lookups": ["", "00ff", "ff", "fe"],
            "range": {"ge": "00", "lt": "ff"}, "prefix": "00",
        }))
        .unwrap();
        assert_eq!(built["entries"], read["entries"]);
        assert_eq!(read["len"], 3);
        assert_eq!(read["lookups"][0][1], "18446744073709551615");
        assert_eq!(read["lookups"][3][1], Value::Null);
        assert_eq!(read["range"], json!([["00ff", "0"]]));
        assert_eq!(read["prefix"], json!([["00ff", "0"]]));
    }

    #[test]
    fn empty_set_and_empty_key_are_distinct() {
        let empty = dispatch(&json!({"op":"build", "kind":"set", "keys":[]})).unwrap();
        let singleton = dispatch(&json!({"op":"build", "kind":"set", "keys":[""]})).unwrap();
        assert_eq!(empty["entries"], json!([]));
        assert_eq!(singleton["entries"], json!([["", "0"]]));
        assert_ne!(empty["bytes_hex"], singleton["bytes_hex"]);
    }

    #[test]
    fn rejects_invalid_requests_and_preserves_process() {
        for line in [
            "",
            "{}",
            "{\"op\":\"read\",\"bytes_hex\":\"0\"}",
            "{\"op\":\"read\",\"bytes_hex\":\"00\"}",
            "{\"op\":\"build\",\"kind\":\"map\",\"entries\":[[\"61\",18446744073709551615]]}",
            "{\"op\":\"build\",\"kind\":\"set\",\"keys\":[\"62\",\"61\"]}",
        ] {
            assert_eq!(handle(line)["ok"], false, "{line}");
        }
        assert_eq!(handle("{\"op\":\"version\"}")["ok"], true);
    }
}
