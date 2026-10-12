//
//  ShapeGenerator.swift
//  MyTool
//
//  Created by Thomas B on 10/9/26.
//

import Foundation

struct ShapeGenerator {
    func GenerateShapes(Boards: [Board], rowNum: Int, colNum: Int) -> [Board] {
        // Assign All Condition
        var TempBlockStatus: [[UUID]] = [[]]
        for Row in 0..<rowNum {
            for Col in 0..<colNum {
                TempBlockStatus[Row][Col] = UUID()
            }
        }
        
        
        return Boards
    }
}
