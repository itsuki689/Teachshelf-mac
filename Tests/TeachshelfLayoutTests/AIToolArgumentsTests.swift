import Foundation
import Testing
import TeachshelfCore
@testable import Teachshelf

struct AIToolArgumentsTests {
    let schema: [String: Any] = ["type": "object", "properties": [
        "flag": ["type": "boolean"], "limit": ["type": "integer", "minimum": 1, "maximum": 100],
        "title": ["type": "string"], "nested": ["type": "object", "properties": ["enabled": ["type": "boolean"]], "required": ["enabled"]],
        "flags": ["type": "array", "items": ["type": "boolean"], "maxItems": 2]
    ], "required": ["flag"], "additionalProperties": false]
    @Test func compatibleTypedStringsAreConvertedWithoutChangingText() throws {
        let result = try AIToolArguments.decode(#"{"flag":"False","limit":"20","title":"True","nested":"{\"enabled\":\"True\"}","flags":"[\"True\",\"False\"]"}"#, schema: schema)
        #expect(result["flag"] as? Bool == false)
        #expect(result["limit"] as? Int == 20)
        #expect(result["title"] as? String == "True")
        #expect((result["nested"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(result["flags"] as? [Bool] == [true, false])
    }
    @Test func ambiguousWrongAndOutOfBoundsArgumentsStillFailValidation() throws {
        for raw in [#"{"flag":"yes"}"#, #"{"flag":1}"#, #"{"flag":"True","limit":"1.2"}"#, #"{"flag":"True","limit":"101"}"#,
                    #"{"flag":"True","limit":"9223372036854775808"}"#, #"{"flag":"True","unknown":"value"}"#,
                    #"{"title":"False"}"#, #"{"flag":"True","flags":"[true,false,true]"}"#,
                    #"{"flag":"True","nested":"{'enabled': True}"}"#] {
            #expect(throws: (any Error).self) { try AIToolArguments.decode(raw, schema: schema) }
        }
    }
    @Test func realPlanSchemaConvertsBooleansButPreservesIDsTitlesAndGuards() throws {
        let definition = try #require(PlanMCPTools.definitions.first { $0["name"] as? String == "teachshelf_create_plan" })
        let schema = definition["inputSchema"] as! [String: Any]
        let result = try AIToolArguments.decode(#"{"library_id":"library","request_id":"test-id","fields":{"title":"False","has_execution_time":"False","completion_required":"True"}}"#, schema: schema)
        #expect(result["library_id"] as? String == "library")
        let fields = result["fields"] as! [String: Any]
        #expect(fields["title"] as? String == "False")
        #expect(fields["has_execution_time"] as? Bool == false)
        #expect(fields["completion_required"] as? Bool == true)
    }
}
