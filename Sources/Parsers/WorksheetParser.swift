import Foundation

final class WorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private(set) var cellsByRow: [Int: [Int: String]] = [:]
    private(set) var maxRow = 0
    private(set) var maxColumn = 0

    private var currentReference = ""
    private var currentType = ""
    private var currentValue = ""
    private var captureValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parse(data: Data) -> WorksheetParser {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return self
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "c" {
            currentReference = attributeDict["r"] ?? ""
            currentType = attributeDict["t"] ?? ""
            currentValue = ""
        } else if elementName == "v" || elementName == "t" {
            captureValue = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureValue {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" {
            captureValue = false
        } else if elementName == "c" {
            guard let (row, column) = decodeCellReference(currentReference) else { return }
            var resolved = currentValue
            if currentType == "s", let index = Int(currentValue), sharedStrings.indices.contains(index) {
                resolved = sharedStrings[index]
            }
            if !resolved.isEmpty {
                var rowCells = cellsByRow[row] ?? [:]
                rowCells[column] = resolved
                cellsByRow[row] = rowCells
                maxRow = max(maxRow, row)
                maxColumn = max(maxColumn, column)
            }
        }
    }
}
