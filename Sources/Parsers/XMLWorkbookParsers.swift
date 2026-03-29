import Foundation

final class SharedStringsParser: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentText = ""
    private var insideSI = false
    private var insideTextNode = false

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "si" {
            insideSI = true
            currentText = ""
        } else if elementName == "t", insideSI {
            insideTextNode = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideSI, insideTextNode {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            insideTextNode = false
        } else if elementName == "si" {
            strings.append(currentText)
            insideSI = false
            currentText = ""
        }
    }
}

final class WorkbookParser: NSObject, XMLParserDelegate {
    private(set) var sheets: [WorkbookSheet] = []

    func parse(data: Data) -> [WorkbookSheet] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "sheet" else { return }
        if let name = attributeDict["name"], let rid = attributeDict["r:id"] {
            sheets.append(
                WorkbookSheet(
                    name: name,
                    relationshipID: rid,
                    state: attributeDict["state"] ?? "visible"
                )
            )
        }
    }
}

final class RelationshipParser: NSObject, XMLParserDelegate {
    private(set) var mapping: [String: String] = [:]

    func parse(data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return mapping
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard elementName == "Relationship" else { return }
        guard let type = attributeDict["Type"], type.contains("/worksheet"),
              let id = attributeDict["Id"], let target = attributeDict["Target"] else { return }
        mapping[id] = target
    }
}
