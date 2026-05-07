import Foundation

public enum TextSanitizer {
    public static func stripInvisibleControls(_ raw: String) -> String {
        String(
            raw.unicodeScalars.filter { scalar in
                let category = scalar.properties.generalCategory
                if category == .format {
                    return false
                }
                if category == .control && scalar.value != 10 && scalar.value != 9 {
                    return false
                }
                return true
            }
        )
    }
}
