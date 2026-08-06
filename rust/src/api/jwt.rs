use flutter_rust_bridge::frb;
use serde_json::Value;

#[derive(Debug, Clone)]
pub struct JwtDecodeResult {
    pub header: String,
    pub payload: String,
    pub signature: String,
    pub is_valid: bool,
    pub error: Option<String>,
}

#[frb(sync)]
pub fn decode_jwt(token: String, secret: Option<String>) -> JwtDecodeResult {
    // Basic split
    let parts: Vec<&str> = token.trim().split('.').collect();
    if parts.len() != 3 && parts.len() != 5 {
        return JwtDecodeResult {
            header: "{}".to_string(),
            payload: "{}".to_string(),
            signature: "".to_string(),
            is_valid: false,
            error: Some("Invalid JWT format (expected 3 or 5 parts)".to_string()),
        };
    }

    let header_b64 = parts[0];
    let payload_b64 = parts[1];
    let signature = parts.last().unwrap_or(&"");

    let header_json = decode_base64_json(header_b64);
    let payload_json = decode_base64_json(payload_b64);

    let mut is_valid = false;
    let mut error = None;

    if let Some(sec) = secret {
        if !sec.is_empty() && parts.len() == 3 {
            // Attempt to verify standard JWS
            // We use jsonwebtoken crate for verification if algorithm is known.
            // For now, doing a basic check if jsonwebtoken can decode it.
            use jsonwebtoken::{decode, decode_header, DecodingKey, Validation};

            if let Ok(hdr) = decode_header(&token) {
                let mut validation = Validation::new(hdr.alg);
                validation.validate_exp = false; // Just verify signature for tool
                validation.validate_nbf = false;
                validation.required_spec_claims.clear();

                let key_result = match hdr.alg {
                    jsonwebtoken::Algorithm::HS256
                    | jsonwebtoken::Algorithm::HS384
                    | jsonwebtoken::Algorithm::HS512 => {
                        Ok(DecodingKey::from_secret(sec.as_bytes()))
                    }
                    jsonwebtoken::Algorithm::RS256
                    | jsonwebtoken::Algorithm::RS384
                    | jsonwebtoken::Algorithm::RS512
                    | jsonwebtoken::Algorithm::PS256
                    | jsonwebtoken::Algorithm::PS384
                    | jsonwebtoken::Algorithm::PS512 => {
                        DecodingKey::from_rsa_pem(sec.as_bytes()).map_err(|e| e.to_string())
                    }
                    jsonwebtoken::Algorithm::ES256 | jsonwebtoken::Algorithm::ES384 => {
                        DecodingKey::from_ec_pem(sec.as_bytes()).map_err(|e| e.to_string())
                    }
                    jsonwebtoken::Algorithm::EdDSA => {
                        DecodingKey::from_ed_pem(sec.as_bytes()).map_err(|e| e.to_string())
                    }
                };

                match key_result {
                    Ok(key) => match decode::<Value>(&token, &key, &validation) {
                        Ok(_) => is_valid = true,
                        Err(e) => {
                            error = Some(e.to_string());
                            is_valid = false;
                        }
                    },
                    Err(e) => {
                        error = Some(format!("Invalid key format for {:?}: {}", hdr.alg, e));
                        is_valid = false;
                    }
                }
            } else {
                error = Some("Unsupported algorithm or invalid header".to_string());
            }
        }
    }

    JwtDecodeResult {
        header: header_json,
        payload: payload_json,
        signature: signature.to_string(),
        is_valid,
        error,
    }
}

#[frb(sync)]
pub fn encode_jwt(header: String, payload: String, secret: String) -> Result<String, String> {
    use jsonwebtoken::{encode, EncodingKey, Header};

    let header_val: Value =
        serde_json::from_str(&header).map_err(|e| format!("Invalid Header JSON: {}", e))?;
    let payload_val: Value =
        serde_json::from_str(&payload).map_err(|e| format!("Invalid Payload JSON: {}", e))?;

    // Extract algorithm from header if present
    let mut alg = jsonwebtoken::Algorithm::HS256;
    if let Some(alg_str) = header_val.get("alg").and_then(|v| v.as_str()) {
        if let Ok(parsed_alg) = alg_str.parse::<jsonwebtoken::Algorithm>() {
            alg = parsed_alg;
        }
    }

    let mut jwt_header = Header::new(alg);
    // Copy other standard header fields if needed, but jsonwebtoken crate handles typical ones.
    if let Some(typ) = header_val.get("typ").and_then(|v| v.as_str()) {
        jwt_header.typ = Some(typ.to_string());
    }
    if let Some(kid) = header_val.get("kid").and_then(|v| v.as_str()) {
        jwt_header.kid = Some(kid.to_string());
    }

    let key_result = match alg {
        jsonwebtoken::Algorithm::HS256
        | jsonwebtoken::Algorithm::HS384
        | jsonwebtoken::Algorithm::HS512 => Ok(EncodingKey::from_secret(secret.as_bytes())),
        jsonwebtoken::Algorithm::RS256
        | jsonwebtoken::Algorithm::RS384
        | jsonwebtoken::Algorithm::RS512
        | jsonwebtoken::Algorithm::PS256
        | jsonwebtoken::Algorithm::PS384
        | jsonwebtoken::Algorithm::PS512 => {
            EncodingKey::from_rsa_pem(secret.as_bytes()).map_err(|e| e.to_string())
        }
        jsonwebtoken::Algorithm::ES256 | jsonwebtoken::Algorithm::ES384 => {
            EncodingKey::from_ec_pem(secret.as_bytes()).map_err(|e| e.to_string())
        }
        jsonwebtoken::Algorithm::EdDSA => {
            EncodingKey::from_ed_pem(secret.as_bytes()).map_err(|e| e.to_string())
        }
    };

    let key = key_result?;

    match encode(&jwt_header, &payload_val, &key) {
        Ok(token) => Ok(token),
        Err(e) => Err(e.to_string()),
    }
}

fn decode_base64_json(b64: &str) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    if let Ok(bytes) = URL_SAFE_NO_PAD.decode(b64) {
        if let Ok(s) = String::from_utf8(bytes) {
            if let Ok(val) = serde_json::from_str::<Value>(&s) {
                return serde_json::to_string_pretty(&val).unwrap_or(s);
            }
            return s;
        }
    }
    // Fallback if URL_SAFE_NO_PAD fails, try STANDARD
    use base64::engine::general_purpose::STANDARD;
    if let Ok(bytes) = STANDARD.decode(b64) {
        if let Ok(s) = String::from_utf8(bytes) {
            if let Ok(val) = serde_json::from_str::<Value>(&s) {
                return serde_json::to_string_pretty(&val).unwrap_or(s);
            }
            return s;
        }
    }
    String::from("{}")
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_jwt_decode_es256() {
        let token = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.IvWNhrCRIVvH_El0TLAzpeCFHD-x63snHHkxKo00seW_YReANhGs2nmsEb3EP4eVyxFTA0_jRHe1qxLEWyfSzA";
        let public_key = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9\nq9UU8I5mEovUf86QZ7kOBIjJwqnzD1omageEHWwHdBO6B+dFabmdT9POxg==\n-----END PUBLIC KEY-----";

        let result = decode_jwt(token.to_string(), Some(public_key.to_string()));
        assert!(result.is_valid);

        let invalid_token = token.replacen("0", "", 1);
        let result = decode_jwt(invalid_token, Some(public_key.to_string()));
        println!(
            "Invalid isValid: {}, error: {:?}",
            result.is_valid, result.error
        );
        assert!(!result.is_valid);
    }
}
