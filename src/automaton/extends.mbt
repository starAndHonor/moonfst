///|
pub extend Matcher with Automaton::{
  start,
  accept,
  is_match,
  can_match,
  will_always_match,
  accept_eof,
}

///|
pub extend AutomatonError with Eq::{equal, not_equal}

///|
pub extend AutomatonError with @debug.Debug::{to_repr}

///|
pub extend LevenshteinStats with Eq::{equal, not_equal}

///|
pub extend LevenshteinStats with @debug.Debug::{to_repr}
