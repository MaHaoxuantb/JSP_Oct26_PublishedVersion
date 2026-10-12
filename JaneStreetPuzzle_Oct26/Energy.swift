//
//  Energy.swift
//  JaneStreetPuzzle_Oct26
//
//  Created by Thomas B on 10/12/26.
//

class Energy {
    // Calculate the Energy
    func EnergyCal(Board: Board) -> Board {
        return Board
    }
    
    // 1. Real AIM
    /// Use the cost to get to the closest MC
    func RealAIMTest(Board: Board) -> [[Float64]] {
        return [[]]
    }
    
    // 2. Symmetric
    func SymmetricalTest(Board: Board) -> [[Float64]] {
        
        return [[]]
    }
    
    // 3. Strength Closeness to 0 or 1
    func DiscreteTest(Board: Board) -> [[Float64]] {
        var VerticalEnergy = Array(
            repeating: Array(repeating: 0, count: Board.BoardBasics.colNum - 1),
            count: Board.BoardBasics.rowNum
        )
        var HorizontalEnergy = Array(
            repeating: Array(repeating: 0, count: Board.BoardBasics.colNum),
            count: Board.BoardBasics.rowNum - 1
        )
        
        // Through each row
        for row in 0...(Board.BoardBasics.colNum - 1) {
            for col in 0...(Board.BoardBasics.rowNum - 1) {
                
            }
        }
        // Through each column
        for col in 0...(Board.BoardBasics.rowNum - 1) {
            for row in 0...(Board.BoardBasics.colNum - 1) {
                
            }
        }
        return [[]]
    }
}
