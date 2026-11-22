//! Windows smart card (A3): an emulated PIV card whose key was generated on the card and whose
//! certificate is in the current user's store, bound to the Smart Card KSP (inbox PIV
//! minidriver). Set up by `ci/cert-custody/windows-smartcard.sh`; CUSTODY_SMARTCARD_CERT is
//! the card certificate's DER and CUSTODY_SMARTCARD_PIN the card PIN.
#![cfg(windows)]

use std::sync::Arc;

use akela_ci_cert_custody::{cng, env, sign_and_verify, tls12_client_auth};

fn open() -> (cng::CngKey, Vec<u8>) {
    let der = std::fs::read(env("CUSTODY_SMARTCARD_CERT")).unwrap();
    let (key, cert) = cng::open(&cng::thumbprint(&der)).unwrap();
    key.set_pin(&env("CUSTODY_SMARTCARD_PIN")).unwrap();
    (key, cert)
}

#[test]
fn smartcard_key_signs_rsa_sha1() {
    let (key, cert) = open();
    sign_and_verify(&key, &cert).unwrap();
}

#[test]
fn smartcard_key_authenticates_tls12_client() {
    let (key, cert) = open();
    tls12_client_auth(Arc::new(key), &cert).unwrap();
}
