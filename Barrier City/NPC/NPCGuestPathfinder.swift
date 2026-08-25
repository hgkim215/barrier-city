import Foundation
import simd

/// 방 바닥을 촘촘한 격자로 나눠 A*로 웨이포인트 경로를 찾는다.
///
/// move()의 이동 자체는 여전히 매 프레임 목표 지점을 향한 직선 스티어링 + raycast
/// 회피다. 문제는 그 "목표 지점"을 방 반대편 좌석이나 먼 배회 목적지로 통째로 잡으면,
/// 그 사이에 긴 바 테이블 같은 큰 장애물이 있을 때 직선이 계속 막혀 같은 자리에서
/// 튕겨 나오길 반복한다는 점이다(장애물을 "돌아간다"는 개념 자체가 없었다). 여기서는
/// 미리 격자 위에서 장애물을 우회하는 경로를 찾아 짧은 구간(웨이포인트) 목록으로
/// 쪼개 준다 — move()는 각 웨이포인트까지의 짧은 직선 구간만 맡으면 되므로 기존의
/// 안전장치(raycast 회피, 군중 반발 등)는 그대로 유효하다.
enum NPCGuestPathfinder {
    /// NPCGuestArea(바닥) 위에 얹은 격자. 셀 좌표는 area의 u/v(-1...1) 파라미터
    /// 공간을 cellSize 간격으로 균등 분할해 만든다 — computeWalkableCells가 스폰
    /// 후보를 훑던 것과 같은 좌표계라, 두 용도가 항상 같은 셀을 가리킨다.
    struct WalkableGrid {
        let area: NPCGuestArea
        let columns: Int
        let rows: Int
        let stepU: Float
        let stepV: Float
        /// row-major(= row * columns + column), true면 그 셀에 설 수 있다.
        let walkable: [Bool]

        private func index(row: Int, column: Int) -> Int? {
            guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
            return row * columns + column
        }

        func isWalkable(row: Int, column: Int) -> Bool {
            guard let index = index(row: row, column: column) else { return false }
            return walkable[index]
        }

        func worldPosition(row: Int, column: Int) -> SIMD2<Float> {
            area.point(u: -1 + Float(column) * stepU, v: -1 + Float(row) * stepV)
        }

        /// 월드 좌표에서 가장 가까운 격자 셀. area 자체가 퇴화(반축이 거의 0)했을
        /// 때만 nil — 그 밖에는 영역 경계를 벗어난 좌표도 가장 가까운 가장자리 셀로
        /// 클램프한다. 좌석은 테이블 바로 옆이라 u/v가 [-1,1]을 살짝 넘어가는 경우가
        /// 실제로 있는데, 여기서 곧장 nil을 반환해버리면 그 좌석으로의 경로 탐색
        /// 전체가 조용히 실패해(폴백으로 예전 직선 이동으로 되돌아가) 정확히 좌석
        /// 근처에서 막히는 문제를 다시 일으켰다.
        func cell(containing point: SIMD2<Float>) -> (row: Int, column: Int)? {
            guard let uv = area.localCoordinates(of: point) else { return nil }
            let column = Int(((uv.x + 1) / stepU).rounded())
            let row = Int(((uv.y + 1) / stepV).rounded())
            return (min(max(row, 0), rows - 1), min(max(column, 0), columns - 1))
        }

        /// `point`가 속한 셀이 막혀 있으면, 반경을 넓혀 가며 가장 가까운 유효 셀을
        /// 찾는다. 좌석처럼 목표 자체가 제외 구역 경계에 바싹 붙어 있어도 반드시
        /// 찾아낼 수 있도록, 격자 전체를 덮을 만큼 넉넉한 반경까지 찾아본다 — 이
        /// 함수는 새 목적지를 고를 때만 한 번 호출되니 비용 부담이 없다.
        func nearestWalkableCell(to point: SIMD2<Float>) -> (row: Int, column: Int)? {
            guard let start = cell(containing: point) else { return nil }
            if isWalkable(row: start.row, column: start.column) { return start }
            let maxRadius = max(rows, columns)
            for radius in 1...max(1, maxRadius) {
                for dRow in -radius...radius {
                    for dColumn in -radius...radius {
                        guard max(abs(dRow), abs(dColumn)) == radius else { continue }
                        let row = start.row + dRow
                        let column = start.column + dColumn
                        if isWalkable(row: row, column: column) { return (row, column) }
                    }
                }
            }
            return nil
        }
    }

    /// `isWalkable`은 호출부(NPCGuestCoordinator)가 raycast 기반 가구 검사까지 포함해
    /// 주입한다 — 이 파일 자체는 RealityKit에 의존하지 않는 순수 격자/탐색 로직이다.
    static func buildGrid(area: NPCGuestArea,
                          cellSize: Float,
                          isWalkable: (SIMD2<Float>) -> Bool) -> WalkableGrid {
        let axisULength = simd_length(area.axisU)
        let axisVLength = simd_length(area.axisV)
        let stepU = axisULength > 0.001 ? min(1, cellSize / axisULength) : 1
        let stepV = axisVLength > 0.001 ? min(1, cellSize / axisVLength) : 1
        let columns = Int((2 / stepU).rounded(.down)) + 1
        let rows = Int((2 / stepV).rounded(.down)) + 1
        var walkable = [Bool](repeating: false, count: columns * rows)
        for row in 0..<rows {
            let v = -1 + Float(row) * stepV
            for column in 0..<columns {
                let u = -1 + Float(column) * stepU
                walkable[row * columns + column] = isWalkable(area.point(u: u, v: v))
            }
        }
        return WalkableGrid(area: area, columns: columns, rows: rows,
                            stepU: stepU, stepV: stepV, walkable: walkable)
    }

    /// 8방향 A*로 start에서 goal까지의 웨이포인트(월드 좌표) 경로를 찾는다. 대각선
    /// 이동은 양쪽 직교 이웃도 걸을 수 있을 때만 허용해(코너 컷 방지) 좁은 틈으로
    /// 대각선으로 파고드는 경로를 막는다. 직선으로 이어지는 구간은 중간 웨이포인트를
    /// 쳐내 move()가 매 프레임 재조준하지 않고 곧장 걷게 한다. start/goal이 격자 밖이면
    /// 가장 가까운 유효 셀로 스냅한다. 경로를 못 찾으면 nil.
    static func findPath(from start: SIMD2<Float>, to goal: SIMD2<Float>,
                         in grid: WalkableGrid) -> [SIMD2<Float>]? {
        guard let startCell = grid.nearestWalkableCell(to: start),
              let goalCell = grid.nearestWalkableCell(to: goal) else { return nil }
        if startCell == goalCell { return [goal] }

        struct Node: Comparable {
            let row: Int
            let column: Int
            let priority: Float
            static func < (lhs: Node, rhs: Node) -> Bool { lhs.priority < rhs.priority }
        }
        func heuristic(_ row: Int, _ column: Int) -> Float {
            let dRow = Float(goalCell.row - row)
            let dColumn = Float(goalCell.column - column)
            return sqrt(dRow * dRow + dColumn * dColumn)
        }
        func key(_ row: Int, _ column: Int) -> Int { row * grid.columns + column }

        var openHeap = [Node(row: startCell.row, column: startCell.column,
                             priority: heuristic(startCell.row, startCell.column))]
        var cameFrom: [Int: (row: Int, column: Int)] = [:]
        var costSoFar: [Int: Float] = [key(startCell.row, startCell.column): 0]
        var visited = Set<Int>()

        let neighborOffsets: [(dRow: Int, dColumn: Int, cost: Float)] = [
            (-1, 0, 1), (1, 0, 1), (0, -1, 1), (0, 1, 1),
            (-1, -1, 1.41421), (-1, 1, 1.41421), (1, -1, 1.41421), (1, 1, 1.41421),
        ]

        // 노드 수가 격자 전체(수백~수천)라 힙 없이도 실용적인 속도가 나온다 —
        // 매 프레임이 아니라 새 목적지를 고를 때만 한 번 호출되기 때문이다.
        while !openHeap.isEmpty {
            openHeap.sort()
            let current = openHeap.removeFirst()
            let currentKey = key(current.row, current.column)
            if visited.contains(currentKey) { continue }
            visited.insert(currentKey)
            if current.row == goalCell.row, current.column == goalCell.column { break }

            for offset in neighborOffsets {
                let row = current.row + offset.dRow
                let column = current.column + offset.dColumn
                guard grid.isWalkable(row: row, column: column) else { continue }
                if offset.dRow != 0, offset.dColumn != 0 {
                    // 대각선은 양쪽 직교 이웃도 뚫려 있을 때만 허용(코너 컷 방지).
                    guard grid.isWalkable(row: current.row + offset.dRow, column: current.column),
                          grid.isWalkable(row: current.row, column: current.column + offset.dColumn)
                    else { continue }
                }
                let newCost = (costSoFar[currentKey] ?? 0) + offset.cost
                let neighborKey = key(row, column)
                if newCost < (costSoFar[neighborKey] ?? .greatestFiniteMagnitude) {
                    costSoFar[neighborKey] = newCost
                    cameFrom[neighborKey] = (current.row, current.column)
                    openHeap.append(Node(row: row, column: column,
                                         priority: newCost + heuristic(row, column)))
                }
            }
        }

        guard visited.contains(key(goalCell.row, goalCell.column)) else { return nil }

        var cellPath: [(row: Int, column: Int)] = [goalCell]
        var cursor = goalCell
        while let previous = cameFrom[key(cursor.row, cursor.column)] {
            cellPath.append(previous)
            cursor = previous
        }
        cellPath.reverse()

        var worldPath = cellPath.map { grid.worldPosition(row: $0.row, column: $0.column) }
        worldPath[worldPath.count - 1] = goal

        return simplify(worldPath)
    }

    /// 방향이 바뀌지 않는 연속 구간의 중간 점들을 쳐낸다(직선 구간을 하나의 긴
    /// 웨이포인트로 합침). move()가 매 셀마다 재조준하지 않고 곧장 걷게 해 준다.
    private static func simplify(_ path: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard path.count > 2 else { return path }
        var result: [SIMD2<Float>] = [path[0]]
        var previousDirection: SIMD2<Float>?
        for index in 1..<path.count {
            let segment = path[index] - path[index - 1]
            guard simd_length(segment) > 0.0001 else { continue }
            let direction = simd_normalize(segment)
            if let previousDirection, simd_length(direction - previousDirection) < 0.01,
               index != path.count - 1 {
                continue
            }
            result.append(path[index])
            previousDirection = direction
        }
        if result.last != path.last { result.append(path[path.count - 1]) }
        return result
    }
}
