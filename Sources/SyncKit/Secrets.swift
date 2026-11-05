import Foundation

/// 密钥打码：值换成「•••• + 指纹前 6 位」，看得出两边是否相同，看不到原文
public enum Secrets {
    public static func masked(_ value: String) -> String {
        value.isEmpty ? "" : "••••" + Hash.hex(Data(value.utf8)).prefix(6)
    }

    /// 文本里 `NAME=value`、`export NAME="value"`、`NAME: value` 形式的值打码，其余行原样
    public static func mask(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { maskLine(String($0)) }.joined(separator: "\n")
    }

    static func maskLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return line }
        guard let sep = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return line }
        let name = line[..<sep].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "export ", with: "")
        // 只认变量名样子的左边，避免把 URL、命令行误伤
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return line }
        var value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return line }
        return String(line[...sep]) + " " + masked(value)
    }
}
