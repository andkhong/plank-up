# tool

## Testing on a phone

A phone is the only surface that can reproduce the real geometry — camera at
floor level, side-on, a body's length away. A laptop webcam sits at eye level
with the user facing it, which is the wrong view for every exercise here.

Browsers only grant camera access on a secure origin. `localhost` qualifies;
`http://192.168.x.x` does not, and both iOS Safari and Android Chrome refuse
`getUserMedia` over plain HTTP without telling the page why. So the LAN server
speaks HTTPS with a self-signed certificate.

```bash
cd app && flutter build web --release
python3 tool/serve_https.py
```

Open the printed URL on a phone on the same wifi, proceed past the certificate
warning, and allow the camera.

### Regenerating the certificate

`tool/certs/` is gitignored — a private key must never be committed, and the
certificate is pinned to one machine's LAN address anyway. Substitute your own:

```bash
mkdir -p tool/certs && cd tool/certs
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=<your-lan-ip>" \
  -addext "subjectAltName=IP:<your-lan-ip>,IP:127.0.0.1,DNS:localhost"
```

The `subjectAltName` is not optional. A certificate carrying only a `CN` is
rejected outright by modern browsers, and the failure looks like a network
error rather than a certificate problem.

## validate_fixtures.dart

Checks the landmark fixture corpus without needing the app package resolved —
the recorder may run on a machine that has not run `pub get`. The Dart loader
in `app/test/support/fixture_format.dart` is authoritative if the two ever
disagree.
