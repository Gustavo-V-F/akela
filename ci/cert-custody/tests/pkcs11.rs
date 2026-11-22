//! PKCS#11 token on every operating system. Set up by `ci/cert-custody/provision-pkcs11.sh`.

use std::sync::Arc;

use akela_ci_cert_custody::{env, pkcs11, sign_and_verify, tls12_client_auth};

fn open() -> (pkcs11::P11Key, Vec<u8>) {
    pkcs11::open(
        &env("CUSTODY_PKCS11_MODULE"),
        &env("CUSTODY_PKCS11_TOKEN"),
        &env("CUSTODY_PKCS11_PIN"),
        "issuer",
    )
    .expect("open the token")
}

#[test]
fn token_key_signs_rsa_sha1() {
    let (key, cert) = open();
    sign_and_verify(&key, &cert).unwrap();
}

#[test]
fn token_key_authenticates_tls12_client() {
    let (key, cert) = open();
    tls12_client_auth(Arc::new(key), &cert).unwrap();
}

#[test]
fn token_key_cannot_be_read_out() {
    let (key, _) = open();
    key.key_stays_on_token().unwrap();
}
