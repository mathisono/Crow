// Test: Key derivation from passphrase
// Run: ucode test_key_derivation.uc
// Expected: Deterministic keys, correct length

import * as crypto from "../crypto/crypto.uc";

let passed = 0;
let failed = 0;

function assert(condition, label)
{
    if (condition) {
        passed++;
    } else {
        failed++;
        printf("FAIL: %s\n", label);
    }
}

function deriveKeyFromPassphrase(passphrase)
{
    return crypto.sha256hash(passphrase);
}

function keyBytesToBase64(keyBytes)
{
    let keyStr = "";
    for (let i = 0; i < length(keyBytes); i++) {
        keyStr += chr(keyBytes[i]);
    }
    return b64enc(keyStr);
}

// Test 1: Key is 32 bytes (SHA-256)
{
    const key = deriveKeyFromPassphrase("TestPassword123");
    assert(length(key) === 32, "key length is 32 bytes");
}

// Test 2: Same passphrase → same key (deterministic)
{
    const key1 = deriveKeyFromPassphrase("MyGroupKey");
    const key2 = deriveKeyFromPassphrase("MyGroupKey");
    let match = true;
    for (let i = 0; i < 32; i++) {
        if (key1[i] !== key2[i]) { match = false; break; }
    }
    assert(match, "same passphrase → same key");
}

// Test 3: Different passphrase → different key
{
    const key1 = deriveKeyFromPassphrase("Password1");
    const key2 = deriveKeyFromPassphrase("Password2");
    let match = true;
    for (let i = 0; i < 32; i++) {
        if (key1[i] !== key2[i]) { match = false; break; }
    }
    assert(!match, "different passphrase → different key");
}

// Test 4: Base64 encoding produces valid string
{
    const key = deriveKeyFromPassphrase("TestKey");
    const b64 = keyBytesToBase64(key);
    assert(type(b64) === "string", "base64 is a string");
    assert(length(b64) === 44, "base64 of 32 bytes = 44 chars");
}

// Test 5: Empty passphrase still produces valid 32-byte key
{
    const key = deriveKeyFromPassphrase("");
    assert(length(key) === 32, "empty passphrase → 32-byte key");
}

// ── Results ──

printf("\n=== Key Derivation Tests ===\n");
printf("Passed: %d\n", passed);
printf("Failed: %d\n", failed);
printf("Total:  %d\n", passed + failed);

if (failed > 0) {
    printf("\n⛔ %d test(s) FAILED\n", failed);
    exit(1);
} else {
    printf("\n✅ All tests passed\n");
}
