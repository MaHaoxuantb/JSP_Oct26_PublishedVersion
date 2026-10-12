import Foundation

//MARK: - Initialization
class Initialization {
    func start(rowNum: Int, colNum: Int) async -> Board {
        return Board(rowNum: rowNum, colNum: colNum)
    }
}

//MARK: - MAIN
class Main {
    func Run(Config: RunConfig) async {
        // Initialize it
        var Board = await Initialization().start(rowNum: Config.rowNum, colNum: Config.colNum)
        // External Iteration
    }
}

//MARK: - Iteration
class Iteration {
    func OneIteration(Board: Board) -> Board {
        var ThisBoard = Board
        let LastBoard = Board
        
        // Rand according to Energy Level
        /// Each row, verticle relationships
        for row in Board.Relationships.VerticalRelationships.indices {
            for col in Board.Relationships.VerticalRelationships[row].indices {
//                let overallRelationshipEnergy: Float64 = 0.5*(Board.Relationships.CellEnergy[row][col] + Board.Relationships.CellEnergy[row][col + 1])
            }
        }
        
        return Board
    }
}

//MARK: - EXEC
await Main().Run(Config: RunConfig())


//MARK: - Testing
