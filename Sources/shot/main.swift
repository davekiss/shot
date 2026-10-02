import Foundation

// `shot` with no arguments speaks MCP over stdio.
// `shot <tool> '<json args>'` runs one tool and prints its JSON result (handy for testing).

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let tool = cliArgs.first {
    if tool == "--help" || tool == "-h" {
        print("usage: shot [capture|compose|ocr|list_windows|find_shots|annotate|describe] '<json args>'\n(no arguments: run as an MCP server over stdio)")
        exit(0)
    }
    do {
        let raw = cliArgs.count > 1 ? cliArgs[1] : "{}"
        guard let a = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? Args else { throw ShotError("arguments must be a JSON object") }
        let result = try Tools.call(tool, a)
        var info = result.info
        if let img = result.image, let (_, scale) = preview(img) { info["preview_scale"] = NSDecimalNumber(string: String(format: "%.3f", scale)) }
        print(json(info))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

func send(_ obj: Args) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(_ id: Any, _ result: Args) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

Describer.start()

while let line = readLine() {
    guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? Args,
          let id = msg["id"] else { continue } // skip notifications and junk
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? Args ?? [:]
    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:] as Args],
            "serverInfo": ["name": "shot", "version": "0.1.0"],
            "instructions": Tools.instructions,
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": Tools.definitions])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        do {
            reply(id, try Tools.call(name, params["arguments"] as? Args ?? [:]).mcp())
        } catch {
            reply(id, ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}
