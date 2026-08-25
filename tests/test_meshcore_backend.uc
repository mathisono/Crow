// =====================================================================
// test_meshcore_backend.uc
// =====================================================================
//
// Regression test for MeshCore backend selector defaults.
// Ensures enabling the MeshCore TCP API still injects the public channel
// entry, matching the APRS backend pattern.
// =====================================================================

import * as backend from "../meshcore_backend.uc";

function assert(condition, message)
{
    if (!condition) {
        printf("FAIL: %s\n", message);
        exit(1);
    }
    printf("PASS: %s\n", message);
}

{
    const config = {
        channels: [],
        meshcore_tcp_api: {
            enabled: true
        }
    };

    backend._test_ensure_default_public_channel(config);

    assert(length(config.channels) === 1, "default public channel added");
    assert(config.channels[0].namekey === "MeshCore izOH6cXN6mrJ5e26oRXNcg==", "public namekey");
    assert(config.channels[0].label === "MeshCore~Public", "public label");
}

assert(backend._test_backend_choice({
    meshcore_serial_api: { enabled: true }
}) === "serial", "USB serial backend selected");

assert(backend._test_backend_choice({
    meshcore_tcp_api: { enabled: true },
    meshcore_serial_api: { enabled: true }
}) === "tcp", "TCP remains preferred when both are enabled");

printf("\nMeshCore backend selector defaults OK\n");
