import Foundation
import UIKit

extension String {
    /// 動画のファイル名から拡張子や不要な文字列（UUID、タイムスタンプ、ランダムなハッシュ値など）を取り除き、
    /// UI表示用のクリーンなタイトルを生成します。
    var cleanVideoTitle: String {
        // 1. 拡張子を削除
        var text = (self as NSString).deletingPathExtension
        let originalText = text

        // 2. ユーザーが設定した除外文字列を削除
        if let words = UserDefaults.standard.array(forKey: "excludedTitleWordsList") as? [String] {
            for word in words {
                let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    text = text.replacingOccurrences(of: trimmed, with: " ", options: .caseInsensitive)
                }
            }
        }

        // 3. 不要なパターンの削除 (記号を消さずに、単語の境界を記号や空白で判定する)
        // UUID
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?=[^A-Za-z0-9]|$)", with: "", options: .regularExpression)

        // 6桁以上の数字の羅列（日付やタイムスタンプ、カメラのシーケンス番号など）
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)\\d{6,}(?=[^A-Za-z0-9]|$)", with: "", options: .regularExpression)

        // 接頭辞の削除 (大文字小文字を区別しない)
        text = text.replacingOccurrences(of: "(?<=[^A-Za-z0-9]|^)(LINE_ALBUM_|IMG_|VID_|RPReplay_)", with: "", options: [.regularExpression, .caseInsensitive])

        // 英数字が混ざった8文字以上のランダム文字列（ハッシュ値など）
        // (?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\\d) -> 単語内に英字と数字が両方含まれることを保証
        text = text.removingMatches(
            matching: "(?<=[^A-Za-z0-9]|^)(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\\d)[A-Za-z0-9]{8,}(?=[^A-Za-z0-9]|$)",
            keepingIfContainsRealWord: true
        )

        // 数字が含まれないアルファベットのみのランダム文字列対策（例: zJXShpZkIEIlXY）
        // 10文字以上で、大文字と小文字が混在し、かつ「小文字が3文字以上連続しない」不自然な単語（ハッシュ・ID特有のケース）
        text = text.removingMatches(
            matching: "(?<=[^A-Za-z0-9]|^)(?=.*[A-Z])(?=.*[a-z])(?![A-Za-z0-9]*[a-z]{3})[A-Za-z0-9]{10,}(?=[^A-Za-z0-9]|$)",
            keepingIfContainsRealWord: true
        )

        // URLエンコードされた文字列があれば戻す（%20など）
        text = text.removingPercentEncoding ?? text

        // 削除後に残った不要な記号の連続や、先頭・末尾の記号・空白を綺麗にする
        text = text.replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
        text = text.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: "^[_\\-~〜\\s\\[\\]()]+|[_\\-~〜\\s\\[\\]()]+$", with: "", options: .regularExpression)

        // 連続するスペースを1つにする
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)

        // もし完全にランダムな文字列のみで空になってしまったら、元々のファイル名（拡張子なし）をそのまま採用する
        if text.isEmpty {
            return originalText
        }

        return text
    }

    /// 正規表現にマッチした部分文字列を削除します。keepingIfContainsRealWord が true の場合、
    /// マッチした文字列の中に実在する単語が含まれていれば削除せずに残します。
    func removingMatches(matching pattern: String, keepingIfContainsRealWord: Bool) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let nsString = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: nsString.length))

        var result = self
        // 後ろから置換することで、インデックスのズレを防ぐ
        for match in matches.reversed() {
            let matchedString = nsString.substring(with: match.range)
            var shouldKeep = false

            if keepingIfContainsRealWord && matchedString.containsRealWord() {
                shouldKeep = true
            }

            if !shouldKeep {
                if let rangeToReplace = Range(match.range, in: result) {
                    result.replaceSubrange(rangeToReplace, with: "")
                }
            }
        }
        return result
    }

    /// 文字列の中に実在する単語（英語などの辞書に載っている単語）が含まれているかを判定します
    func containsRealWord() -> Bool {
        let checker = UITextChecker()
        let nsText = self as NSString

        // 1. 連続したアルファベットのブロックを抽出してチェック
        let letterBlocks = self.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
        for block in letterBlocks {
            let range = NSRange(location: 0, length: block.utf16.count)
            if checker.rangeOfMisspelledWord(in: block, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                return true
            }
        }

        // 2. キャメルケース（CamelCase）などで区切ってチェック（例: PartyVlog01 -> Party, Vlog）
        if let camelRegex = try? NSRegularExpression(pattern: "([A-Z]?[a-z]+|[A-Z]+(?![a-z]))") {
            let matches = camelRegex.matches(in: self, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let word = nsText.substring(with: match.range)
                if word.count >= 3 {
                    let range = NSRange(location: 0, length: word.utf16.count)
                    if checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                        return true
                    }
                }
            }
        }

        // 3. 最後のフォールバック：4〜8文字の部分文字列をすべてチェックし、辞書に存在すればOKとする
        // （長すぎる文字列での処理落ちを防ぐため、元の文字列が50文字以下の場合のみ）
        if self.count < 50 {
            let lowerText = self.lowercased()
            let chars = Array(lowerText)
            if chars.count >= 4 {
                for i in 0...(chars.count - 4) {
                    for j in (i + 3)..<min(chars.count, i + 8) {
                        let sub = String(chars[i...j])
                        let range = NSRange(location: 0, length: sub.utf16.count)
                        if checker.rangeOfMisspelledWord(in: sub, range: range, startingAt: 0, wrap: false, language: "en_US").location == NSNotFound {
                            return true
                        }
                    }
                }
            }
        }

        return false
    }
}
