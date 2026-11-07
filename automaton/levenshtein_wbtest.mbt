///|
fn reference_distance(left : String, right : String) -> Int32 {
  let a = left.to_array()
  let b = right.to_array()
  let mut previous = Array::makei(b.length() + 1, fn(i) { i })
  for i in 0..<a.length() {
    let row = Array::make(b.length() + 1, 0)
    row[0] = i + 1
    for j in 0..<b.length() {
      let substitution = previous[j] + (if a[i] == b[j] { 0 } else { 1 })
      row[j + 1] = substitution.min(previous[j + 1] + 1).min(row[j] + 1)
    }
    previous = row
  }
  previous[b.length()]
}

///|
fn small_unicode_words(
  alphabet : Array[String],
  maximum : Int32,
) -> Array[String] {
  let words = [""]
  let mut level = [""]
  for _ in 0..<maximum {
    let next : Array[String] = []
    for prefix in level {
      for letter in alphabet {
        let word = prefix + letter
        next.push(word)
        words.push(word)
      }
    }
    level = next
  }
  words
}

///|
fn valid_utf8(bytes : Bytes) -> Bool {
  try {
    ignore(@utf8.decode(bytes[:]))
    true
  } catch {
    _ => false
  }
}

///|
test "Unicode edit distance counts scalars, including supplementary planes" {
  let emoji = levenshtein("😀", 1)
  for candidate in ["😀", "月", "", "😀😀", "a😀"] {
    assert_true(emoji.matches_string(candidate))
  }
  assert_false(emoji.matches_string("ab"))
  let chinese = levenshtein("月亮", 1)
  for candidate in ["月", "日亮", "月光亮"] {
    assert_true(chinese.matches_string(candidate))
  }
  assert_false(chinese.matches_string("月光天"))
  assert_false(levenshtein("é", 1).matches_string("e\u0301"))
  assert_true(levenshtein("é", 2).matches_string("e\u0301"))
  assert_true(levenshtein("\u0000", 0).matches(b"\x00"))
  assert_true(
    levenshtein("😀", 0).levenshtein_stats().unwrap().query_scalars == 1,
  )
}

///|
test "Unicode Levenshtein agrees with independent scalar DP" {
  let candidates = small_unicode_words(["a", "b", "é", "😀"], 3)
  for
    query in ["", "a", "ab", "é", "😀", "aé", "é😀", "e\u0301", "月亮"] {
    for distance in 0..<3 {
      let matcher = levenshtein(query, distance)
      for candidate in candidates {
        assert_eq(
          matcher.matches_string(candidate),
          reference_distance(query, candidate) <= distance,
        )
      }
    }
  }
}

///|
test "UTF8 lowering agrees with strict decoder on every one and two byte key" {
  let matcher = levenshtein("", 2)
  assert_true(matcher.matches(b""))
  for a in 0..<256 {
    let one = bytes_from_ints([a])
    assert_eq(matcher.matches(one), valid_utf8(one))
    for b in 0..<256 {
      let two = bytes_from_ints([a, b])
      assert_eq(matcher.matches(two), valid_utf8(two))
    }
  }
}

///|
test "UTF8 boundary scalars are legal and malformed encodings never match" {
  let matcher = levenshtein("", 1)
  for
    key in [
      b"\x00", b"\x7f", b"\xc2\x80", b"\xdf\xbf", b"\xe0\xa0\x80", b"\xed\x9f\xbf",
      b"\xee\x80\x80", b"\xef\xbf\xbf", b"\xf0\x90\x80\x80", b"\xf4\x8f\xbf\xbf",
    ] {
    assert_true(matcher.matches(key))
  }
  let generous = levenshtein("", 20)
  for
    key in [
      b"\x80", b"\xbf", b"\xc0\x80", b"\xc1\xbf", b"\xc2", b"\xc2\x7f", b"\xe0\x9f\xbf",
      b"\xed\xa0\x80", b"\xed\xbf\xbf", b"\xe1\x80", b"\xf0\x8f\xbf\xbf", b"\xf4\x90\x80\x80",
      b"\xf5\x80\x80\x80", b"\xff", b"a\xe2\x82", b"\xe2\x82\xac\x80",
    ] {
    assert_false(generous.matches(key))
  }
}

///|
test "Levenshtein construction limits fail explicitly before returning a matcher" {
  assert_true(automaton_raises(() => levenshtein("a", -1)))
  assert_true(automaton_raises(() => levenshtein("a", 1000000)))
  assert_true(automaton_raises(() => levenshtein("a", 1, max_states=1)))
  assert_true(automaton_raises(() => levenshtein("abcdef", 1, max_work=10)))
  let matcher = levenshtein("abcdef", 1, max_states=10000)
  let stats = matcher.levenshtein_stats().unwrap()
  assert_eq(matcher.state_count(), stats.scalar_states * stats.utf8_states)
  assert_true(stats.dp_cells <= 10000000)
  assert_true(matcher.matches_string("abcxef"))
}

///|
test "Unicode pruning and Boolean complements retain correct invalid-byte semantics" {
  let matcher = levenshtein("é", 1)
  let negated = complement(matcher)
  for prefix in small_byte_words([0, 97, 0xc3, 0xa9, 255], 2) {
    let state = state_after(matcher, prefix)
    for suffix in small_byte_words([0, 97, 0xc3, 0xa9, 255], 2) {
      let next = suffix
        .iter()
        .fold(init=state, fn(s, byte) { matcher.accept(s, byte) })
      if !matcher.can_match(state) {
        assert_false(end_matches(matcher, next))
      }
      let joined = Bytes::makei(prefix.length() + suffix.length(), fn(i) {
        if i < prefix.length() {
          prefix[i]
        } else {
          suffix[i - prefix.length()]
        }
      })
      assert_eq(negated.matches(joined), !matcher.matches(joined))
    }
  }
  assert_true(negated.matches(b"\xff"))
}

///|
test "query scalar classes distinguish every UTF8 boundary representation" {
  for
    key in [
      b"\x00", b"\x7f", b"\xc2\x80", b"\xdf\xbf", b"\xe0\xa0\x80", b"\xed\x9f\xbf",
      b"\xee\x80\x80", b"\xef\xbf\xbf", b"\xf0\x90\x80\x80", b"\xf4\x8f\xbf\xbf",
    ] {
    let query = @utf8.decode(key[:])
    let matcher = levenshtein(query, 0)
    assert_true(matcher.matches(key))
    for position in 0..<key.length() {
      for replacement in 0..<256 {
        let modified = Bytes::makei(key.length(), fn(i) {
          if i == position {
            replacement.to_byte()
          } else {
            key[i]
          }
        })
        assert_eq(
          matcher.matches(modified),
          replacement.to_byte() == key[position],
        )
      }
    }
  }
}

///|
test "long repeated query stays bounded without runtime state caching" {
  let key = Bytes::make(512, b'a')
  let matcher = levenshtein(@utf8.decode(key[:]), 0)
  assert_true(matcher.matches(key))
  let wrong = Bytes::makei(key.length(), fn(i) {
    if i == 256 {
      b'b'
    } else {
      b'a'
    }
  })
  assert_false(matcher.matches(wrong))
  let before = matcher.levenshtein_stats()
  for _ in 0..<10 {
    assert_true(matcher.matches(key))
  }
  assert_eq(matcher.levenshtein_stats(), before)
}
