//
//  Storage.swift
//  MyTool
//
//  Created by Thomas B on 10/9/26.
//

import Foundation

class Board {
    let id : UUID
    let BoardBasics: BoardBasics
    var Relationships: Relationships
    var Energy: [[Float64]]
    
    init(rowNum: Int, colNum: Int) {
        self.id = UUID()
        self.BoardBasics = Board.BoardBasics(rowNum: rowNum, colNum: colNum)
        self.Relationships = Board.Relationships(rowNum: rowNum, colNum: colNum)
        self.Energy = Array(
            repeating: Array(repeating: 0.0, count: colNum),
            count: rowNum
        )
    }
    
    struct BoardBasics {
        let rowNum: Int
        let colNum: Int
        
        init(rowNum: Int, colNum: Int) {
            self.rowNum = rowNum
            self.colNum = colNum
        }
    }

    struct Relationships {
        var VerticalRelationships: [[Float64]]
        var HorizontalRelationships: [[Float64]]
        var ColorBlocks: [[UUID]]
        var Capitals: [[Bool]] // True for each capitals
        var VerticalEnergy: [[Float64]]
        var HorizontalEnergy: [[Float64]]
        var BlocksContained: ColorBlocksContained
        
        init(rowNum: Int, colNum: Int) {
            self.VerticalRelationships = Array(
                repeating: Array(repeating: 0.5, count: colNum - 1),
                count: rowNum
            )
            self.HorizontalRelationships = Array(
                repeating: Array(repeating: 0.5, count: colNum),
                count: rowNum - 1
            )
            self.ColorBlocks = Array(
                repeating: Array(repeating: UUID(), count: colNum),
                count: rowNum
            )
            self.Capitals = Array(
                repeating: Array(repeating: false, count: colNum),
                count: rowNum
            )
            self.VerticalEnergy = Array(
                repeating: Array(repeating: 0.5, count: colNum - 1),
                count: rowNum
            )
            self.HorizontalEnergy = Array(
                repeating: Array(repeating: 0.5, count: colNum),
                count: rowNum - 1
            )
            self.BlocksContained = ColorBlocksContained()
        }
        
        class ColorBlocksContained {
            var ids: [UUID]
            var blockCounts: [Int]
            init() {
                self.ids = []
                self.blockCounts = []
            }
        }
    }
}

struct OriginalCondition {
    var Status: [[Int]]
    
    init(Status: [[Int]]) {
        self.Status = Status
    }
}
