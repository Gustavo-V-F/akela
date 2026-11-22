//! Windows certificate store. Set up by `ci/cert-custody/windows.sh`, which imports issuer.p12
//! and removal.p12 into the current user's store under the software KSP without export rights.
#![cfg(windows)]

use std::sync::Arc;

use akela_ci_cert_custody::{cng, fixture_der, sign_and_verify, tls12_client_auth};

fn open(name: &str) -> (cng::CngKey, Vec<u8>) {
    let (key, cert) =
        cng::open(&cng::thumbprint(&fixture_der(&format!("{name}.crt.der")))).unwrap();
    (key, cert)
}

#[test]
fn store_key_signs_rsa_sha1() {
    let (key, cert) = open("issuer");
    sign_and_verify(&key, &cert).unwrap();
}

#[test]
fn store_key_authenticates_tls12_client() {
    let (key, cert) = open("issuer");
    tls12_client_auth(Arc::new(key), &cert).unwrap();
}

#[test]
fn store_key_cannot_be_exported() {
    let (key, _) = open("issuer");
    key.export_refused().unwrap();
}

#[test]
fn removed_store_certificate_cannot_sign() {
    let (key, cert) = open("removal");
    sign_and_verify(&key, &cert).unwrap();
    drop(key);
    let thumb = cng::thumbprint(&cert);
    cng::remove(&thumb).unwrap();
    assert!(
        cng::open(&thumb).is_err(),
        "a removed certificate is still in the store"
    );
}
