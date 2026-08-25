// Test: Gatekeeper per-channel ACL and wildcard matching
// Run: ucode test_gatekeeper_acl.uc
// Expected: All assertions pass

import * as gatekeeper from "../gatekeeper.uc";

global.DEBUG0 = function (...args) {};
global.DEBUG1 = function (...args) {};

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

// ── Setup ──

gatekeeper.setup({
    strict_gatekeeper: {
        enabled: true,
        gateway_callsign: "KJ6DZB",
        allowed_callsigns: ["K6DZB", "KN6PLV", "W2ABC", "W2DZB"]
    }
});

// ── Test: simpleWildcardMatch via enforceChannelAccess ──

// Helper: build a test message
function makeMsg(callsign, namekey)
{
    return {
        from: 0x12345678,
        data: {
            text_from: callsign,
            text_message: `${callsign} test message`
        },
        namekey: namekey,
        metadata: {}
    };
}

// Test 1: No ACL configured → allow all
{
    const config = { channels: {} };
    const msg = makeMsg("K6DZB", "#Test key==");
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, config);
    assert(result !== null, "no ACL → allow");
}

// Test 2: ACL with require_callsign=false → allow all
{
    const config = {
        channels: {
            "#Test key==": {
                access_control: { require_callsign: false }
            }
        }
    };
    const msg = makeMsg("ANYONE", "#Test key==");
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, config);
    assert(result !== null, "require_callsign=false → allow");
}

// Test 3: ACL with allowed_callsigns, matching callsign → allow
{
    const config = {
        channels: {
            "#TacNet key==": {
                access_control: {
                    require_callsign: true,
                    allowed_callsigns: ["K6*", "W2*"]
                }
            }
        }
    };
    const msg = makeMsg("K6DZB", "#TacNet key==");
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, config);
    assert(result !== null, "K6DZB matches K6* → allow");
}

// Test 4: ACL with allowed_callsigns, non-matching callsign → deny
{
    const config = {
        channels: {
            "#TacNet key==": {
                access_control: {
                    require_callsign: true,
                    allowed_callsigns: ["K6*", "W2*"]
                }
            }
        }
    };
    const msg = makeMsg("N5ABC", "#TacNet key==");
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, config);
    assert(result === null, "N5ABC doesn't match K6*/W2* → deny");
}

// Test 5: Deny list takes priority
{
    const config = {
        channels: {
            "#TacNet key==": {
                access_control: {
                    require_callsign: true,
                    allowed_callsigns: ["K6*"],
                    deny_callsigns: ["K6SPAM"]
                }
            }
        }
    };
    const msg1 = makeMsg("K6DZB", "#TacNet key==");
    const result1 = gatekeeper.enforceChannelAccess(msg1, msg1.namekey, config);
    assert(result1 !== null, "K6DZB matches K6*, not in deny → allow");

    const msg2 = makeMsg("K6SPAM", "#TacNet key==");
    const result2 = gatekeeper.enforceChannelAccess(msg2, msg2.namekey, config);
    assert(result2 === null, "K6SPAM matches deny list → deny");
}

// Test 6: No callsign → deny when require_callsign=true
{
    const config = {
        channels: {
            "#TacNet key==": {
                access_control: {
                    require_callsign: true,
                    allowed_callsigns: ["K6*"]
                }
            }
        }
    };
    const msg = {
        from: 0x12345678,
        data: { text_message: "test" },  // No text_from!
        namekey: "#TacNet key==",
        metadata: {}
    };
    const result = gatekeeper.enforceChannelAccess(msg, msg.namekey, config);
    assert(result === null, "no callsign + require=true → deny");
}

// Test 7: Suffix wildcard
{
    const config = {
        channels: {
            "#Test key==": {
                access_control: {
                    require_callsign: true,
                    allowed_callsigns: ["*DZB"]
                }
            }
        }
    };
    const msg1 = makeMsg("K6DZB", "#Test key==");
    const r1 = gatekeeper.enforceChannelAccess(msg1, msg1.namekey, config);
    assert(r1 !== null, "K6DZB matches *DZB → allow");

    const msg2 = makeMsg("W2DZB", "#Test key==");
    const r2 = gatekeeper.enforceChannelAccess(msg2, msg2.namekey, config);
    assert(r2 !== null, "W2DZB matches *DZB → allow");

    const msg3 = makeMsg("K6PLV", "#Test key==");
    const r3 = gatekeeper.enforceChannelAccess(msg3, msg3.namekey, config);
    assert(r3 === null, "K6PLV doesn't match *DZB → deny");
}

// ── Results ──

printf("\n=== Gatekeeper ACL Tests ===\n");
printf("Passed: %d\n", passed);
printf("Failed: %d\n", failed);
printf("Total:  %d\n", passed + failed);

if (failed > 0) {
    printf("\n⛔ %d test(s) FAILED\n", failed);
    exit(1);
} else {
    printf("\n✅ All tests passed\n");
}
