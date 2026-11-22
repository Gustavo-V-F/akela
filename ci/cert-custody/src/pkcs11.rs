//! A PKCS#11 token (how A3 tokens are reached), referenced by its module and the slot holding
//! the token with a given label.

use std::sync::Mutex;

// One initialized module per process: finalizing it while another session is open crashes.
static CONTEXT: Mutex<Option<Pkcs11>> = Mutex::new(None);

use cryptoki::context::{CInitializeArgs, CInitializeFlags, Pkcs11};
use cryptoki::error::RvError;
use cryptoki::mechanism::Mechanism;
use cryptoki::object::{Attribute, AttributeInfo, AttributeType, ObjectClass, ObjectHandle};
use cryptoki::session::{Session, UserType};
use cryptoki::types::AuthPin;

use crate::{Hash, StoreKey, err};

pub struct P11Key {
    session: Mutex<Session>,
    key: ObjectHandle,
    _ctx: Pkcs11,
}

/// Opens a session on the token labelled `token` and finds the private key and certificate
/// labelled `label`; returns the key and the certificate's DER.
pub fn open(
    module: &str,
    token: &str,
    pin: &str,
    label: &str,
) -> Result<(P11Key, Vec<u8>), String> {
    let ctx = {
        let mut guard = CONTEXT.lock().unwrap();
        if guard.is_none() {
            let ctx = Pkcs11::new(module).map_err(err)?;
            ctx.initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
                .map_err(err)?;
            *guard = Some(ctx);
        }
        guard.clone().unwrap()
    };
    let slot = ctx
        .get_slots_with_token()
        .map_err(err)?
        .into_iter()
        .find(|s| ctx.get_token_info(*s).is_ok_and(|t| t.label() == token))
        .ok_or_else(|| format!("no slot holds token {token}"))?;
    let session = ctx.open_ro_session(slot).map_err(err)?;
    // Login is per token for the whole process, so a second session finds it logged in already.
    match session.login(UserType::User, Some(&AuthPin::new(pin.into()))) {
        Ok(()) | Err(cryptoki::error::Error::Pkcs11(RvError::UserAlreadyLoggedIn, _)) => {}
        Err(e) => return Err(e.to_string()),
    }
    let find = |class| {
        session
            .find_objects(&[
                Attribute::Class(class),
                Attribute::Label(label.as_bytes().to_vec()),
            ])
            .map_err(err)?
            .into_iter()
            .next()
            .ok_or_else(|| format!("no {class} labelled {label}"))
    };
    let key = find(ObjectClass::PRIVATE_KEY)?;
    let cert = find(ObjectClass::CERTIFICATE)?;
    let cert = match session
        .get_attributes(cert, &[AttributeType::Value])
        .map_err(err)?
        .pop()
    {
        Some(Attribute::Value(v)) => v,
        _ => return Err("certificate has no value".into()),
    };
    Ok((
        P11Key {
            session: Mutex::new(session),
            key,
            _ctx: ctx,
        },
        cert,
    ))
}

impl P11Key {
    /// Whether the token reports the private key as sensitive and not extractable, and
    /// refuses to reveal its private exponent.
    pub fn key_stays_on_token(&self) -> Result<(), String> {
        let session = self.session.lock().unwrap();
        let attrs = session
            .get_attributes(
                self.key,
                &[AttributeType::Sensitive, AttributeType::Extractable],
            )
            .map_err(err)?;
        if !attrs.contains(&Attribute::Sensitive(true))
            || !attrs.contains(&Attribute::Extractable(false))
        {
            return Err(format!("key attributes allow export: {attrs:?}"));
        }
        match session
            .get_attribute_info(self.key, &[AttributeType::PrivateExponent])
            .map_err(err)?[..]
        {
            [AttributeInfo::Sensitive] => Ok(()),
            ref other => Err(format!("private exponent is readable: {other:?}")),
        }
    }
}

impl StoreKey for P11Key {
    fn sign(&self, hash: Hash, msg: &[u8]) -> Result<Vec<u8>, String> {
        let mechanism = match hash {
            Hash::Sha1 => Mechanism::Sha1RsaPkcs,
            Hash::Sha256 => Mechanism::Sha256RsaPkcs,
        };
        self.session
            .lock()
            .unwrap()
            .sign(&mechanism, self.key, msg)
            .map_err(err)
    }
}
