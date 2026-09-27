//! 填充：任意输入 unpad 不 panic；pad→unpad 往返一致。
#![no_main]
use libfuzzer_sys::fuzz_target;
use vault_crypto::pad::{pad, unpad, PAD_BLOCK};
use zeroize::Zeroizing;

fuzz_target!(|data: &[u8]| {
    let _ = unpad(Zeroizing::new(data.to_vec()));
    let padded = pad(data);
    assert_eq!(padded.len() % PAD_BLOCK, 0);
    assert_eq!(&*unpad(padded).unwrap(), data);
});
