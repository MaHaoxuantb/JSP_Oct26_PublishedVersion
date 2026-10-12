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
        var Relationships: [[Float64]]
        var BlockStatus: [[UUID]]
        var Capitals: [[Bool]] // True for each capitals
        var CellCosts: [[Float64]]
        var BlocksContained: [OneColorBlock]
        
        struct OneColorBlock {
            let id: UUID
            var CellCost: Int
            
            init(CellCost: Int) {
                self.id = UUID()
                self.CellCost = CellCost
            }
        }
        
        init(rowNum: Int, colNum: Int) {
            self.Relationships = Array(
                repeating: Array(repeating: 0.5, count: colNum - 1),
                count: rowNum - 1
            )
            self.BlockStatus = Array(
                repeating: Array(repeating: UUID(), count: colNum),
                count: rowNum
            )
            self.Capitals = Array(
                repeating: Array(repeating: false, count: colNum),
                count: rowNum
            )
            self.CellCosts = Array(
                repeating: Array(repeating: 0.0, count: colNum),
                count: rowNum
            )
            self.BlocksContained = []
        }
    }
}

struct OriginalCondition {
    var Status: [[Int]]
    
    init(Status: [[Int]]) {
        self.Status = Status
    }
}
