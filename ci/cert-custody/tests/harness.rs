//! Negative controls: the signature check and the TLS server reject a key that does not match
//! the certificate, so a passing store test means the store's own key did the work.

use std::sync::Arc;

use akela_ci_cert_custody::{file, fixtures, sign_and_verify, tls12_client_auth};

fn wrong_key_with_issuer_cert() -> (file::FileKey, Vec<u8>) {
    let (wrong, _) = file::open(&fixtures().join("removal.p12"), "test").unwrap();
    let (_, cert) = file::open(&fixtures().join("issuer.p12"), "test").unwrap();
    (wrong, cert)
}

#[test]
fn signature_from_another_key_is_rejected() {
    let (key, cert) = wrong_key_with_issuer_cert();
    assert!(sign_and_verify(&key, &cert).is_err());
}

#[test]
fn tls_client_with_another_key_is_rejected() {
    let (key, cert) = wrong_key_with_issuer_cert();
    assert!(tls12_client_auth(Arc::new(key), &cert).is_err());
}
