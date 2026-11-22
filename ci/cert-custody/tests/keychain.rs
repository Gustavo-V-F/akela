//! macOS keychain. Set up by `ci/cert-custody/macos.sh`, which imports issuer.p12 and
//! removal.p12 into CUSTODY_KEYCHAIN with non-extractable keys.
#![cfg(target_os = "macos")]

use std::path::PathBuf;
use std::sync::Arc;

use akela_ci_cert_custody::{env, fixture_der, keychain, sign_and_verify, tls12_client_auth};

fn open(
    name: &str,
) -> (
    keychain::KeychainKey,
    security_framework::identity::SecIdentity,
    Vec<u8>,
) {
    let cert = fixture_der(&format!("{name}.crt.der"));
    let (key, identity) = keychain::open(
        &PathBuf::from(env("CUSTODY_KEYCHAIN")),
        &env("CUSTODY_KEYCHAIN_PASSWORD"),
        &cert,
    )
    .unwrap();
    (key, identity, cert)
}

#[test]
fn keychain_key_signs_rsa_sha1() {
    let (key, _, cert) = open("issuer");
    sign_and_verify(&key, &cert).unwrap();
}

#[test]
fn keychain_key_authenticates_tls12_client() {
    let (key, _, cert) = open("issuer");
    tls12_client_auth(Arc::new(key), &cert).unwrap();
}

#[test]
fn keychain_key_cannot_be_exported() {
    let (key, _, _) = open("issuer");
    key.export_refused().unwrap();
}

#[test]
fn removed_keychain_certificate_cannot_sign() {
    let (key, identity, cert) = open("removal");
    sign_and_verify(&key, &cert).unwrap();
    drop(key);
    keychain::remove(&identity).unwrap();
    let path = PathBuf::from(env("CUSTODY_KEYCHAIN"));
    assert!(
        keychain::open(&path, &env("CUSTODY_KEYCHAIN_PASSWORD"), &cert).is_err(),
        "a removed certificate is still in the keychain"
    );
}
