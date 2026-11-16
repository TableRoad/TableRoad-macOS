# Test-only SSH keys

**Never use these anywhere real.** They are throwaway keys for the local Docker bastion, committed on purpose
so the SSH integration tests are reproducible. Encrypted keys use the passphrase `tableroad`.

| File | Format |
|---|---|
| `ed25519` | OpenSSH, ed25519, no passphrase |
| `ed25519_encrypted` | OpenSSH, ed25519, passphrase |
| `rsa` | OpenSSH, RSA 3072, no passphrase |
| `rsa_encrypted` | OpenSSH, RSA 3072, passphrase |
| `rsa_pem` | PEM (PKCS#1), RSA 3072, no passphrase |
| `ecdsa_p256` | OpenSSH, ECDSA P-256, no passphrase |
