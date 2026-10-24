import * as channel_export from "channel_export";

let failures = 0;

function check(name, condition)
{
    if (condition) {
        printf("ok   - %s\n", name);
    }
    else {
        printf("FAIL - %s\n", name);
        failures++;
    }
}

const messages = [
    { when: 0, textfrom: 'Alice, "N0CALL"', text: 'hello, "world"' },
    { when: null, textfrom: "Bob", text: "two\nlines" }
];

const csv = channel_export.build("#Tac/Net secret", messages, "csv", time());
check("CSV filename is sanitized", index(csv.filename, "Tac-Net-") === 0 && index(csv.filename, ".csv") === length(csv.filename) - 4);
check("CSV header is present", index(csv.data, "timestamp,from,message\r\n") === 0);
check("CSV quotes and escapes fields", index(csv.data, '"Alice, ""N0CALL""","hello, ""world"""') >= 0);
check("CSV retains quoted multiline text", index(csv.data, '"Bob","two\nlines"') >= 0);

const text = channel_export.build("#Tac/Net secret", messages, "text", time());
check("text filename uses txt", index(text.filename, ".txt") === length(text.filename) - 4);
check("text header excludes the channel key", index(text.data, "Channel: #Tac/Net\n") === 0 && index(text.data, "secret") < 0);
check("epoch zero is formatted", index(text.data, "[] Alice") < 0 && index(text.data, "] Alice") >= 0);

exit(failures > 0 ? 1 : 0);
