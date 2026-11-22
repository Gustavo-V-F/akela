//! Issuer certificate custody (ADR-0005): a certificate in each local store must sign
//! documents (XML signature, RSA-SHA1) and authenticate the client in mutual TLS 1.2,
//! the two uses the MOCs give it, without its private key leaving the store.

use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use rustls::client::ResolvesClientCert;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName};
use rustls::server::WebPkiClientVerifier;
use rustls::sign::{CertifiedKey, Signer, SigningKey};
use rustls::{
    ClientConfig, ClientConnection, RootCertStore, ServerConfig, ServerConnection,
    SignatureAlgorithm, SignatureScheme, StreamOwned,
};

#[cfg(windows)]
pub mod cng;
pub mod file;
#[cfg(target_os = "macos")]
pub mod keychain;
pub mod pkcs11;

/// Digest used inside an RSA PKCS#1 v1.5 signature.
#[derive(Clone, Copy, Debug)]
pub enum Hash {
    /// XML signature of NF-e, NFC-e, CT-e, MDF-e and their events (`xmldsig#rsa-sha1`).
    Sha1,
    /// TLS 1.2 client authentication (`rsa_pkcs1_sha256`).
    Sha256,
}

/// A private key held by a store. Signing happens inside the store.
pub trait StoreKey: Send + Sync {
    fn sign(&self, hash: Hash, msg: &[u8]) -> Result<Vec<u8>, String>;
}

/// Stand-in for a signed XML `SignedInfo`.
pub const MSG: &[u8] = b"<SignedInfo><Reference URI=\"#NFe00000000000000000000000000000000000000000000\"/></SignedInfo>";

pub fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

/// Directory written by `make-fixtures.sh`.
pub fn fixtures() -> PathBuf {
    PathBuf::from(env("CUSTODY_FIXTURES"))
}

pub fn fixture_der(name: &str) -> Vec<u8> {
    std::fs::read(fixtures().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

/// Checks an RSA PKCS#1 v1.5 SHA-1 signature against the certificate's public key.
pub fn verify_sha1(cert_der: &[u8], msg: &[u8], sig: &[u8]) -> Result<(), String> {
    let (_, cert) = x509_parser::parse_x509_certificate(cert_der).map_err(err)?;
    let public_key = &cert.tbs_certificate.subject_pki.subject_public_key.data;
    ring::signature::UnparsedPublicKey::new(
        &ring::signature::RSA_PKCS1_2048_8192_SHA1_FOR_LEGACY_USE_ONLY,
        public_key,
    )
    .verify(msg, sig)
    .map_err(|_| "signature does not verify against the certificate".to_string())
}

/// Signs `MSG` with SHA-1 and verifies the result against `cert_der`.
pub fn sign_and_verify(key: &dyn StoreKey, cert_der: &[u8]) -> Result<(), String> {
    let sig = key.sign(Hash::Sha1, MSG)?;
    verify_sha1(cert_der, MSG, &sig)
}

struct ExtKey(Arc<dyn StoreKey>);
struct ExtSigner(Arc<dyn StoreKey>);
#[derive(Debug)]
struct Resolver(Arc<CertifiedKey>);

impl std::fmt::Debug for ExtKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ExtKey")
    }
}

impl std::fmt::Debug for ExtSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ExtSigner")
    }
}

impl SigningKey for ExtKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        offered
            .contains(&SignatureScheme::RSA_PKCS1_SHA256)
            .then(|| Box::new(ExtSigner(self.0.clone())) as Box<dyn Signer>)
    }

    fn algorithm(&self) -> SignatureAlgorithm {
        SignatureAlgorithm::RSA
    }
}

impl Signer for ExtSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        self.0
            .sign(Hash::Sha256, message)
            .map_err(rustls::Error::General)
    }

    fn scheme(&self) -> SignatureScheme {
        SignatureScheme::RSA_PKCS1_SHA256
    }
}

impl ResolvesClientCert for Resolver {
    fn resolve(&self, _hints: &[&[u8]], _schemes: &[SignatureScheme]) -> Option<Arc<CertifiedKey>> {
        Some(self.0.clone())
    }

    fn has_certs(&self) -> bool {
        true
    }
}

/// Runs a TLS 1.2 handshake on loopback against a server that requires a client certificate
/// from the test CA; the client authenticates with `key` and `cert_der`. Succeeds only if the
/// server saw that certificate and data flowed both ways.
pub fn tls12_client_auth(key: Arc<dyn StoreKey>, cert_der: &[u8]) -> Result<(), String> {
    let dir = fixtures();
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = RootCertStore::empty();
    roots
        .add(CertificateDer::from_pem_file(dir.join("ca.pem")).map_err(err)?)
        .map_err(err)?;
    let roots = Arc::new(roots);

    let verifier = WebPkiClientVerifier::builder_with_provider(roots.clone(), provider.clone())
        .build()
        .map_err(err)?;
    let server_cfg = ServerConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS12])
        .map_err(err)?
        .with_client_cert_verifier(verifier)
        .with_single_cert(
            vec![CertificateDer::from_pem_file(dir.join("server.crt.pem")).map_err(err)?],
            PrivateKeyDer::from_pem_file(dir.join("server.key.pem")).map_err(err)?,
        )
        .map_err(err)?;

    let cert = CertificateDer::from(cert_der.to_vec());
    let client_cfg = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS12])
        .map_err(err)?
        .with_root_certificates(roots)
        .with_client_cert_resolver(Arc::new(Resolver(Arc::new(CertifiedKey::new(
            vec![cert],
            Arc::new(ExtKey(key)),
        )))));

    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(err)?;
    let addr = listener.local_addr().map_err(err)?;
    let server = std::thread::spawn(move || -> Result<Vec<u8>, String> {
        let (tcp, _) = listener.accept().map_err(err)?;
        tcp.set_read_timeout(Some(Duration::from_secs(30)))
            .map_err(err)?;
        let mut s = StreamOwned::new(
            ServerConnection::new(Arc::new(server_cfg)).map_err(err)?,
            tcp,
        );
        let mut buf = [0u8; 4];
        s.read_exact(&mut buf).map_err(|e| format!("server: {e}"))?;
        s.write_all(b"pong").map_err(err)?;
        s.flush().map_err(err)?;
        s.conn
            .peer_certificates()
            .and_then(|c| c.first())
            .map(|c| c.to_vec())
            .ok_or_else(|| "server: no client certificate".to_string())
    });

    let tcp = TcpStream::connect(addr).map_err(err)?;
    tcp.set_read_timeout(Some(Duration::from_secs(30)))
        .map_err(err)?;
    let name = ServerName::IpAddress(IpAddr::V4(Ipv4Addr::LOCALHOST).into());
    let mut c = StreamOwned::new(
        ClientConnection::new(Arc::new(client_cfg), name).map_err(err)?,
        tcp,
    );
    let client = (|| -> Result<(), String> {
        c.write_all(b"ping").map_err(err)?;
        let mut buf = [0u8; 4];
        c.read_exact(&mut buf).map_err(err)?;
        if c.conn.protocol_version() != Some(rustls::ProtocolVersion::TLSv1_2) {
            return Err("handshake did not use TLS 1.2".into());
        }
        Ok(())
    })();
    drop(c);

    let peer = server
        .join()
        .map_err(|_| "server thread panicked".to_string())?;
    client.map_err(|e| format!("client: {e}; server: {:?}", peer.as_ref().err()))?;
    if peer? != cert_der {
        return Err("server saw a different client certificate".into());
    }
    Ok(())
}
