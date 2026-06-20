// =====================================================================
// test_channel_parser.uc
// =====================================================================
//
// Unit test for PACKET_CHANNEL_INFO (0x12) parser
// Tests parseChannelInfo() with Mathison's hex sample
//
// Sample from Mathison (2026-06-20 00:00 PDT):
//   Channel: TestChannel (index 1)
//   Secret: AA BB CC DD EE FF 00 11 22 33 44 55 66 77 88 99
//   Raw hex: 12 01 54 65 73 74 43 68 61 6E 6E 65 6C + nulls + AA BB CC...
//
// =====================================================================

import * as discovery from "meshcore_tcp_discovery";

function assert(condition, message)
{
    if (!condition) {
        printf("FAIL: %s\\n", message);
        exit(1);
    }
    printf("PASS: %s\\n", message);
}

function bytesEqual(arr1, arr2, label)
{
    if (!arr1 || !arr2) {
        assert(arr1 === arr2, label);
        return;
    }
    if (length(arr1) !== length(arr2)) {
        assert(false, sprintf("%s: length mismatch (%d vs %d)", 
               label, length(arr1), length(arr2)));
        return;
    }
    for (let i = 0; i < length(arr1); i++) {
        if (arr1[i] !== arr2[i]) {
            assert(false, sprintf("%s: byte %d mismatch (0x%02x vs 0x%02x)",
                   label, i, arr1[i], arr2[i]));
            return;
        }
    }
    assert(true, label);
}

// =====================================================================
// Test 1: Parse Mathison's sample hex data
// =====================================================================

function test_parse_sample_channel()
{
    printf("\\n=== Test 1: Parse Sample Channel Info ===\\n");
    
    // Build sample data: 50 bytes
    // 12 01 54 65 73 74 43 68 61 6E 6E 65 6C [nulls] [secret]
    const sample = [
        0x12,                                           // Packet ID
        0x01,                                           // Index 1
        0x54, 0x65, 0x73, 0x74, 0x43, 0x68,           // "TestCh"
        0x61, 0x6E, 0x6E, 0x65, 0x6C,                 // "annel"
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,           // Null padding
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,           // Secret key
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55,
        0x66, 0x77, 0x88, 0x99
    ];
    
    assert(length(sample) === 50, "Sample data is 50 bytes");
    
    // Parse
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed !== null, "Parser returns non-null result");
    assert(parsed.packet_id === 0x12, "Packet ID is 0x12");
    assert(parsed.channel_index === 1, "Channel index is 1");
    assert(parsed.channel_name === "TestChannel", "Channel name is TestChannel");
    assert(parsed.is_configured === true, "is_configured is true");
    
    // Verify secret key
    const expectedSecret = [
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
        0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99
    ];
    bytesEqual(parsed.secret_key, expectedSecret, "Secret key matches");
}

// =====================================================================
// Test 2: Parse empty slot (all zeros)
// =====================================================================

function test_parse_empty_slot()
{
    printf("\\n=== Test 2: Parse Empty Slot ===\\n");
    
    // Build empty slot data: all zeros
    const empty = [];
    for (let i = 0; i < 50; i++) {
        push(empty, 0x00);
    }
    empty[0] = 0x12;  // Packet ID must be correct
    
    const parsed = discovery.parseChannelInfoForTest(empty);
    
    assert(parsed !== null, "Parser returns non-null result");
    assert(parsed.channel_name === "", "Channel name is empty");
    assert(parsed.is_configured === false, "is_configured is false");
}

// =====================================================================
// Test 3: Parse channel with partial name (null-padded)
// =====================================================================

function test_parse_short_name()
{
    printf("\\n=== Test 3: Parse Short Channel Name ===\\n");
    
    // Build sample: "TacNet" (6 chars) + 26 nulls
    const sample = [];
    push(sample, 0x12);     // Packet ID
    push(sample, 0x02);     // Index 2
    
    // Name: "TacNet"
    const name = "TacNet";
    for (let i = 0; i < 6; i++) {
        push(sample, name.charCodeAt(i));
    }
    // Pad with nulls to 32 bytes
    for (let i = 6; i < 32; i++) {
        push(sample, 0x00);
    }
    // Add secret key
    for (let i = 0; i < 16; i++) {
        push(sample, 0x99);  // Non-zero to indicate configured
    }
    
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed !== null, "Parser returns non-null result");
    assert(parsed.channel_index === 2, "Channel index is 2");
    assert(parsed.channel_name === "TacNet", "Channel name is TacNet");
    assert(parsed.is_configured === true, "is_configured is true");
}

// =====================================================================
// Test 4: Public channel (all-zero secret)
// =====================================================================

function test_parse_public_channel()
{
    printf("\\n=== Test 4: Parse Public Channel (Zero Secret) ===\\n");
    
    // Build sample: "Public" + nulls + all-zero secret
    const sample = [];
    push(sample, 0x12);     // Packet ID
    push(sample, 0x03);     // Index 3
    
    // Name: "Public"
    const name = "Public";
    for (let i = 0; i < 6; i++) {
        push(sample, name.charCodeAt(i));
    }
    // Pad with nulls
    for (let i = 6; i < 32; i++) {
        push(sample, 0x00);
    }
    // Secret: all zeros
    for (let i = 0; i < 16; i++) {
        push(sample, 0x00);
    }
    
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed !== null, "Parser returns non-null result");
    assert(parsed.channel_name === "Public", "Channel name is Public");
    assert(parsed.is_configured === false, "is_configured is false (zero secret)");
}

// =====================================================================
// Test 5: Invalid packet ID
// =====================================================================

function test_parse_invalid_packet_id()
{
    printf("\\n=== Test 5: Invalid Packet ID ===\\n");
    
    const sample = [];
    push(sample, 0x13);     // WRONG packet ID (not 0x12)
    for (let i = 1; i < 50; i++) {
        push(sample, 0x00);
    }
    
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed === null, "Parser returns null for wrong packet ID");
}

// =====================================================================
// Test 6: Insufficient data
// =====================================================================

function test_parse_insufficient_data()
{
    printf("\\n=== Test 6: Insufficient Data ===\\n");
    
    const truncated = [0x12, 0x01, 0x54];  // Only 3 bytes
    
    const parsed = discovery.parseChannelInfoForTest(truncated);
    
    assert(parsed === null, "Parser returns null for truncated data");
}

// =====================================================================
// Test 7: Channel at max index
// =====================================================================

function test_parse_max_index()
{
    printf("\\n=== Test 7: Channel at Max Index (7) ===\\n");
    
    const sample = [];
    push(sample, 0x12);     // Packet ID
    push(sample, 0x07);     // Index 7 (max)
    
    // Name: "Emergency"
    const name = "Emergency";
    for (let i = 0; i < length(name); i++) {
        push(sample, name.charCodeAt(i));
    }
    // Pad with nulls
    while (length(sample) < 2 + 32) {
        push(sample, 0x00);
    }
    // Add secret
    for (let i = 0; i < 16; i++) {
        push(sample, 0xAA);
    }
    
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed !== null, "Parser returns non-null result");
    assert(parsed.channel_index === 7, "Channel index is 7");
    assert(parsed.channel_name === "Emergency", "Channel name is Emergency");
    assert(parsed.is_configured === true, "is_configured is true");
}

// =====================================================================
// Test 8: Invalid index (out of range)
// =====================================================================

function test_parse_invalid_index()
{
    printf("\\n=== Test 8: Invalid Index (> 7) ===\\n");
    
    const sample = [];
    for (let i = 0; i < 50; i++) {
        push(sample, 0x00);
    }
    sample[0] = 0x12;       // Packet ID
    sample[1] = 0x08;       // INVALID index (> 7)
    
    const parsed = discovery.parseChannelInfoForTest(sample);
    
    assert(parsed === null, "Parser returns null for invalid index");
}

// =====================================================================
// Main test runner
// =====================================================================

printf("\\n");
printf("================================================================================\\n");
printf("  MESHCORE CHANNEL PARSER UNIT TESTS\\n");
printf("================================================================================\\n");

test_parse_sample_channel();
test_parse_empty_slot();
test_parse_short_name();
test_parse_public_channel();
test_parse_invalid_packet_id();
test_parse_insufficient_data();
test_parse_max_index();
test_parse_invalid_index();

printf("\\n");
printf("================================================================================\\n");
printf("  ALL TESTS PASSED ✅\\n");
printf("================================================================================\\n");
printf("\\n");

exit(0);
