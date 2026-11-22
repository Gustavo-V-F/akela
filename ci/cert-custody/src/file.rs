//! The agent's own store: an A1 PKCS#12 file readable only by the agent's service account.

use std::path::Path;

use p12_keystore::{KeyStore, Pkcs12ImportPolicy};
use rsa::pkcs8::DecodePrivateKey;
use rsa::{Pkcs1v15Sign, RsaPrivateKey};
use sha1::{Digest, Sha1};
use sha2::Sha256;

use crate::{Hash, StoreKey, err};

pub struct FileKey(RsaPrivateKey);

/// Opens a PKCS#12 file; returns its key and the DER of its certificate.
pub fn open(path: &Path, password: &str) -> Result<(FileKey, Vec<u8>), String> {
    let data = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let store = KeyStore::from_pkcs12(&data, password, Pkcs12ImportPolicy::Strict).map_err(err)?;
    let (_, chain) = store
        .private_key_chain()
        .ok_or("no private key in the PKCS#12 file")?;
    let key = RsaPrivateKey::from_pkcs8_der(chain.key().as_der()).map_err(err)?;
    let cert = chain
        .certs()
        .first()
        .ok_or("no certificate in the PKCS#12 file")?
        .as_der()
        .to_vec();
    Ok((FileKey(key), cert))
}

impl StoreKey for FileKey {
    fn sign(&self, hash: Hash, msg: &[u8]) -> Result<Vec<u8>, String> {
        match hash {
            Hash::Sha1 => self.0.sign(Pkcs1v15Sign::new::<Sha1>(), &Sha1::digest(msg)),
            Hash::Sha256 => self
                .0
                .sign(Pkcs1v15Sign::new::<Sha256>(), &Sha256::digest(msg)),
        }
        .map_err(err)
    }
}
