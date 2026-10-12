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
    var Energy: [[Int]]
    
    init(BoardBasics: BoardBasics, Relationships: Relationships, Energy: [[Int]]) {
        self.id = UUID()
        self.BoardBasics = BoardBasics
        self.Relationships = Relationships
        self.Energy = Energy
    }
    
    struct BoardBasics {
        let RowNum: Int32
        let ColNum: Int32
        
        init(RowNum: Int32, ColNum: Int32) {
            self.RowNum = RowNum
            self.ColNum = ColNum
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
        
        init(RowNum: Int, ColNum: Int) {
            self.Relationships = Array(
                repeating: Array(repeating: 0.0, count: ColNum - 1),
                count: RowNum - 1
            )
            self.BlockStatus = Array(
                repeating: Array(repeating: UUID(), count: ColNum),
                count: RowNum
            )
            self.Capitals = Array(
                repeating: Array(repeating: false, count: ColNum),
                count: RowNum
            )
            self.CellCosts = Array(
                repeating: Array(repeating: 0.0, count: ColNum),
                count: RowNum
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
