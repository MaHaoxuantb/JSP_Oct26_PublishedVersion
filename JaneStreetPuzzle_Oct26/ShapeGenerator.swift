//
//  ShapeGenerator.swift
//  MyTool
//
//  Created by Thomas B on 10/9/26.
//

import Foundation

struct ShapeGenerator {
    func GenerateShapes(Boards: [Board], RowNum: Int, ColNum: Int) -> [Board] {
        // Assign All Condition
        var TempBlockStatus: [[UUID]] = [[]]
        for Row in 0..<RowNum {
            for Col in 0..<ColNum {
                TempBlockStatus[Row][Col] = UUID()
            }
        }
        
        
        return Boards
    }
}
