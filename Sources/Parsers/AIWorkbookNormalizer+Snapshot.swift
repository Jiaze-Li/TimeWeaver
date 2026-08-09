import Foundation

struct WorkbookSnapshot: Encodable {
    var sourceName: String
    var sourceLink: String
    var bookingID: String
    var calendar: String
    var timezone: String
    var defaultWorkday: WorkbookSnapshotWorkday
    var sheets: [WorkbookSnapshotSheet]
}

struct WorkbookSnapshotWorkday: Encodable {
    var start: String
    var end: String
}

struct WorkbookSnapshotSheet: Encodable {
    var name: String
    var rows: [WorkbookSnapshotRow]
}

struct WorkbookSnapshotRow: Encodable {
    var rowNumber: Int
    var cells: [WorkbookSnapshotCell]
}

struct WorkbookSnapshotCell: Encodable {
    var column: String
    var value: String
}

extension AIWorkbookNormalizer {
    static func snapshotSheet(_ sheet: ParsedWorkbookSheet) -> WorkbookSnapshotSheet {
        let rows = (1...sheet.worksheet.maxRow).compactMap { row -> WorkbookSnapshotRow? in
            guard let rowCells = sheet.worksheet.cellsByRow[row], !rowCells.isEmpty else { return nil }
            let cells = rowCells.keys.sorted().compactMap { column -> WorkbookSnapshotCell? in
                guard let rawValue = rowCells[column] else { return nil }
                let value = rawValue
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    return nil
                }
                return WorkbookSnapshotCell(column: columnLetters(column), value: value)
            }
            guard !cells.isEmpty else { return nil }
            return WorkbookSnapshotRow(rowNumber: row, cells: cells)
        }
        return WorkbookSnapshotSheet(name: sheet.name, rows: rows)
    }
}
