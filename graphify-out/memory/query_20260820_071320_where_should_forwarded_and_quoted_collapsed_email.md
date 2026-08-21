---
type: "query"
date: "2026-08-20T07:13:20.070786+00:00"
question: "Where should forwarded and quoted collapsed email history be parsed, persisted, threaded, and rendered as individual graph nodes?"
contributor: "graphify"
outcome: "useful"
source_nodes: ["HeaderDecoder", "MailAppleScriptClient", "MessageStore", "JWZThreader", "ThreadNode", ".make()", "GraphCanvasViewModel", "ThreadCanvasViewModel"]
---

# Q: Where should forwarded and quoted collapsed email history be parsed, persisted, threaded, and rendered as individual graph nodes?

## Answer

Expanded from original query via graph vocab: [decode, header, parser, persist, store, jwz, thread, graph, render, message, source, quoted]. The graph maps the narrow flow to MailAppleScriptClient and HeaderDecoder for source parsing, MessageStore for structured persistence, JWZThreader and ThreadNode for deterministic child expansion, GraphData.make for rendering, and GraphCanvasViewModel plus ThreadCanvasViewModel for source-action routing.

## Outcome

- Signal: useful

## Source Nodes

- HeaderDecoder
- MailAppleScriptClient
- MessageStore
- JWZThreader
- ThreadNode
- .make()
- GraphCanvasViewModel
- ThreadCanvasViewModel