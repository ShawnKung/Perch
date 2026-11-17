#!/bin/bash
set -euo pipefail
umask 077
SIGNING="$HOME/Library/Application Support/Perch Signing"
KEYCHAIN="$SIGNING/signing.keychain-db"
mkdir -p "$SIGNING"
if [[ ! -f "$KEYCHAIN" ]]; then
  /usr/bin/openssl rand -base64 32 > "$SIGNING/keychain-password"
  export PERCH_SIGNING_PASSWORD
  PERCH_SIGNING_PASSWORD="$(cat "$SIGNING/keychain-password")"
  TEMP="$(mktemp -d "${TMPDIR:-/tmp}/perch-signing.XXXXXX")"
  trap 'rm -rf "$TEMP"' EXIT
  cat > "$TEMP/certificate.conf" <<'EOF'
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = Perch Local Code Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 \
    -config "$TEMP/certificate.conf" -keyout "$TEMP/key.pem" \
    -out "$SIGNING/certificate.pem" -passout env:PERCH_SIGNING_PASSWORD 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TEMP/key.pem" -in "$SIGNING/certificate.pem" \
    -out "$TEMP/identity.p12" -passin env:PERCH_SIGNING_PASSWORD -passout env:PERCH_SIGNING_PASSWORD
  security create-keychain -p "$PERCH_SIGNING_PASSWORD" "$KEYCHAIN" || { echo '创建签名钥匙串失败' >&2; exit 1; }
  security unlock-keychain -p "$PERCH_SIGNING_PASSWORD" "$KEYCHAIN" || { echo '解锁新签名钥匙串失败' >&2; exit 1; }
  security import "$TEMP/identity.p12" -k "$KEYCHAIN" -P "$PERCH_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null || { echo '导入签名证书失败' >&2; exit 1; }
  security set-key-partition-list -S apple-tool:,codesign: -s -k "$PERCH_SIGNING_PASSWORD" "$KEYCHAIN" >/dev/null || { echo '设置签名钥匙串访问权限失败' >&2; exit 1; }
  if [[ "${PERCH_CI_TRUST_SIGNING_CERT:-}" == 1 ]]; then
    [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
      echo '临时证书信任仅允许在 GitHub 托管运行器使用' >&2; exit 1;
    }
    sudo -n security add-trusted-cert -d -r trustRoot \
      -k /Library/Keychains/System.keychain "$SIGNING/certificate.pem" || {
      echo '设置 CI 临时代码签名信任失败' >&2; exit 1;
    }
  fi
fi
PERCH_SIGNING_PASSWORD="$(cat "$SIGNING/keychain-password")"
security unlock-keychain -p "$PERCH_SIGNING_PASSWORD" "$KEYCHAIN" || { echo '解锁签名钥匙串失败' >&2; exit 1; }
IDENTITY="$(/usr/bin/openssl x509 -in "$SIGNING/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
# Keep the certificate requirement stable across updates, rather than trusting an identifier alone.
codesign --force --timestamp=none --sign "$IDENTITY" --keychain "$KEYCHAIN" "$1" || {
  echo '代码签名失败；钥匙串中的签名身份如下：' >&2
  security find-identity "$KEYCHAIN" >&2 || true
  exit 1
}
