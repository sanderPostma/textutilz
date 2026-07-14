//! MIME / encoding transforms for the Tools → "MIME tools" panel.
//!
//! All logic lives here (Rust) per the project mandate; the Flutter panel only
//! picks a function and forwards the toggle/checkbox state. Every function is a
//! pure `frb(sync)` transform over a `String` so the UI can apply it to the
//! active editor's text and write the result back.

use anyhow::{anyhow, Context};
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use base64::{alphabet, Engine};
use flate2::read::DeflateDecoder;
use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};
use std::io::Read;

/// Apply `f` to each `\n`-separated line and rejoin, or to the whole input.
fn per_line<F: Fn(&str) -> String>(input: &str, by_line: bool, f: F) -> String {
    if by_line {
        input.split('\n').map(&f).collect::<Vec<_>>().join("\n")
    } else {
        f(input)
    }
}

/// Same as [`per_line`] but the transform can fail; a failing line aborts.
fn try_per_line<F: Fn(&str) -> anyhow::Result<String>>(
    input: &str,
    by_line: bool,
    f: F,
) -> anyhow::Result<String> {
    if by_line {
        let mut out = Vec::new();
        for line in input.split('\n') {
            out.push(f(line)?);
        }
        Ok(out.join("\n"))
    } else {
        f(input)
    }
}

// ---- Base64 ----------------------------------------------------------------

/// Base64-encode `input`.
///
/// - `padding`: emit `=` padding (standard) vs. no padding.
/// - `unix_eol`: normalize CRLF/CR to LF before encoding.
/// - `by_line`: encode each line independently, preserving line breaks.
#[flutter_rust_bridge::frb(sync)]
pub fn base64_encode(input: String, padding: bool, unix_eol: bool, by_line: bool) -> String {
    let normalized = if unix_eol {
        input.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        input
    };
    per_line(&normalized, by_line, |s| {
        if padding {
            STANDARD.encode(s.as_bytes())
        } else {
            STANDARD_NO_PAD.encode(s.as_bytes())
        }
    })
}

/// Base64-decode `input`, returning the bytes as (lossy) UTF-8 text.
///
/// - `strict`: reject trailing bits / disallow non-canonical input and require
///   padding. Non-strict mode tolerates whitespace, newlines and missing
///   padding (handy for pasted, wrapped blobs).
/// - `by_line`: decode each line independently.
#[flutter_rust_bridge::frb(sync)]
pub fn base64_decode(input: String, strict: bool, by_line: bool) -> anyhow::Result<String> {
    // Lenient engine: canonical alphabet, optional padding, ignore nothing but
    // we strip ASCII whitespace ourselves so wrapped input decodes.
    let lenient: GeneralPurpose = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_padding_mode(DecodePaddingMode::Indifferent)
            .with_decode_allow_trailing_bits(true),
    );
    try_per_line(&input, by_line, |s| {
        let bytes = if strict {
            STANDARD
                .decode(s.trim())
                .context("invalid base64 (strict)")?
        } else {
            let cleaned: String = s.chars().filter(|c| !c.is_ascii_whitespace()).collect();
            lenient.decode(cleaned).context("invalid base64")?
        };
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    })
}

// ---- Quoted-printable ------------------------------------------------------

/// Quoted-printable encode.
#[flutter_rust_bridge::frb(sync)]
pub fn qp_encode(input: String) -> String {
    quoted_printable::encode_to_str(input.as_bytes())
}

/// Quoted-printable decode (robust parse mode tolerates minor violations).
#[flutter_rust_bridge::frb(sync)]
pub fn qp_decode(input: String) -> anyhow::Result<String> {
    let bytes = quoted_printable::decode(input.as_bytes(), quoted_printable::ParseMode::Robust)
        .map_err(|e| anyhow!("invalid quoted-printable: {e}"))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

// ---- URL / percent encoding ------------------------------------------------

/// Which characters a URL encode pass escapes.
pub enum UrlEncodeVariant {
    /// RFC 1738 style: keep unreserved `A-Za-z0-9` and `-_.`; escape the rest
    /// (spaces become `%20`).
    Rfc1738,
    /// Extended (JS `encodeURIComponent`-like): additionally keep `!~*'()`.
    Extended,
    /// Full: escape every byte, including alphanumerics.
    Full,
}

// RFC 1738 safe set: escape everything that is not alphanumeric or - _ .
const RFC1738_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'!')
    .add(b'"')
    .add(b'#')
    .add(b'$')
    .add(b'%')
    .add(b'&')
    .add(b'\'')
    .add(b'(')
    .add(b')')
    .add(b'*')
    .add(b'+')
    .add(b',')
    .add(b'/')
    .add(b':')
    .add(b';')
    .add(b'<')
    .add(b'=')
    .add(b'>')
    .add(b'?')
    .add(b'@')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}')
    .add(b'~');

// Extended set: like RFC1738 but keep ! ~ * ' ( ) unescaped.
const EXTENDED_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'$')
    .add(b'%')
    .add(b'&')
    .add(b'+')
    .add(b',')
    .add(b'/')
    .add(b':')
    .add(b';')
    .add(b'<')
    .add(b'=')
    .add(b'>')
    .add(b'?')
    .add(b'@')
    .add(b'[')
    .add(b'\\')
    .add(b']')
    .add(b'^')
    .add(b'`')
    .add(b'{')
    .add(b'|')
    .add(b'}');

/// Percent-encode every byte of `s`, alphanumerics included.
fn encode_full(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        out.push('%');
        out.push_str(&format!("{:02X}", b));
    }
    out
}

/// URL / percent-encode `input` per `variant`. `by_line` encodes each line
/// independently (so line breaks survive).
#[flutter_rust_bridge::frb(sync)]
pub fn url_encode(input: String, variant: UrlEncodeVariant, by_line: bool) -> String {
    per_line(&input, by_line, |s| match variant {
        UrlEncodeVariant::Rfc1738 => utf8_percent_encode(s, RFC1738_SET).to_string(),
        UrlEncodeVariant::Extended => utf8_percent_encode(s, EXTENDED_SET).to_string(),
        UrlEncodeVariant::Full => encode_full(s),
    })
}

/// Percent-decode `input` to (lossy) UTF-8 text.
#[flutter_rust_bridge::frb(sync)]
pub fn url_decode(input: String) -> anyhow::Result<String> {
    Ok(percent_decode_str(&input).decode_utf8_lossy().into_owned())
}

// ---- SAML ------------------------------------------------------------------

/// Decode a SAML request/response token: optional URL-decode, base64-decode,
/// then (for the HTTP-Redirect binding) raw-DEFLATE inflate. If inflation
/// fails the token is assumed already-inflated (HTTP-POST binding) and the
/// base64-decoded XML is returned as-is.
#[flutter_rust_bridge::frb(sync)]
pub fn saml_decode(input: String) -> anyhow::Result<String> {
    let trimmed = input.trim();
    // Tokens are often URL-encoded when lifted from a query string.
    let url_decoded = percent_decode_str(trimmed).decode_utf8_lossy().into_owned();
    let cleaned: String = url_decoded
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .collect();
    let bytes = STANDARD
        .decode(&cleaned)
        .or_else(|_| STANDARD_NO_PAD.decode(&cleaned))
        .context("SAML token is not valid base64")?;

    // Try raw-DEFLATE (HTTP-Redirect binding).
    let mut inflated = String::new();
    if DeflateDecoder::new(&bytes[..])
        .read_to_string(&mut inflated)
        .is_ok()
        && !inflated.is_empty()
    {
        return Ok(inflated);
    }
    // Fall back to the already-inflated XML (HTTP-POST binding).
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_roundtrip_padded() {
        let enc = base64_encode("Hello, world!".to_string(), true, false, false);
        assert_eq!(enc, "SGVsbG8sIHdvcmxkIQ==");
        let dec = base64_decode(enc, false, false).unwrap();
        assert_eq!(dec, "Hello, world!");
    }

    #[test]
    fn base64_no_padding() {
        let enc = base64_encode("Hello, world!".to_string(), false, false, false);
        assert_eq!(enc, "SGVsbG8sIHdvcmxkIQ");
    }

    #[test]
    fn base64_by_line() {
        let enc = base64_encode("a\nb".to_string(), true, false, true);
        assert_eq!(enc, "YQ==\nYg==");
        let dec = base64_decode(enc, false, true).unwrap();
        assert_eq!(dec, "a\nb");
    }

    #[test]
    fn base64_unix_eol_normalizes() {
        let crlf = base64_encode("a\r\nb".to_string(), true, true, false);
        let lf = base64_encode("a\nb".to_string(), true, false, false);
        assert_eq!(crlf, lf);
    }

    #[test]
    fn base64_decode_tolerates_wrapped_whitespace() {
        // Non-strict decode ignores embedded newlines/spaces.
        let dec = base64_decode("SGVsbG8s\nIHdvcmxk IQ==".to_string(), false, false).unwrap();
        assert_eq!(dec, "Hello, world!");
    }

    #[test]
    fn base64_decode_strict_rejects_garbage() {
        assert!(base64_decode("not base64!!!".to_string(), true, false).is_err());
    }

    #[test]
    fn qp_roundtrip() {
        let enc = qp_encode("café = life".to_string());
        assert!(enc.contains('='));
        let dec = qp_decode(enc).unwrap();
        assert_eq!(dec, "café = life");
    }

    #[test]
    fn url_encode_rfc1738_space() {
        let enc = url_encode("a b&c".to_string(), UrlEncodeVariant::Rfc1738, false);
        assert_eq!(enc, "a%20b%26c");
    }

    #[test]
    fn url_encode_extended_keeps_marks() {
        let enc = url_encode("a!~*'()".to_string(), UrlEncodeVariant::Extended, false);
        assert_eq!(enc, "a!~*'()");
    }

    #[test]
    fn url_encode_full_escapes_everything() {
        let enc = url_encode("AB".to_string(), UrlEncodeVariant::Full, false);
        assert_eq!(enc, "%41%42");
    }

    #[test]
    fn url_encode_by_line_preserves_breaks() {
        let enc = url_encode("a b\nc d".to_string(), UrlEncodeVariant::Rfc1738, true);
        assert_eq!(enc, "a%20b\nc%20d");
    }

    #[test]
    fn url_decode_roundtrip() {
        let dec = url_decode("a%20b%26c".to_string()).unwrap();
        assert_eq!(dec, "a b&c");
    }

    #[test]
    fn saml_decode_deflated_redirect_binding() {
        // Build a redirect-binding token: raw-DEFLATE then base64.
        use flate2::write::DeflateEncoder;
        use flate2::Compression;
        use std::io::Write;
        let xml = "<samlp:AuthnRequest>hi</samlp:AuthnRequest>";
        let mut enc = DeflateEncoder::new(Vec::new(), Compression::default());
        enc.write_all(xml.as_bytes()).unwrap();
        let deflated = enc.finish().unwrap();
        let token = STANDARD.encode(&deflated);
        let decoded = saml_decode(token).unwrap();
        assert_eq!(decoded, xml);
    }

    #[test]
    fn saml_decode_post_binding_plain_base64() {
        // POST binding: base64 of the raw XML, no deflate.
        let xml = "<samlp:Response>ok</samlp:Response>";
        let token = STANDARD.encode(xml.as_bytes());
        let decoded = saml_decode(token).unwrap();
        assert_eq!(decoded, xml);
    }
}
