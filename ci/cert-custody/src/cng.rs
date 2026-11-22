//! Windows: the current user's certificate store ("MY"), with keys behind CNG. Covers A1
//! certificates imported from PKCS#12 and smart cards (A3) whose certificates Windows
//! propagates into the store through the card's minidriver.

use std::ffi::c_void;
use std::ptr::{null, null_mut};

use sha1::{Digest, Sha1};
use sha2::Sha256;
use windows_sys::Win32::Security::Cryptography::*;
use windows_sys::core::{PCWSTR, w};

use crate::{Hash, StoreKey};

pub struct CngKey {
    handle: NCRYPT_KEY_HANDLE,
    free: bool,
}

impl Drop for CngKey {
    fn drop(&mut self) {
        if self.free {
            unsafe { NCryptFreeObject(self.handle) };
        }
    }
}

fn last_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

fn status(what: &str, s: i32) -> Result<(), String> {
    if s == 0 {
        Ok(())
    } else {
        Err(format!("{what}: 0x{:08x}", s as u32))
    }
}

/// The SHA-1 thumbprint Windows uses to identify a certificate.
pub fn thumbprint(cert_der: &[u8]) -> [u8; 20] {
    Sha1::digest(cert_der).into()
}

struct Found {
    store: HCERTSTORE,
    cert: *const CERT_CONTEXT,
}

impl Drop for Found {
    fn drop(&mut self) {
        unsafe {
            if !self.cert.is_null() {
                CertFreeCertificateContext(self.cert);
            }
            CertCloseStore(self.store, 0);
        }
    }
}

fn find_cert(thumb: &[u8; 20]) -> Result<Found, String> {
    unsafe {
        let store = CertOpenSystemStoreW(0, w!("MY"));
        if store.is_null() {
            return Err(last_error("CertOpenSystemStoreW"));
        }
        let blob = CRYPT_INTEGER_BLOB {
            cbData: 20,
            pbData: thumb.as_ptr() as *mut u8,
        };
        let cert = CertFindCertificateInStore(
            store,
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            0,
            CERT_FIND_SHA1_HASH,
            &blob as *const _ as *const c_void,
            null(),
        );
        let found = Found { store, cert };
        if cert.is_null() {
            return Err(last_error("certificate not in the store"));
        }
        Ok(found)
    }
}

fn acquire(found: &Found) -> Result<CngKey, String> {
    let mut handle: HCRYPTPROV_OR_NCRYPT_KEY_HANDLE = 0;
    let mut spec: CERT_KEY_SPEC = 0;
    let mut free = 0;
    let ok = unsafe {
        CryptAcquireCertificatePrivateKey(
            found.cert,
            CRYPT_ACQUIRE_ONLY_NCRYPT_KEY_FLAG | CRYPT_ACQUIRE_SILENT_FLAG,
            null(),
            &mut handle,
            &mut spec,
            &mut free,
        )
    };
    if ok == 0 {
        return Err(last_error("CryptAcquireCertificatePrivateKey"));
    }
    Ok(CngKey {
        handle,
        free: free != 0,
    })
}

/// Finds the certificate with this thumbprint in the current user's store and its CNG key;
/// returns the key and the certificate's DER.
pub fn open(thumb: &[u8; 20]) -> Result<(CngKey, Vec<u8>), String> {
    let found = find_cert(thumb)?;
    let key = acquire(&found)?;
    let der = unsafe {
        let c = &*found.cert;
        std::slice::from_raw_parts(c.pbCertEncoded, c.cbCertEncoded as usize).to_vec()
    };
    Ok((key, der))
}

/// Deletes the certificate's key and then the certificate from the store, as the agent does
/// when a manager removes a certificate from a machine.
pub fn remove(thumb: &[u8; 20]) -> Result<(), String> {
    let mut found = find_cert(thumb)?;
    let key = acquire(&found)?;
    status("NCryptDeleteKey", unsafe { NCryptDeleteKey(key.handle, 0) })?;
    std::mem::forget(key); // NCryptDeleteKey already freed the handle
    let cert = std::mem::replace(&mut found.cert, null());
    if unsafe { CertDeleteCertificateFromStore(cert) } == 0 {
        return Err(last_error("CertDeleteCertificateFromStore"));
    }
    Ok(())
}

impl CngKey {
    /// Gives a smart card key its PIN so signing needs no prompt.
    pub fn set_pin(&self, pin: &str) -> Result<(), String> {
        let wide: Vec<u16> = pin.encode_utf16().chain([0]).collect();
        status("NCryptSetProperty(SmartCardPin)", unsafe {
            NCryptSetProperty(
                self.handle,
                NCRYPT_PIN_PROPERTY,
                wide.as_ptr() as *const u8,
                (wide.len() * 2) as u32,
                0,
            )
        })
    }

    /// Ok when the store refuses to export the private key in every private-key format.
    pub fn export_refused(&self) -> Result<(), String> {
        for blob in [
            BCRYPT_RSAFULLPRIVATE_BLOB,
            BCRYPT_RSAPRIVATE_BLOB,
            NCRYPT_PKCS8_PRIVATE_KEY_BLOB,
        ] {
            let mut size = 0u32;
            let s = unsafe {
                NCryptExportKey(self.handle, 0, blob, null(), null_mut(), 0, &mut size, 0)
            };
            if s == 0 {
                return Err(format!("the store exported the private key ({size} bytes)"));
            }
        }
        Ok(())
    }
}

impl StoreKey for CngKey {
    fn sign(&self, hash: Hash, msg: &[u8]) -> Result<Vec<u8>, String> {
        let (alg, digest): (PCWSTR, Vec<u8>) = match hash {
            Hash::Sha1 => (BCRYPT_SHA1_ALGORITHM, Sha1::digest(msg).to_vec()),
            Hash::Sha256 => (BCRYPT_SHA256_ALGORITHM, Sha256::digest(msg).to_vec()),
        };
        let pad = BCRYPT_PKCS1_PADDING_INFO { pszAlgId: alg };
        let flags = NCRYPT_PAD_PKCS1_FLAG | NCRYPT_SILENT_FLAG;
        let padding = &pad as *const _ as *const c_void;
        let mut size = 0u32;
        unsafe {
            status(
                "NCryptSignHash (size)",
                NCryptSignHash(
                    self.handle,
                    padding,
                    digest.as_ptr(),
                    digest.len() as u32,
                    null_mut(),
                    0,
                    &mut size,
                    flags,
                ),
            )?;
            let mut sig = vec![0u8; size as usize];
            status(
                "NCryptSignHash",
                NCryptSignHash(
                    self.handle,
                    padding,
                    digest.as_ptr(),
                    digest.len() as u32,
                    sig.as_mut_ptr(),
                    size,
                    &mut size,
                    flags,
                ),
            )?;
            sig.truncate(size as usize);
            Ok(sig)
        }
    }
}
