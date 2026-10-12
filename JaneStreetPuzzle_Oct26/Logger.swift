//
//  Logger.swift
//  JaneStreetPuzzle_Oct26
//
//  Created by Thomas B on 10/12/26.
//

import Foundation

class Logger {
    var basics: LogBasics
    var runLog: [oneRunLog] = []
    
    init(basics: LogBasics) {
        self.basics = basics
        self.runLog = []
    }
    
    struct LogBasics {
        let id: UUID = UUID()
        let StartTime: TimeInterval = Date().timeIntervalSince1970
    }
    
    struct oneRunLog {
        let id: UUID = UUID()
        let time: TimeInterval = Date().timeIntervalSince1970
        let energyGraph: [[Float64]] = [[]]
    }
}
