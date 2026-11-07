///|
/// Explicit method exports for MoonBit 0.10.19. These preserve the intended
/// public dot-call API without implicitly promoting every future trait method.
pub extend FstError with @debug.Debug::{to_repr}

///|
pub extend Entry with Eq::{equal, not_equal}

///|
pub extend Entry with @debug.Debug::{to_repr}

///|
pub extend Bound with Eq::{equal, not_equal}

///|
pub extend Bound with @debug.Debug::{to_repr}

///|
pub extend KeyRange with Eq::{equal, not_equal}

///|
pub extend KeyRange with @debug.Debug::{to_repr}

///|
pub extend DuplicatePolicy with Eq::{equal, not_equal}

///|
pub extend DuplicatePolicy with @debug.Debug::{to_repr}

///|
pub extend Statistics with Eq::{equal, not_equal}

///|
pub extend Statistics with @debug.Debug::{to_repr}

///|
pub extend BuilderStatistics with Eq::{equal, not_equal}

///|
pub extend BuilderStatistics with @debug.Debug::{to_repr}

///|
pub extend Operation with Eq::{equal, not_equal}

///|
pub extend Operation with @debug.Debug::{to_repr}

///|
pub extend IndexedValue with Eq::{equal, not_equal}

///|
pub extend IndexedValue with @debug.Debug::{to_repr}

///|
pub extend MergedEntry with Eq::{equal, not_equal}

///|
pub extend MergedEntry with @debug.Debug::{to_repr}

///|
pub extend ArraySource with EntrySource::{next, close}

///|
pub extend CheckedSource with EntrySource::{next, close}

///|
pub extend FilterSource with EntrySource::{next, close}

///|
pub extend MapSource with EntrySource::{next, close}

///|
pub extend WindowSource with EntrySource::{next, close}
