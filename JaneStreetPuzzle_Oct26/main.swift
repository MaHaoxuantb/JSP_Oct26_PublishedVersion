import Foundation

//MARK: - Initialization
class Initialization {
    func start(rowNum: Int, colNum: Int) async -> Board {
        return Board(rowNum: rowNum, colNum: colNum)
    }
}

//MARK: - MAIN
class Main {
    func Run() async {
        // Initialize it
        let Config = RunConfig()
        var Board = await Initialization().start(rowNum: Config.rowNum, colNum: Config.colNum)
        // Iterate for Num of Capitols
        for N in 0...100 {
            
        }
    }
}

//MARK: - Iteration
class Iteration {
    func OneIteration(Board: Board) -> Board {
        return Board
    }
    
    // Relationships Into ColorBlocks
    func IntoColorBlocks(Board: Board) async -> Board {
        var ThisBoard = Board
        while true {
            let LastBoard = ThisBoard
            ThisBoard = await Propergation(Board: LastBoard)
            if ThisBoard.Relationships.BlockStatus == LastBoard.Relationships.BlockStatus {
                return ThisBoard
            }
        }
        
        // Top-Left Proporgation
        func Propergation(Board: Board) async -> Board {
            // Through each row
            for row in Board.Relationships.Relationships.indices {
                for col in Board.Relationships.Relationships[row].indices {
                    if Board.Relationships.Relationships[row][col] >= 0.5 {
                        Board.Relationships.BlockStatus[row][col + 1] = Board.Relationships.BlockStatus[row][col]
                    }
                }
            }
            // Through each column
            for col in Board.Relationships.Relationships.first?.indices ?? 0..<0 {
                for row in Board.Relationships.Relationships.indices {
                    if Board.Relationships.Relationships[row][col] >= 0.5 {
                        Board.Relationships.BlockStatus[row + 1][col] = Board.Relationships.BlockStatus[row][col]
                    }
                }
            }
            return Board
        }
    }
}

//MARK: - Energy
class Energy {
    // Calculate the Energy
    func EnergyCal(Board: Board) -> Board {
        return Board
    }
    
    // Real AIM
    
    // Symmetric
    
    // Strength Closeness to 0 or 1
}

//MARK: - EXEC
//await Main().Run()


//MARK: - Testing
