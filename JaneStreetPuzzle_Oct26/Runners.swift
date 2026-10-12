//
//  Runners.swift
//  JaneStreetPuzzle_Oct26
//
//  Created by Thomas B on 10/12/26.
//

import Foundation

class Runners {
    // Relationships Into ColorBlocks
    func IntoColorBlocks(Board: Board) async -> Board {
        var ThisBoard = Board
        
        // Prepare it for this JOB
        for row in ThisBoard.Relationships.ColorBlocks.indices {
            for col in ThisBoard.Relationships.ColorBlocks[row].indices {
                ThisBoard.Relationships.ColorBlocks[row][col] = UUID()
            }
        }
        ThisBoard.Relationships.BlocksContained.ids = []
        ThisBoard.Relationships.BlocksContained.blockCounts = []
        
        // MAIN
        while true {
            let LastBoard = ThisBoard
            ThisBoard = await Propergation(Board: LastBoard)
            if ThisBoard.Relationships.ColorBlocks == LastBoard.Relationships.ColorBlocks {
                break
            }
        }
        
        // Update the UUID Index for color blocks
        for rowBlocks in ThisBoard.Relationships.ColorBlocks {
            for oneBlock in rowBlocks {
                if !ThisBoard.Relationships.BlocksContained.ids.contains(oneBlock) {
                    ThisBoard.Relationships.BlocksContained.ids.append(oneBlock)
                    ThisBoard.Relationships.BlocksContained.blockCounts.append(1)
                } else {
                    let thisIndex = ThisBoard.Relationships.BlocksContained.ids.firstIndex(of: oneBlock)!
                    ThisBoard.Relationships.BlocksContained.blockCounts[thisIndex] += 1
                }
            }
        }
        
        return ThisBoard
        
        // Top-Left Propergation
        func Propergation(Board: Board) async -> Board {
            // Through each row
            for row in Board.Relationships.VerticalRelationships.indices {
                for col in Board.Relationships.VerticalRelationships[row].indices {
                    if Board.Relationships.VerticalRelationships[row][col] >= 0.5 {
                        Board.Relationships.ColorBlocks[row][col + 1] = Board.Relationships.ColorBlocks[row][col]
                    }
                }
            }
            // Through each column
            for col in Board.Relationships.HorizontalRelationships.first?.indices ?? 0..<0 {
                for row in Board.Relationships.HorizontalRelationships.indices {
                    if Board.Relationships.HorizontalRelationships[row][col] >= 0.5 {
                        Board.Relationships.ColorBlocks[row + 1][col] = Board.Relationships.ColorBlocks[row][col]
                    }
                }
            }
            return Board
        }
    }
}
