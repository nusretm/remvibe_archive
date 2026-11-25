use remvibe_archive::{ArchiveRegion, Footer, FormatError, Header, HEADER_LEN, FOOTER_LEN};

fn main() {
    let header = Header.encode();
    assert_eq!(&header[..8], b"RVA3\r\n\x1a\n");
    assert_eq!(Header::decode(&header), Ok(Header));
    let mut invalid = header;
    invalid[10] = 1;
    assert_eq!(Header::decode(&invalid), Err(FormatError::UnsupportedFlags(256)));

    let payload_length = 17u64;
    let manifest_length = 23u64;
    let region_length = HEADER_LEN as u64 + payload_length + manifest_length + FOOTER_LEN as u64;
    let region = ArchiveRegion::new(4096, region_length, 8192).unwrap();
    let footer = Footer {
        manifest_offset: HEADER_LEN as u64 + payload_length,
        manifest_length,
        manifest_sha256: [0xab; 32], // Codec sample, not a real verified manifest hash.
    };
    assert_eq!(Footer::decode(&footer.encode()).unwrap(), footer);
    assert_eq!(footer.manifest_range(region).unwrap(), 4129..4152);
    assert!(ArchiveRegion::new(u64::MAX, region_length, u64::MAX).is_err());
    assert!(region.absolute_range(region_length, 1).is_err());
    assert!(Footer { manifest_length: 24, ..footer }.manifest_range(region).is_err());
    println!("PASS: RVA V3 envelope codec and bounded region probe");
}
