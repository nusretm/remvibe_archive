//! Compression primitives. Exactly one complete frame, bounded output.
use crate::Compression;
use flate2::{Decompress, FlushDecompress, Status};
use std::{borrow::Cow, io::{self, Read, Write}};
use zstd::stream::raw::{Decoder, Operation, DParameter};

fn invalid(reason: &'static str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, reason) }

pub(crate) fn encode_manifest(bytes: Vec<u8>, compression: Compression, zlib_level: u32, zstd_level: i32) -> io::Result<Vec<u8>> {
    match compression {
        Compression::None => Ok(bytes),
        Compression::Zlib => {
            if zlib_level > 9 { return Err(invalid("invalid zlib level")); }
            let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(zlib_level));
            encoder.write_all(&bytes)?;
            encoder.finish()
        }
        Compression::Zstd => {
            if !(1..=19).contains(&zstd_level) { return Err(invalid("invalid zstd level")); }
            zstd::bulk::compress(&bytes, zstd_level)
        }
    }
}

/// The source is limited to stored bytes. Accept must enforce original size.
/// Decoder state is bounded by a 128 MiB maximum Zstd window; no dictionaries.
pub(crate) fn decode_zstd<E: From<io::Error>>(
    source: &mut impl Read, stored: u64, input: &mut [u8], output: &mut [u8],
    mut check: impl FnMut() -> Result<(), E>, mut accept: impl FnMut(&[u8]) -> Result<(), E>,
) -> Result<(), E> {
    if stored < 4 { return Err(invalid("truncated zstd frame").into()); }
    let mut magic = [0; 4];
    source.read_exact(&mut magic)?;
    if magic != [0x28, 0xb5, 0x2f, 0xfd] { return Err(invalid("invalid zstd frame magic").into()); }
    let mut source = io::Cursor::new(magic).chain(source);
    let mut decoder = Decoder::new()?;
    decoder.set_parameter(DParameter::WindowLogMax(27))?;
    let mut remaining = stored;
    let (mut pos, mut end) = (0usize, 0usize);
    loop {
        check()?;
        if pos == end && remaining != 0 {
            let n = remaining.min(input.len() as u64) as usize;
            source.read_exact(&mut input[..n])?;
            remaining -= n as u64; pos = 0; end = n;
        }
        let status = decoder.run_on_buffers(&input[pos..end], output)?;
        pos += status.bytes_read;
        accept(&output[..status.bytes_written])?;
        if status.remaining == 0 {
            if pos != end || remaining != 0 { return Err(invalid("trailing zstd frame bytes").into()); }
            return Ok(());
        }
        if status.bytes_read == 0 && status.bytes_written == 0 {
            return Err(invalid("truncated or stalled zstd frame").into());
        }
    }
}

pub(crate) fn decode_manifest(bytes: &[u8], compression: Compression, original: usize) -> io::Result<Cow<'_, [u8]>> {
    if compression == Compression::None {
        if bytes.len() != original { return Err(invalid("manifest size mismatch")); }
        return Ok(Cow::Borrowed(bytes));
    }
    let mut result = Vec::new();
    result.try_reserve_exact(original).map_err(|_| invalid("cannot allocate manifest"))?;
    let mut accept = |chunk: &[u8]| -> io::Result<()> {
        if chunk.len() > original - result.len() { return Err(invalid("manifest output exceeds declared size")); }
        result.extend_from_slice(chunk);
        Ok(())
    };
    let mut output = vec![0; 64 * 1024];
    match compression {
        Compression::None => unreachable!(),
        Compression::Zstd => {
            let mut input = vec![0; 64 * 1024];
            decode_zstd(&mut io::Cursor::new(bytes), bytes.len() as u64, &mut input, &mut output,
                || Ok(()), &mut accept)?;
        }
        Compression::Zlib => {
            let mut decoder = Decompress::new(true);
            let mut pos = 0;
            loop {
                let before_in = decoder.total_in();
                let before_out = decoder.total_out();
                let status = decoder.decompress(&bytes[pos..], &mut output, FlushDecompress::None)
                    .map_err(|_| invalid("invalid zlib manifest"))?;
                let used = (decoder.total_in() - before_in) as usize;
                let produced = (decoder.total_out() - before_out) as usize;
                pos += used;
                accept(&output[..produced])?;
                if status == Status::StreamEnd {
                    if pos != bytes.len() { return Err(invalid("trailing zlib manifest bytes")); }
                    break;
                }
                if used == 0 && produced == 0 { return Err(invalid("truncated zlib manifest")); }
            }
        }
    }
    drop(accept);
    if result.len() != original { return Err(invalid("manifest size mismatch")); }
    Ok(Cow::Owned(result))
}
