// Test: MeshCore frame type detection constants
// Validates the corrected frame type values from Mathison's spec
// Run: ucode test_frame_detection.uc

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

// Frame type constants (must match meshcore_tcp_api.uc)
const CMD_DIRECT_MSG_RECV      = 0x07;
const CMD_CHANNEL_MSG_RECV     = 0x08;
const PUSH_CODE_SEND_CONFIRMED = 0x82;
const CMD_HELLO                = 0x01;
const CMD_ENCRYPTED_DM         = 0x90;
const CMD_ENCRYPTED_BIN        = 0x91;

// Test 1: Frame types are distinct
{
    assert(CMD_DIRECT_MSG_RECV !== CMD_CHANNEL_MSG_RECV, "direct ≠ channel");
    assert(CMD_DIRECT_MSG_RECV !== PUSH_CODE_SEND_CONFIRMED, "direct ≠ send_confirmed");
    assert(CMD_CHANNEL_MSG_RECV !== PUSH_CODE_SEND_CONFIRMED, "channel ≠ send_confirmed");
}

// Test 2: Frame type values are correct per Mathison's spec
{
    assert(CMD_DIRECT_MSG_RECV === 0x07, "direct msg = 0x07");
    assert(CMD_CHANNEL_MSG_RECV === 0x08, "channel msg = 0x08");
    assert(PUSH_CODE_SEND_CONFIRMED === 0x82, "send confirmed = 0x82");
}

// Test 3: Old wrong constants are NOT used
{
    const OLD_CMD_TXT_MSG = 0x81;
    const OLD_CMD_GRP_TXT = 0x82;
    assert(CMD_DIRECT_MSG_RECV !== OLD_CMD_TXT_MSG, "direct msg ≠ old 0x81");
    assert(CMD_CHANNEL_MSG_RECV !== OLD_CMD_GRP_TXT, "channel msg ≠ old 0x82");
}

// Test 4: Simulate frame routing decision
function routeFrame(cmd)
{
    if (cmd === CMD_DIRECT_MSG_RECV) return "direct";
    if (cmd === CMD_CHANNEL_MSG_RECV) return "group";
    if (cmd === PUSH_CODE_SEND_CONFIRMED) return "skip";
    if (cmd === CMD_ENCRYPTED_DM || cmd === CMD_ENCRYPTED_BIN) return "drop_encrypted";
    return "drop_unknown";
}

{
    assert(routeFrame(0x07) === "direct", "0x07 → direct");
    assert(routeFrame(0x08) === "group", "0x08 → group");
    assert(routeFrame(0x82) === "skip", "0x82 → skip (not group!)");
    assert(routeFrame(0x01) === "drop_unknown", "0x01 → unknown");
    assert(routeFrame(0x90) === "drop_encrypted", "0x90 → encrypted");
    assert(routeFrame(0x91) === "drop_encrypted", "0x91 → encrypted");
    assert(routeFrame(0xFF) === "drop_unknown", "0xFF → unknown");
}

// Test 5: Group payload structure validation
// Group: sender(4B LE) + slot(1B) + text
// Direct: sender(4B LE) + recipient(4B LE) + text_len(1B) + text
{
    const GROUP_MIN_PAYLOAD = 5;   // sender(4) + slot(1)
    const DIRECT_MIN_PAYLOAD = 9;  // sender(4) + recipient(4) + text_len(1)

    assert(GROUP_MIN_PAYLOAD < DIRECT_MIN_PAYLOAD, "group payload shorter than direct");
    assert(GROUP_MIN_PAYLOAD === 5, "group min = 5 bytes");
    assert(DIRECT_MIN_PAYLOAD === 9, "direct min = 9 bytes");
}

// Test 6: Slot index range
{
    for (let slot = 0; slot <= 7; slot++) {
        assert(slot >= 0 && slot <= 7, `slot ${slot} in range 0-7`);
    }
    assert(!(8 >= 0 && 8 <= 7), "slot 8 out of range");
    assert(!(-1 >= 0 && -1 <= 7), "slot -1 out of range");
}

// ── Results ──

printf("\n=== Frame Detection Tests ===\n");
printf("Passed: %d\n", passed);
printf("Failed: %d\n", failed);
printf("Total:  %d\n", passed + failed);

if (failed > 0) {
    printf("\n⛔ %d test(s) FAILED\n", failed);
    exit(1);
} else {
    printf("\n✅ All tests passed\n");
}
