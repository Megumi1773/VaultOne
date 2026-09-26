//! ISO/IEC 7816-4 填充至 256 字节倍数，缓解密文长度泄露（计划书 §3.1）。

use zeroize::Zeroizing;

use crate::{CryptoError, Result};

pub const PAD_BLOCK: usize = 256;

pub fn pad(data: &[u8]) -> Zeroizing<Vec<u8>> {
    let padded_len = (data.len() + 1).div_ceil(PAD_BLOCK) * PAD_BLOCK;
    let mut out = Zeroizing::new(Vec::with_capacity(padded_len));
    out.extend_from_slice(data);
    out.push(0x80);
    out.resize(padded_len, 0);
    out
}

pub fn unpad(mut data: Zeroizing<Vec<u8>>) -> Result<Zeroizing<Vec<u8>>> {
    let marker = data.iter().rposition(|&b| b != 0).ok_or(CryptoError::Integrity)?;
    if data[marker] != 0x80 {
        return Err(CryptoError::Integrity);
    }
    data.truncate(marker);
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aligns_and_roundtrips() {
        for len in [0usize, 1, 254, 255, 256, 257, 1000] {
            let data = vec![0xABu8; len];
            let padded = pad(&data);
            assert_eq!(padded.len() % PAD_BLOCK, 0);
            assert!(padded.len() > len);
            assert_eq!(&*unpad(padded).unwrap(), &data[..]);
        }
        let data = vec![1u8, 0, 0];
        assert_eq!(&*unpad(pad(&data)).unwrap(), &data[..]);
    }

    #[test]
    fn rejects_bad_padding() {
        assert!(unpad(Zeroizing::new(vec![0u8; 16])).is_err());
        assert!(unpad(Zeroizing::new(vec![1u8, 2, 3])).is_err());
    }
}
