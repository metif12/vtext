# Pure-V Brotli decoder, vendored — no C code, no C dependency.

This directory is a decoder-only snapshot of `vlib/x/compress/brotli`
from V 0.5.2 (`827f160`), plus the streaming callback API and the
prefix-table leak fix from `metif12/v` branch `fix/x-brotli-callback`.
Everything here is V; the upstream encoder (`compressor.v`, `encoder.v`,
`lz.v`) stays upstream because `compressor.v` calls the native C brotli
through `compress.brotli`, which would drag a C library into this tree.

## Files

- `decoder.v` — one-shot `decompress()`; `decode_stream` moved here verbatim
  from upstream `compressor.v` (pure V, no native calls).
- `decompress_callback.v` — `decompress_with_callback()`: bounded/streaming
  decode in 32 KiB chunks; a short callback count stops the stream without
  error. From the callback branch, verbatim.
- `common.v`, `transforms.v`, `utils.v` — bit reader, prefix codes, static
  dictionary glue, transforms. Verbatim from V 0.5.2 except the leak fix
  below.
- `dictionary.bin` — the 122,784-byte brotli static dictionary, loaded with
  `$embed_file`. Verbatim from upstream. MIT, like the rest of V.

## Changes from upstream (both are the whole delta)

1. `utils.v` `read_prefix_tree`: free the `lengths` array after the decoder
   tables are built from it. Without this every Huffman tree leaks one
   array — per meta-block, per font. (From the callback branch.)
2. `decoder.v`: `decode_stream` moved here from `compressor.v`, verbatim.
   (`decompress()` called it across the file boundary; the encoder side
   stays upstream.)

Encoder-only helpers that came along inside `common.v` (`BitWriter`,
`trivial_block_size`, `write_*`) are unused by the decoder and stay
untouched so the snapshot keeps diffing cleanly against upstream; V reports
them as notices, not errors.

## Licence

V is MIT-licensed; so is everything vendored here.
