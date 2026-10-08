//
//  Extensions:AppExtensions.swift
//  VideoPlayer
//
//  Created by hara ryuto   on 2025/06/20.
//

import Foundation

/// StringをIdentifiableにするためのヘルパー
extension String: Identifiable {
    public var id: String { self }
}

/// TimeIntervalをMM:SS形式の文字列にフォーマットする拡張
extension TimeInterval {
    var formattedString: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
