import Testing
@testable import CodexBarCore

struct OneConsoleJSONTests {
    @Test
    func `string lookup honors caller key priority across the full tree`() {
        let value: [String: Any] = [
            "token": "generic-token",
            "data": [
                "secToken": "preferred-sec-token",
            ],
        ]

        let result = OneConsoleJSON.findFirstString(
            forKeys: ["secToken", "token"],
            in: value)

        #expect(result == "preferred-sec-token")
    }

    @Test
    func `lookup skips invalid values before a nested valid value`() {
        let value: [String: Any] = [
            "count": "not-a-number",
            "data": [
                "count": "42",
            ],
        ]

        #expect(OneConsoleJSON.findFirstInt(forKeys: ["count"], in: value) == 42)
    }

    @Test
    func `array lookup preserves key priority and skips invalid values`() {
        let value: [String: Any] = [
            "fallback": [1],
            "preferred": "not-an-array",
            "data": [
                "preferred": [2, 3],
            ],
        ]

        let result = OneConsoleJSON.findFirstArray(
            forKeys: ["preferred", "fallback"],
            in: value) as? [Int]

        #expect(result == [2, 3])
    }
}
