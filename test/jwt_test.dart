import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/src/rust/frb_generated.dart';
import 'package:textutilz/src/rust/api/jwt.dart';

void main() {
  test('jwt invalid payload', () async {
    await RustLib.init();
    final token =
        "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.IvWNhrCRIVvH_El0TLAzpeCFHD-x63snHHkxKo00seW_YReANhGs2nmsEb3EP4eVyxFTA0_jRHe1qxLEWyfSzA";
    final public_key =
        "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9\nq9UU8I5mEovUf86QZ7kOBIjJwqnzD1omageEHWwHdBO6B+dFabmdT9POxg==\n-----END PUBLIC KEY-----";

    // 1. Decode original
    final result = decodeJwt(token: token, secret: public_key);
    print("Valid token: ${result.isValid}, error: ${result.error}");

    // 2. Modify payload
    final invalidToken = token.replaceFirst('0', '');
    final invalidResult = decodeJwt(token: invalidToken, secret: public_key);
    print(
      "Invalid token (payload): ${invalidResult.isValid}, error: ${invalidResult.error}",
    );

    // 3. Modify signature
    final invalidSig = token.substring(0, token.length - 1);
    final sigResult = decodeJwt(token: invalidSig, secret: public_key);
    print(
      "Invalid token (sig): ${sigResult.isValid}, error: ${sigResult.error}",
    );
  });
}
