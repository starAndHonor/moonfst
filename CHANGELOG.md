# Changelog

## 0.1.1 — 2026-11-08 UTC

- Move MoonBit library, tests and examples under `src/`, using `source = "src"`; public package names and APIs remain unchanged.
- Align source paths in fixture, benchmark and diagnostic tools with the new layout.
- Pin compiler and matching core archive URLs and SHA256 digests, and Rust version; add reproducible local setup and environment checks.
- Verify real publish archives, four-backend tests and independent consumers in the local/CI acceptance flow.
- Document clean-checkout reproduction, corpus regeneration, ignored outputs and maintenance boundaries.

This patch release changes repository organization and development tooling. The FST algorithm sources, serialized format and public interfaces are unchanged from 0.1.0. Existing benchmark reports retain their original source fingerprints and measurements.

## 0.1.0

Initial public Mooncakes release of the pure MoonBit port of Rust fst 0.4.7, with v3 binary interoperability, compact sets/maps, automaton search, streaming operations and optional dictionary indexes.
