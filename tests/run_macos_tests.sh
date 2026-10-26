#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
TEST_KEYCHAIN_CREATED=0
unset NATIVE_TEST_KEYCHAIN
cleanup() {
  if [[ "${TEST_KEYCHAIN_CREATED}" == 1 ]]; then /usr/bin/security delete-keychain "${NATIVE_TEST_KEYCHAIN}" >/dev/null 2>&1 || true; fi
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT
if [[ "${KEYCHAIN_SECRETS_TEST_REAL_KEYCHAIN:-0}" == 1 ]]; then
  export NATIVE_TEST_KEYCHAIN="${TEST_DIR}/synthetic.keychain-db"
  /usr/bin/security create-keychain -p '' "${NATIVE_TEST_KEYCHAIN}"
  TEST_KEYCHAIN_CREATED=1
  /usr/bin/security unlock-keychain -p '' "${NATIVE_TEST_KEYCHAIN}"
fi
python3 -m unittest discover -s "${ROOT_DIR}/tests" -p 'test_*.py' -v
mkdir -p "${TEST_DIR}/NativeTests.app/Contents/MacOS" "${TEST_DIR}/NativeTests.app/Contents/Resources"
cp "${ROOT_DIR}/scripts/keychain_secrets.py" "${TEST_DIR}/NativeTests.app/Contents/Resources/"
chmod +x "${TEST_DIR}/NativeTests.app/Contents/Resources/keychain_secrets.py"
clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa "${ROOT_DIR}/macos/KeychainSecretsApp.m" -o "${TEST_DIR}/KeychainSecrets"
clang -fobjc-arc -Wall -Wextra -Werror -framework Cocoa "${ROOT_DIR}/tests/native_tests.m" -o "${TEST_DIR}/NativeTests.app/Contents/MacOS/NativeTests"
"${TEST_DIR}/NativeTests.app/Contents/MacOS/NativeTests"
