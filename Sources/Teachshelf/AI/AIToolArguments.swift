import Foundation
import TeachshelfCore

/// Some compatible servers serialize typed tool parameters as strings (e.g. Qwen's "True").
/// Convert only according to the declared schema; never coerce free text or infer missing fields.
enum AIToolArguments {
    static func decode(_ json: String, schema: [String: Any]) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let value = normalize(raw, schema: schema)
        try PlanMCPTools.validate(value, schema: schema)
        guard let arguments = value as? [String: Any] else { throw PlanMCPError("工具参数必须是 JSON 对象。") }
        return arguments
    }
    private static func normalize(_ value: Any, schema: [String: Any]) -> Any {
        if let variants = schema["anyOf"] as? [[String: Any]] {
            // Preserve already valid values, including text in nullable string fields.
            if variants.contains(where: { (try? PlanMCPTools.validate(value, schema: $0)) != nil }) { return value }
            for variant in variants {
                let candidate = normalize(value, schema: variant)
                if (try? PlanMCPTools.validate(candidate, schema: variant)) != nil { return candidate }
            }
            return value
        }
        var typed = value
        if let string = value as? String {
            switch schema["type"] as? String {
            case "boolean":
                switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true": typed = true
                case "false": typed = false
                default: break
                }
            case "integer":
                if string.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil, let number = Int(string) { typed = number }
            case "object", "array":
                if let decoded = try? JSONSerialization.jsonObject(with: Data(string.utf8)) { typed = decoded }
            default: break
            }
        }
        if schema["type"] as? String == "object", let object = typed as? [String: Any], let properties = schema["properties"] as? [String: [String: Any]] {
            return object.mapValuesWithKeys { key, item in properties[key].map { normalize(item, schema: $0) } ?? item }
        }
        if schema["type"] as? String == "array", let array = typed as? [Any], let itemSchema = schema["items"] as? [String: Any] {
            return array.map { normalize($0, schema: itemSchema) }
        }
        return typed
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
