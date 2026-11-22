//! Test setup: stores a DER certificate on a PKCS#11 token next to the key with the same label,
//! as an A3 token's vendor software does. Usage: p11-put-cert MODULE TOKEN PIN LABEL CERT.der (CKA_ID 01, like the key)

use cryptoki::context::{CInitializeArgs, CInitializeFlags, Pkcs11};
use cryptoki::object::{Attribute, CertificateType, ObjectClass};
use cryptoki::session::UserType;
use cryptoki::types::AuthPin;

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let [module, token, pin, label, cert] = &a[..] else {
        panic!("usage: p11-put-cert MODULE TOKEN PIN LABEL CERT.der");
    };
    let der = std::fs::read(cert).expect("read certificate");
    let (_, parsed) = x509_parser::parse_x509_certificate(&der).expect("parse certificate");
    let subject = parsed.tbs_certificate.subject.as_raw().to_vec();
    let ctx = Pkcs11::new(module).expect("load module");
    ctx.initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))
        .expect("initialize");
    let slot = ctx
        .get_slots_with_token()
        .expect("slots")
        .into_iter()
        .find(|s| ctx.get_token_info(*s).is_ok_and(|t| t.label() == token))
        .expect("token not found");
    let session = ctx.open_rw_session(slot).expect("session");
    session
        .login(UserType::User, Some(&AuthPin::new(pin.as_str().into())))
        .expect("login");
    session
        .create_object(&[
            Attribute::Class(ObjectClass::CERTIFICATE),
            Attribute::CertificateType(CertificateType::X_509),
            Attribute::Token(true),
            Attribute::Label(label.as_bytes().to_vec()),
            Attribute::Id(vec![1]),
            Attribute::Subject(subject),
            Attribute::Value(der.clone()),
        ])
        .expect("create certificate object");
}
