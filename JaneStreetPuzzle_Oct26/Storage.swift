//
//  Storage.swift
//  MyTool
//
//  Created by Thomas B on 10/9/26.
//

import Foundation

struct Board {
    let id : UUID
    let BoardBasics: BoardBasics
    var OriginalCondition: OriginalCondition
    var ColorBlocks: ColorBlocks
    var Entropy: EntropyStatus
    
    init(BoardBasics: BoardBasics, OriginalCondition: OriginalCondition, ColorBlocks: ColorBlocks, Entropy: EntropyStatus) {
        self.id = UUID()
        self.BoardBasics = BoardBasics
        self.OriginalCondition = OriginalCondition
        self.ColorBlocks = ColorBlocks
        self.Entropy = Entropy
    }
    
    struct BoardBasics {
        let RowNum: Int32
        let ColNum: Int32
        
        init(RowNum: Int32, ColNum: Int32) {
            self.RowNum = RowNum
            self.ColNum = ColNum
        }
    }

    struct OriginalCondition {
        var Status: [[Int32]]
        
        init(Status: [[Int32]]) {
            self.Status = Status
        }
    }

    struct ColorBlocks {
        var BlockStatus: [[UUID]]
        var Capitals: [[Bool]] // True for each capitals
        var CellCosts: [[Int32]]
        var BlocksContained: [OneColorBlock]
        
        struct OneColorBlock {
            let id: UUID
            var CellCost: Int32
            
            init(CellCost: Int32) {
                self.id = UUID()
                self.CellCost = CellCost
            }
        }
        
        init(BlockStatus: [[UUID]], Capitals: [[Bool]], CellCosts: [[Int32]], BlocksContained: [OneColorBlock]) {
            self.BlockStatus = BlockStatus
            self.Capitals = Capitals
            self.CellCosts = CellCosts
            self.BlocksContained = BlocksContained
        }
    }
    
    struct EntropyStatus {
        var Status: [[Int32]]
        
        init(Status: [[Int32]]) {
            self.Status = Status
        }
    }
}
