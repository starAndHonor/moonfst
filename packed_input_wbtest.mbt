///|
test "word label search agrees with scalar search for every byte and tail width" {
  let counts = Array::makei(34, i => i)
  for count in [63, 64, 255, 256] {
    counts.push(count)
  }
  for count in counts {
    for rotation in [0, 1, 2, 7, 63, 64, 127, 128, 129, 254, 255] {
      let labels = Array::makei(count, i => ((rotation + i * 7) & 255).to_byte())
      labels.sort()
      let buffer : Array[Byte] = Array::make(16, b'\x00')
      for i = labels.length() - 1; i >= 0; i = i - 1 {
        buffer.push(labels[i])
      }
      let end = buffer.length()
      // Deliberate matches in bytes beyond the label list must be ignored.
      for byte in [0, 1, 128, 255, 0, 1, 254, 255, 0, 1, 2, 3, 4, 5, 6, 7] {
        buffer.push(byte.to_byte())
      }
      let data = Bytes::from_array(buffer)
      for byte in 0..<256 {
        let input = byte.to_byte()
        let mut expected = -1
        for i in 0..<labels.length() {
          if labels[i] == input {
            expected = i
            break
          }
        }
        assert_eq(packed_find_input(data, end, count, input), expected)
      }
    }
  }
}
