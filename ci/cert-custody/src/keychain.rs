//! macOS: a keychain holding an A1 certificate imported from PKCS#12 as an identity with a
//! non-extractable private key.

use std::path::Path;

use security_framework::identity::SecIdentity;
use security_framework::item::{ItemClass, ItemSearchOptions, Limit, Reference, SearchResult};
use security_framework::key::{Algorithm, SecKey};
use security_framework::os::macos::keychain::SecKeychain;

use crate::{Hash, StoreKey, err};

pub struct KeychainKey(SecKey);

/// Unlocks the keychain at `path` and finds the identity whose certificate is `cert_der`.
pub fn open(
    path: &Path,
    password: &str,
    cert_der: &[u8],
) -> Result<(KeychainKey, SecIdentity), String> {
    let mut keychain = SecKeychain::open(path).map_err(err)?;
    keychain.unlock(Some(password)).map_err(err)?;
    let results = ItemSearchOptions::new()
        .class(ItemClass::identity())
        .keychains(&[keychain])
        .load_refs(true)
        .limit(Limit::All)
        .search()
        .map_err(|e| format!("identity search: {e}"))?;
    for result in results {
        if let SearchResult::Ref(Reference::Identity(identity)) = result {
            if identity.certificate().map_err(err)?.to_der() == cert_der {
                return Ok((KeychainKey(identity.private_key().map_err(err)?), identity));
            }
        }
    }
    Err("identity not in the keychain".into())
}

/// Deletes the identity (certificate and private key), as the agent does when a manager
/// removes a certificate from a machine.
pub fn remove(identity: &SecIdentity) -> Result<(), String> {
    identity.delete().map_err(err)
}

impl KeychainKey {
    /// Ok when the keychain refuses to hand out the private key's bytes.
    pub fn export_refused(&self) -> Result<(), String> {
        match self.0.external_representation() {
            None => Ok(()),
            Some(data) => Err(format!(
                "the keychain exported the private key ({} bytes)",
                data.len()
            )),
        }
    }
}

impl StoreKey for KeychainKey {
    fn sign(&self, hash: Hash, msg: &[u8]) -> Result<Vec<u8>, String> {
        let algorithm = match hash {
            Hash::Sha1 => Algorithm::RSASignatureMessagePKCS1v15SHA1,
            Hash::Sha256 => Algorithm::RSASignatureMessagePKCS1v15SHA256,
        };
        self.0.create_signature(algorithm, msg).map_err(err)
    }
}
