#!/usr/bin/env python3
"""Run the native AI self-check against a local synthetic SSE provider."""
import json
import base64
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

failures = []
titles = set()
title_counts = {}


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/nav/auth-icon.png":
            if "fixture_icon=allowed" not in self.headers.get("Cookie", ""):
                self.send_error(401)
                return
            data = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2ioAAAAASUVORK5CYII=")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path == "/favicon.ico":
            self.send_error(404)
            return
        if self.path.startswith("/nav/"):
            if self.path == "/nav/slow-headers":
                time.sleep(1.2)
            if self.path == "/nav/resource":
                time.sleep(1.5)
            if self.path == "/nav/failure":
                self.connection.close()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Cache-Control", "no-store")
            if self.path == "/nav/auth-icon":
                self.send_header("Set-Cookie", "fixture_icon=allowed; HttpOnly; Path=/; SameSite=Lax")
            self.end_headers()
            page = self.path.rsplit("/", 1)[-1]
            html = "<title>" + page + "</title><p>" + page + "</p>"
            if page == "auth-icon":
                html += '<link rel="icon" href="/nav/auth-icon.png">'
            if page == "slow-body":
                html += '<img src="/nav/resource">'
            try:
                self.wfile.write(html.encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.headers.get("Authorization") != "Bearer synthetic-key" and self.headers.get("x-api-key") != "synthetic-key":
            failures.append("Model catalog omitted authentication")
            self.send_error(401)
            return
        if self.path != "/v1/models":
            failures.append("Model catalog used an unexpected endpoint")
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"object": "list", "data": [
            {"id": "fixture"}, {"id": "alternate"}, {"id": "fixture"}
        ]}).encode())

    def do_POST(self):
        try:
            length = int(self.headers["Content-Length"])
            body = self.rfile.read(length)
            if len(body) != length:
                return  # A cancellation can close the connection before uploading the body.
            payload = json.loads(body)
            if self.path.endswith("/tools/search"):
                assert self.headers["Authorization"] == "Bearer synthetic-search-key"
                assert set(payload) == {"query", "count", "need_content"}
                assert payload["query"] == "fixture search" and payload["count"] == 3 and payload["need_content"] is True
                if self.path.startswith("/search-slow"):
                    time.sleep(0.8)
                if self.path.startswith("/search-error"):
                    self.send_error(503)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"results": [{"title": "Search source", "url": "https://search.fixture.invalid/source",
                    "snippet": "Fixture result", "content": "Fixture search evidence"},
                    {"title": "Unsafe", "url": "javascript:alert(1)"}]}).encode())
                return
            anthropic = self.path in ["/v1/messages", "/streaming/messages"]
            responses = self.path in ["/v1/responses", "/streaming/responses"]
            if anthropic:
                assert self.headers["x-api-key"] == "synthetic-key"
                assert self.headers["anthropic-version"] == "2023-06-01"
                assert payload["max_tokens"] == (80 if payload["stream"] is False else 4096) and payload["system"]
            else:
                assert self.headers["Authorization"] == "Bearer synthetic-key"
            assert b"synthetic-key" not in body
            assert payload["model"] == "fixture"
            if responses:
                assert payload["instructions"] and payload["store"] is False
                payload["messages"] = payload["input"]
            elif not anthropic:
                assert payload["messages"][0]["role"] == "system"
            system_text = payload.get("instructions", payload.get("system", ""))
            if not system_text:
                system_text = "\n".join(m["content"] for m in payload["messages"] if m.get("role") == "system")
            available = []
            if "<available_pages>" in system_text:
                available = json.loads(system_text.split("<available_pages>\n", 1)[1].split("\n</available_pages>", 1)[0])
            last = payload["messages"][-1]
            content = last.get("content", last.get("output", ""))
            tool_result = (
                last.get("type") == "function_call_output" or last.get("role") == "tool" or
                isinstance(content, list) and any(p.get("type") == "tool_result" for p in content)
            )
            if payload.get("stream") and "--legacy-tools" not in sys.argv:
                file_tools = [tool for tool in payload.get("tools", []) if tool.get("function", tool).get("name") == "create_text_file"]
                assert len(file_tools) == 1
                assert "create_text_file" in system_text
                file_schema = file_tools[0].get("function", file_tools[0])
                assert file_schema.get("parameters", file_schema.get("input_schema"))["required"] == ["name", "content"]
                # The existing search/page assertions below concern their own tools.
                payload["tools"] = [tool for tool in payload["tools"] if tool not in file_tools]
                if not payload["tools"]:
                    del payload["tools"]
                interaction_tools = [tool for tool in payload.get("tools", []) if tool.get("function", tool).get("name") in ["ask_clarification", "suggest_followups"]]
                assert len(interaction_tools) == 2
                payload["tools"] = [tool for tool in payload.get("tools", []) if tool not in interaction_tools]
                if not payload["tools"]:
                    del payload["tools"]
            if payload.get("stream") and (
                isinstance(content, str) and content == "Reasoning fixture"
            ):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for chunk in ["Inspect ", "fixture."]:
                    if responses:
                        self.sse({"type": "response.reasoning_summary_text.delta", "output_index": 0, "summary_index": 0, "delta": chunk})
                    elif anthropic:
                        if chunk == "Inspect ":
                            self.sse({"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}})
                        self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": chunk}})
                    else:
                        self.sse({"choices": [{"delta": {"reasoning_content": chunk}}]})
                    time.sleep(0.15)
                if responses:
                    item = {"type": "reasoning", "id": "rs-fixture", "summary": [{"type": "summary_text", "text": "Inspect fixture."}]}
                    self.sse({"type": "response.reasoning_summary_text.done", "output_index": 0, "summary_index": 0, "text": "Inspect fixture."})
                    self.sse({"type": "response.output_item.done", "output_index": 0, "item": item})
                    self.sse({"type": "response.output_text.delta", "delta": "Reasoning verified"})
                    self.sse({"type": "response.completed", "response": {"output": [item]}})
                elif anthropic:
                    self.sse({"type": "content_block_stop", "index": 0})
                    self.sse({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Reasoning verified"}})
                    self.sse({"type": "message_stop"})
                else:
                    self.event("Reasoning verified")
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                return
            if payload.get("stream") and (
                isinstance(content, str) and content.startswith(("File ", "Interaction ", "补充信息：")) or tool_result and "file-call" in json.dumps(last)
            ):
                self.file_reply(payload, content, tool_result, responses, anthropic)
                return
            if payload.get("stream") and (isinstance(content, str) and content.startswith("Search ") or
                tool_result and "search-call" in json.dumps(last)):
                assert "当前本地日期：" + time.strftime("%Y-%m-%d") in system_text
                assert "当前时区：" in system_text
                if payload.get("tools"):
                    assert "不添加用户未给出的限制或假设" in system_text and "优先可靠的一手来源" in system_text
                if isinstance(content, str) and "standard chat" in content:
                    if "off" in content:
                        assert self.path == "/v1/chat/completions" and "tools" not in payload
                    else:
                        assert responses and payload["tools"] == [{"type": "web_search"}]
                        assert payload["include"] == ["web_search_call.action.sources"]
                if tool_result:
                    result = json.loads(content[0]["content"] if anthropic else content)
                    assert "results" in result or "error" in result
                    if "results" in result:
                        assert len(result["results"]) == 1 and result["results"][0]["url"] == "https://search.fixture.invalid/source"
                    self.search_reply(responses, anthropic)
                    return
                if "followup" in content:
                    assert "https://search.fixture.invalid/source" in json.dumps(payload["messages"][:-1])
                    if "external" in content:
                        assert "search-call" in json.dumps(payload["messages"][:-1])
                    elif responses:
                        assert any(m.get("type") == "web_search_call" for m in payload["messages"])
                    elif anthropic:
                        assert "web_search_tool_result" in json.dumps(payload["messages"])
                        assert any(block.get("type") == "server_tool_use" and block["input"] == {"query": "fixture"}
                                   for message in payload["messages"] for block in message.get("content", [])
                                   if isinstance(block, dict))
                    self.search_reply(responses, anthropic)
                    return
                if "off" in content:
                    assert "tools" not in payload
                    self.search_reply(responses, anthropic)
                    return
                if "idle" in content:
                    assert payload["tools"]
                    self.search_reply(responses, anthropic)
                    return
                tools = payload["tools"]
                assert len(tools) == 1
                if "external" in content:
                    function = tools[0].get("function", tools[0])
                    assert function["name"] == "web_search" and "deepseek_web_search" not in json.dumps(tools)
                    if not anthropic:
                        assert function["strict"] is False
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    args = '{"query":"fixture search","num":3}' if " num " in content else '{"query":"fixture search","count":3}'
                    if responses:
                        item = {"type": "function_call", "id": "search-fc", "call_id": "search-call", "name": "web_search", "arguments": args}
                        self.sse({"type": "response.completed", "response": {"output": [item]}})
                    elif anthropic:
                        self.sse({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "search-call", "name": "web_search", "input": {}}})
                        self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": args}})
                        self.sse({"type": "message_stop"})
                    else:
                        self.sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "search-call", "function": {"name": "web_search", "arguments": args}}]}}]})
                        self.wfile.write(b"data: [DONE]\n\n")
                        self.wfile.flush()
                    return
                assert tools[0]["type"] == ("web_search" if "standard" in content else "deepseek_web_search")
                if "standard" in content:
                    assert payload["include"] == ["web_search_call.action.sources"]
                self.search_reply(responses, anthropic, native=True,
                                  source_mode="overflow" if "overflow" in content else "sparse" if "sparse" in content else "multiple" if "multiple" in content else "verbose" if content == "Search native fixture" else None)
                return
            if tool_result:
                if anthropic:
                    assert content[0]["tool_use_id"] == "page-call-1"
                    result = json.loads(content[0]["content"])
                    assert payload["messages"][-2]["content"][-1]["type"] == "tool_use"
                else:
                    assert last.get("call_id", last.get("tool_call_id")) == "page-call-1"
                    result = json.loads(content)
                    if responses:
                        assert payload["messages"][-2]["type"] == "function_call"
                    else:
                        assert payload["messages"][-2]["tool_calls"][0]["function"]["name"] == "get_page_html"
                initial = next(m for m in payload["messages"] if m.get("role") == "user")
                initial_text = initial["content"]
                if "HTML bad tool fixture" in initial_text:
                    assert "error" in result and "html" not in result and result["available_reference_ids"] == [1]
                else:
                    assert "<h1>Readable fixture</h1>" in result["html"]
                    assert "Other paragraph" in result["html"]
                    assert "https://fixture.invalid/dynamic?from=rendered" in result["urls"]
                    assert "_SECRET" not in json.dumps(result)
                    assert result["next_offset"] is None and result["htmlTruncated"] is False
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                if responses:
                    self.sse({"type": "response.output_text.delta", "delta": "HTML tool verified"})
                    self.sse({"type": "response.completed"})
                elif anthropic:
                    self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "HTML tool verified"}})
                    self.sse({"type": "message_stop"})
                else:
                    self.event("HTML tool verified")
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                return
            if payload["stream"] is False:
                assert isinstance(content, str) and len(content) <= 1502
                assert "<page_reference>" not in content and "_SECRET" not in content and "FILE-4729" not in content
                titles.add(content.split("\n")[-1])
                title_counts[content] = title_counts.get(content, 0) + 1
                if "title failure fixture" in content:
                    self.send_error(503)
                    return
                if "title cancellation fixture" in content:
                    time.sleep(0.3)
                text = "合成标题：对话重点总结与历史记录管理功能验证超过二十字"
                reply = {"content": [{"type": "text", "text": text}]} if anthropic else (
                    {"output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}]} if responses else
                    {"choices": [{"message": {"content": text}}]})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(reply, ensure_ascii=False).encode())
                return
            assert payload["stream"] is True
            first_line = content.split("\n")[0] if isinstance(content, str) else next(part.get("text", "").split("\n")[0] for part in content if part.get("text"))
            if first_line in ["hello fixture", "title failure fixture", "Read attachment fixture", "other tab", "summarize fixture", "multiple pages fixture"]:
                assert first_line in titles, "First main request started before title request"
            if isinstance(content, list):
                assert any("FILE-4729" in part.get("text", "") for part in content)
                content = "\n".join(part.get("text", "") for part in content)
            if "HTML tool fixture" in content or "HTML bad tool fixture" in content:
                assert available and available[0]["reference_id"] == 1
                assert "<h1>" not in content and "https://fixture.invalid/dynamic?from=rendered" not in content
                tool = payload["tools"][0]
                function = tool.get("function", tool)
                assert function["name"] == "get_page_html"
                schema = function.get("parameters", function.get("input_schema"))
                assert schema["required"] == ["reference_id"] and schema["additionalProperties"] is False
                args = '{"reference_id":999}' if "HTML bad tool fixture" in content else '{"reference_id":"1","offset":"0"}'
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                if responses:
                    item = {"type": "function_call", "id": "fc-1", "call_id": "page-call-1", "name": "get_page_html", "arguments": ""}
                    self.sse({"type": "response.output_item.added", "output_index": 0, "item": item})
                    for chunk in [args[:8], args[8:]]:
                        self.sse({"type": "response.function_call_arguments.delta", "output_index": 0, "delta": chunk})
                    item["arguments"] = args
                    self.sse({"type": "response.output_item.done", "output_index": 0, "item": item})
                    self.sse({"type": "response.completed", "response": {"output": [item]}})
                elif anthropic:
                    self.sse({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "page-call-1", "name": "get_page_html", "input": {}}})
                    for chunk in [args[:8], args[8:]]:
                        self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": chunk}})
                    self.sse({"type": "content_block_stop", "index": 0})
                    self.sse({"type": "message_stop"})
                else:
                    self.sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "page-call-1", "type": "function", "function": {"name": "get_page_html", "arguments": args[:8]}}]}}]})
                    self.sse({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "page-call-1", "type": "function",
                        "function": {"name": "get_page_html", "arguments": args[8:]}}]}}]})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                return
            if "Remember attachment fixture" in content:
                assert any(isinstance(m["content"], list) and any("FILE-4729" in part.get("text", "") for part in m["content"]) for m in payload["messages"][:-1])
            if "HTML followup fixture" in content:
                assert "<page_reference>" not in content and "<page_tool_result>" not in content
                if available:
                    assert payload["tools"]
                else:
                    assert "tools" not in payload
                assert any(
                    "https://fixture.invalid/dynamic?from=rendered" in json.dumps(m) and
                    (m.get("role") == "tool" or m.get("type") == "function_call_output" or
                     any(p.get("type") == "tool_result" for p in (m.get("content") or []) if isinstance(p, dict)))
                    for m in payload["messages"][:-1]
                )
            if first_line.startswith("queued fixture"):
                assert payload["messages"][-2]["role"] == "assistant"
                assert payload["messages"][-2]["content"] == "开始结束", "Queued message started before previous response completed"
            if first_line.startswith("history retention fixture"):
                assert any(m.get("role") == "user" and m.get("content") == "hello fixture" for m in payload["messages"])
            if "summarize fixture" in content:
                assert "<page_reference>" in content and "Selected excerpt only" in content
                assert "Other paragraph" not in content and "_SECRET" not in content
                assert "https://fixture.invalid/dynamic?from=rendered" not in content and "<h1>" not in content
            if "multiple pages fixture" in content:
                assert content.count("<page_reference>") == 2
                assert "SECOND-PAGE-7391" in content and "Selected excerpt only" in content
                assert "_SECRET" not in content
            if self.path.startswith("/unauthorized"):
                self.send_response(401)
                self.end_headers()
                self.wfile.write(b'{"error":"synthetic-key"}')
                return
            if self.path.startswith("/rate"):
                self.send_response(429)
                self.end_headers()
                return
            if self.path.startswith("/redirect"):
                self.send_response(307)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/leaked")
                self.end_headers()
                return
            if self.path.startswith("/leaked"):
                failures.append("Bearer request followed redirect")
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if self.path.startswith("/json") else "text/event-stream")
            self.end_headers()
            if self.path.startswith("/streaming"):
                if content == "History streaming fixture":
                    self.event(("# 历史回答\n\n" + "历史正文与阅读位置。\n\n" * 150))
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    return
                if content == "Burst streaming fixture":
                    self.sse({"choices": [{"delta": {"reasoning_content": "长思考。\n" * 600}}]})
                    time.sleep(0.6)
                    # A buffered network read must not starve the UI while consuming many events.
                    data = "".join("data: " + json.dumps({"choices": [{"delta": {"content": "正文增量片段。\n"}}]},
                                                        ensure_ascii=False) + "\n\n" for _ in range(700))
                    self.wfile.write(data.encode())
                    self.wfile.flush()
                    time.sleep(0.6)
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    return
                thinking = content == "Thinking streaming fixture"
                if thinking:
                    for text in ["思考中的逐段内容。\n" * 150, "继续检查正文显示。\n" * 150]:
                        if responses:
                            self.sse({"type": "response.reasoning_summary_text.delta", "output_index": 0, "delta": text})
                        elif anthropic:
                            self.sse({"type": "content_block_delta", "index": 1, "delta": {"type": "thinking_delta", "thinking": text}})
                        else:
                            self.sse({"choices": [{"delta": {"reasoning_content": text}}]})
                        time.sleep(0.6)
                for text in ["第一段", "\n\n第二段", "\n\n第三段"]:
                    if responses:
                        self.sse({"type": "response.output_text.delta", "delta": text})
                    elif anthropic:
                        self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
                    else:
                        self.event(text)
                    time.sleep(0.4)
                if responses:
                    self.sse({"type": "response.completed", "response": {"status": "completed"}})
                elif anthropic:
                    self.sse({"type": "message_stop"})
                else:
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                return
            if responses:
                for text in ["你好", "，Perch!"]:
                    event = {"type": "response.output_text.delta", "delta": text}
                    self.wfile.write(("event: response.output_text.delta\ndata: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
                self.wfile.write(b'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n')
                self.wfile.flush()
                return
            if anthropic:
                for text in ["你好", "，Perch!"]:
                    event = {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}
                    self.wfile.write(("event: content_block_delta\ndata: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
                self.wfile.write(b'event: message_stop\ndata: {"type":"message_stop"}\n\n')
                self.wfile.flush()
                return
            self.wfile.write(b": keepalive\r\n\r\n")
            if self.path.startswith("/json"):
                self.wfile.write(b"{}")
                return
            if self.path.startswith("/invalid"):
                self.wfile.write(b"data: not-json\r\n\r\n")
                return
            if self.path.startswith("/slow"):
                for text in ["开始", "结束"]:
                    self.event(text)
                    time.sleep(0.5 if first_line == "native queue start fixture" else 0.15)
            else:
                # Force chunk boundaries inside multi-byte characters and CRLF.
                for text in ["你好", "，Perch!"]:
                    self.event(text, fragment=True)
            if not self.path.startswith("/broken"):
                self.wfile.write(b"data: [DONE]\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the user stops generation.
        except Exception as error:
            failures.append(f"{self.path}: {type(error).__name__}: {error}")
            self.send_error(500)

    def file_reply(self, payload, content, tool_result, responses, anthropic):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(event):
            self.wfile.write(("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()

        def finish(text=""):
            if responses:
                if text:
                    emit({"type": "response.output_text.delta", "delta": text})
                emit({"type": "response.completed"})
            elif anthropic:
                if text:
                    emit({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
                emit({"type": "message_stop"})
            else:
                if text:
                    emit({"choices": [{"delta": {"content": text}}]})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()

        if tool_result:
            results = [json.loads(part["content"]) for part in content] if anthropic else [json.loads(content)]
            assert all(result.get("status") in ["ready", "awaiting_user"] or "error" in result for result in results)
            if "File phase fixture" in json.dumps(payload["messages"]):
                assert all("结束回答" in result.get("message", "") for result in results)
                time.sleep(0.3)
                for chunk in ["Second ", "round."]:
                    if responses:
                        emit({"type": "response.reasoning_summary_text.delta", "output_index": 0, "delta": chunk})
                    elif anthropic:
                        emit({"type": "content_block_delta", "index": 1, "delta": {"type": "thinking_delta", "thinking": chunk}})
                    else:
                        emit({"choices": [{"delta": {"reasoning_content": chunk}}]})
                    time.sleep(0.15)
                finish("After tool")
                return
            # A file-only answer must be accepted without a dummy prose response.
            finish("Interaction complete" if '"name": "suggest_followups"' in json.dumps(payload["messages"]) else "")
            return
        if content.startswith("补充信息："):
            assert "ask_clarification" in json.dumps(payload["messages"][:-1])
            finish("Clarification resumed")
            return
        if "followup" in content:
            history = json.dumps(payload["messages"][:-1], ensure_ascii=False)
            assert "create_text_file" in history and "文件交付" in history and "helper.user.js" in history
            finish("File history verified")
            return
        source = "// 文件交付 `模板` \"quotes\" \\\n" + "console.log('fixture');\n" * 1000
        files = [("helper.user.js", source), ("README.md", "# 文件说明\n```js\n示例\n```\n"),
                 ("helper.user.js", source + "// updated\n")]
        if "revision" in content:
            files = [("helper.user.js", "// revision\n")]
        elif any(mode in content for mode in ["invalid", "interrupted", "truncated", "missing-id"]):
            files = [("../bad.py" if "invalid" in content else "helper.user.js", source)]
        output = []
        if content == "File phase fixture":
            files = [("phase.txt", "phase")]
            if responses:
                emit({"type": "response.output_text.delta", "delta": "Before tool"})
            elif anthropic:
                emit({"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "Before tool"}})
            else:
                emit({"choices": [{"delta": {"content": "Before tool"}}]})
        calls = [("create_text_file", {"name": name, "content": text}) for name, text in files]
        if content.startswith("Interaction "):
            calls = [("suggest_followups", {"suggestions": ["补充一个示例", "解释实现方式"]})] if "suggest" in content else [
                ("ask_clarification", {"questions": [{"label": "输出语言", "options": ["Python", "Swift"]},
                                                    {"label": "运行环境", "options": []}]})]
        for index, (tool_name, arguments) in enumerate(calls):
            args = json.dumps(arguments, ensure_ascii=False)
            call_id = "" if "missing-id" in content else "file-call-" + str(index)
            item = {"type": "function_call", "id": "file-fc-" + str(index), "call_id": call_id,
                    "name": tool_name, "arguments": args}
            output.append(item)
            if responses:
                emit({"type": "response.output_item.added", "output_index": index, "item": dict(item, arguments="")})
            elif anthropic:
                emit({"type": "content_block_start", "index": index, "content_block": {
                    "type": "tool_use", "id": call_id, "name": tool_name, "input": {}}})
            for offset in range(0, len(args), 2000):
                chunk = args[offset:offset + 2000]
                if responses:
                    emit({"type": "response.function_call_arguments.delta", "output_index": index, "delta": chunk})
                elif anthropic:
                    emit({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": chunk}})
                else:
                    emit({"choices": [{"delta": {"tool_calls": [{"index": index, "id": call_id,
                        "function": {"name": tool_name, "arguments": chunk}}]}}]})
                if content == "File phase fixture":
                    time.sleep(0.3)
                if "interrupted" in content:
                    return
        if "truncated" in content:
            if responses:
                emit({"type": "response.incomplete"})
            elif anthropic:
                emit({"type": "message_delta", "delta": {"stop_reason": "max_tokens"}})
            else:
                emit({"choices": [{"delta": {}, "finish_reason": "length"}]})
            return
        if responses:
            emit({"type": "response.completed", "response": {"output": output}})
        else:
            finish()

    def event(self, text, fragment=False):
        # Multiline SSE data must be combined before JSON decoding.
        event = ('data: {"choices": [\r\ndata: {"delta": {"content": ' +
                 json.dumps(text, ensure_ascii=False) + '}}]}\r\n\r\n').encode()
        if fragment:
            for i in range(0, len(event), 3):
                self.wfile.write(event[i:i + 3])
                self.wfile.flush()
        else:
            self.wfile.write(event)
            self.wfile.flush()

    def search_reply(self, responses, anthropic, native=False, source_mode=None):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        source = {"title": "Search source", "url": "https://search.fixture.invalid/source"}
        usage = {"input_tokens": 10, "output_tokens": 5, "server_tool_use": {"tool_search": 1}}
        if responses:
            items = []
            if native and source_mode == "verbose":
                # More than 1 MiB of reasoning must not consume the search evidence budget.
                for _ in range(80):
                    event = {"type": "response.reasoning_summary_text.delta", "output_index": 0, "delta": "r" * 16384}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                self.wfile.flush()
            if native and source_mode == "overflow":
                for _ in range(80):
                    item = {"type": "web_search_call", "id": "ws-overflow", "status": "completed",
                            "action": {"type": "search", "sources": [dict(source, content="s" * 16384)]}}
                    self.wfile.write(("data: " + json.dumps({"type": "response.output_item.done", "output_index": 0, "item": item}) + "\n\n").encode())
                self.wfile.flush()
            if native:
                second = {"title": "Second source", "url": "https://search.fixture.invalid/second"}
                groups = [[], [source], []] if source_mode == "sparse" else [[source], [second, source], []] if source_mode == "multiple" else [[source]]
                for index, sources in enumerate(groups):
                    item = {"type": "web_search_call", "id": "ws-fixture-" + str(index), "status": "completed", "action": {"type": "search", "sources": sources}}
                    items.append(item)
                    self.sse({"type": "response.output_item.done", "output_index": index, "item": item})
                if source_mode == "verbose":
                    items.append({"type": "reasoning", "id": "rs-fixture",
                                  "summary": [{"type": "summary_text", "text": "r" * 65536}]})
            self.sse({"type": "response.output_text.delta", "delta": "Search verified"})
            annotations = [dict(source, type="url_citation")] if native else []
            if source_mode == "multiple":
                annotations.append({"type": "url_citation", "title": "Citation only", "url": "https://search.fixture.invalid/citation"})
            items.append({"type": "message", "id": "msg-fixture", "role": "assistant", "content": [{"type": "output_text", "text": "Search verified", "annotations": annotations}]})
            self.sse({"type": "response.completed", "response": dict(output=items, usage=usage if native else {})})
        elif anthropic:
            index = 0
            if native:
                self.sse({"type": "content_block_start", "index": 0, "content_block": {"type": "server_tool_use", "id": "srv-search", "name": "deepseek_web_search", "input": {}}})
                for chunk in ['{"query":', '"fixture"}']:
                    self.sse({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": chunk}})
                self.sse({"type": "content_block_stop", "index": 0})
                self.sse({"type": "content_block_start", "index": 1, "content_block": {"type": "web_search_tool_result", "tool_use_id": "srv-search", "content": [dict(source, type="web_search_result", encrypted_content="fixture-encrypted")]}})
                index = 2
            self.sse({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}})
            self.sse({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": "Search verified"}})
            self.sse({"type": "message_delta", "usage": usage if native else {}})
            self.sse({"type": "message_stop"})
        else:
            if native:
                self.sse({"choices": [{"delta": {"server_tool_calls": [{"calls": [{"kind": "search", "sources": [source]}]}]}}]})
            self.event("Search verified")
            if native:
                self.sse({"choices": [], "usage": usage})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

    def sse(self, event):
        data = ("data: " + json.dumps(event, ensure_ascii=False) + "\n\n").encode()
        for i in range(0, len(data), 3):
            self.wfile.write(data[i:i + 3])
            self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
navigation = "--navigation" in sys.argv
search_only = "--search-only" in sys.argv
composer_only = "--composer-only" in sys.argv
files_only = "--files-only" in sys.argv
experience_only = "--experience-only" in sys.argv
streaming_only = "--streaming-only" in sys.argv
arguments = ["--navigation-self-test" if navigation else "--ai-streaming-self-test" if streaming_only else "--ai-experience-self-test" if experience_only else "--ai-files-self-test" if files_only else "--ai-search-self-test" if search_only else "--ai-composer-self-test" if composer_only else "--ai-self-test", f"http://127.0.0.1:{server.server_port}"]
result = subprocess.run([sys.argv[1]] + arguments, timeout=120)
server.shutdown()
if not navigation and not search_only and not composer_only and not files_only and not experience_only and not streaming_only and (title_counts.get("hello fixture") != 1 or "Remember attachment fixture" in titles or "Replacement attachment fixture" in titles):
    failures.append("Conversation title was not generated exactly once")
if failures:
    print("FAIL: synthetic provider:", failures, file=sys.stderr)
sys.exit(result.returncode or bool(failures))
