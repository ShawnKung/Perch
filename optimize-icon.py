#!/usr/bin/env python3
"""Recompress PNG payloads in the generated ICNS without changing image data."""
import pathlib
import struct
import sys
import zlib


def chunks(data, png=False):
    offset = 8
    while offset < len(data):
        if png:
            size, kind = struct.unpack(">I4s", data[offset:offset + 8])
            end = offset + size + 12
            payload = data[offset + 8:end - 4]
            assert end <= len(data)
            assert zlib.crc32(kind + payload) == struct.unpack(">I", data[end - 4:end])[0]
        else:
            kind, size = struct.unpack(">4sI", data[offset:offset + 8])
            assert size >= 8
            end = offset + size
            payload = data[offset + 8:end]
            assert end <= len(data)
        yield kind, payload
        offset = end
    assert offset == len(data)


def compress_png(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return data
    original = list(chunks(data, png=True))
    image = b"".join(payload for kind, payload in original if kind == b"IDAT")
    raw = zlib.decompress(image)
    compressor = zlib.compressobj(level=9, strategy=zlib.Z_FILTERED)
    packed = compressor.compress(raw) + compressor.flush()
    if len(packed) >= len(image):
        return data
    result = data[:8]
    written = False
    for kind, payload in original:
        if kind == b"IDAT":
            if written:
                continue
            payload = packed
            written = True
        result += struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    restored = list(chunks(result, png=True))
    assert zlib.decompress(b"".join(p for k, p in restored if k == b"IDAT")) == raw
    assert [(k, p) for k, p in restored if k != b"IDAT"] == [(k, p) for k, p in original if k != b"IDAT"]
    return result


path = pathlib.Path(sys.argv[1])
original = path.read_bytes()
assert original[:4] == b"icns" and struct.unpack(">I", original[4:8])[0] == len(original)
entries = [(kind, compress_png(payload)) for kind, payload in chunks(original)]
# Preserve an optional ICNS table of contents with the new element lengths.
entries = [(kind, b"".join(struct.pack(">4sI", k, len(p) + 8) for k, p in entries if k != b"TOC ")
            if kind == b"TOC " else payload) for kind, payload in entries]
body = b"".join(struct.pack(">4sI", kind, len(payload) + 8) + payload for kind, payload in entries)
result = b"icns" + struct.pack(">I", len(body) + 8) + body
assert list(chunks(result)) == entries
path.write_bytes(result)
print("ICNS lossless compression:", len(original), "->", len(result), "bytes")
