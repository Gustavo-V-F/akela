//! Linux: the agent's own file store. Set up by `ci/cert-custody/linux.sh`: the store directory
//! and files belong to CUSTODY_FILE_OWNER with modes 0700/0600, and CUSTODY_OTHER_USER exists.
#![cfg(target_os = "linux")]

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;

use akela_ci_cert_custody::{env, file, sign_and_verify, tls12_client_auth};

const PASSWORD: &str = "test";

fn store(name: &str) -> PathBuf {
    PathBuf::from(env("CUSTODY_FILE_STORE")).join(name)
}

fn can_read_as(user: &str, path: &PathBuf) -> bool {
    Command::new("runuser")
        .args(["-u", user, "--", "cat"])
        .arg(path)
        .output()
        .expect("run runuser")
        .status
        .success()
}

#[test]
fn file_store_key_signs_rsa_sha1() {
    let (key, cert) = file::open(&store("issuer.p12"), PASSWORD).unwrap();
    sign_and_verify(&key, &cert).unwrap();
}

#[test]
fn file_store_key_authenticates_tls12_client() {
    let (key, cert) = file::open(&store("issuer.p12"), PASSWORD).unwrap();
    tls12_client_auth(Arc::new(key), &cert).unwrap();
}

#[test]
fn other_user_cannot_read_file_store() {
    let path = store("issuer.p12");
    assert!(
        can_read_as(&env("CUSTODY_FILE_OWNER"), &path),
        "the owner must read it (control)"
    );
    assert!(
        !can_read_as(&env("CUSTODY_OTHER_USER"), &path),
        "another user read the certificate"
    );
}

#[test]
fn removed_file_store_certificate_cannot_sign() {
    let path = store("removal.p12");
    let (key, cert) = file::open(&path, PASSWORD).unwrap();
    sign_and_verify(&key, &cert).unwrap();
    drop(key);
    std::fs::remove_file(&path).unwrap();
    assert!(
        file::open(&path, PASSWORD).is_err(),
        "a removed certificate still opened"
    );
}
