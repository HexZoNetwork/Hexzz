// Hekz go-bridge — mirrors /home/hex/bots/tools-go/main.go + bot.js brain.
// Run this on YOUR PC/VPS (never inside Roblox):
//   HEKZ_KEY=secret OPENAI_BASE=https://9router.kliksosmed.id/v1 OPENAI_KEY=sk-... go run .
//
// Roblox game (HekzServer.lua, Brain.Mode=bridge) calls POST /chat via
// HttpService. Go holds the AI key, does OpenAI-compatible function calling,
// and asks the game to run tools (map_scan/players/read_script/exec/...) when needed.
// exec is the game-side equivalent of tg_event: raw Luau via loadstring.
// Pretest: no allowlist. Add your own auth before public release.

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
)

type Hist struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

type ChatReq struct {
	Text    string         `json:"text"`
	Player  string         `json:"player"`
	Stage   any            `json:"stage"`
	History []Hist         `json:"history"`
	System  string         `json:"system"`
	Tools   []map[string]any `json:"tools"`
}

type ChatRes struct {
	Reply string         `json:"reply,omitempty"`
	Tool  string         `json:"tool,omitempty"`
	Args  map[string]any `json:"args,omitempty"`
}

// --- safe server-side tools (same family as tools-go, minus shell/files) ---

func toolCalc(expr string) string {
	s := strings.ReplaceAll(expr, " ", "")
	if s == "" || len(s) > 64 {
		return "ERROR: empty/too long"
	}
	for _, c := range s {
		if !strings.ContainsRune("0123456789+-*/%^().", c) {
			return "ERROR: only 0-9 + - * / % ^ . ( ) allowed"
		}
	}
	// shunting-yard lite: use recursive descent (ported from tools-go parser)
	p := &parser{s: s}
	v, err := p.add()
	if err != nil {
		return "ERROR: " + err.Error()
	}
	p.skip()
	if p.i != len(p.s) {
		return fmt.Sprintf("ERROR: unexpected char at %d", p.i)
	}
	return fmt.Sprintf("%s = %v", expr, v)
}

type parser struct{ s string; i int }

func (p *parser) skip() {
	for p.i < len(p.s) && (p.s[p.i] == ' ' || p.s[p.i] == '\t') {
		p.i++
	}
}
func (p *parser) num() (float64, error) {
	p.skip()
	j := p.i
	for j < len(p.s) && ((p.s[j] >= '0' && p.s[j] <= '9') || p.s[j] == '.') {
		j++
	}
	if j == p.i {
		return 0, fmt.Errorf("expected number at %d", p.i)
	}
	var f float64
	_, err := fmt.Sscanf(p.s[p.i:j], "%f", &f)
	p.i = j
	return f, err
}
func (p *parser) prim() (float64, error) {
	p.skip()
	if p.i < len(p.s) && p.s[p.i] == '(' {
		p.i++
		v, err := p.add()
		if err != nil {
			return 0, err
		}
		p.skip()
		if p.i >= len(p.s) || p.s[p.i] != ')' {
			return 0, fmt.Errorf("missing )")
		}
		p.i++
		return v, nil
	}
	return p.num()
}
func (p *parser) pw() (float64, error) {
	v, err := p.prim()
	if err != nil {
		return 0, err
	}
	p.skip()
	if p.i < len(p.s) && p.s[p.i] == '^' {
		p.i++
		e, err := p.pw()
		if err != nil {
			return 0, err
		}
		v = math.Pow(v, e)
	}
	return v, nil
}
func (p *parser) mul() (float64, error) {
	v, err := p.pw()
	if err != nil {
		return 0, err
	}
	for {
		p.skip()
		if p.i < len(p.s) && (p.s[p.i] == '*' || p.s[p.i] == '/' || p.s[p.i] == '%') {
			op := p.s[p.i]
			p.i++
			r, err := p.pw()
			if err != nil {
				return 0, err
			}
			switch op {
			case '*':
				v *= r
			case '/':
				if r == 0 {
					return 0, fmt.Errorf("div by zero")
				}
				v /= r
			case '%':
				v = float64(int(v) % int(r))
			}
		} else {
			return v, nil
		}
	}
}
func (p *parser) add() (float64, error) {
	v, err := p.mul()
	if err != nil {
		return 0, err
	}
	for {
		p.skip()
		if p.i < len(p.s) && (p.s[p.i] == '+' || p.s[p.i] == '-') {
			op := p.s[p.i]
			p.i++
			r, err := p.mul()
			if err != nil {
				return 0, err
			}
			if op == '+' {
				v += r
			} else {
				v -= r
			}
		} else {
			return v, nil
		}
	}
}

func toolTime() string { return time.Now().UTC().Format(time.RFC3339) + " (UTC)" }

// --- AI self-calling helpers: tools must be callable by the AI itself,
// not only via keyword routing. Supports native function-calling AND
// text-embedded JSON for models that don't support tools. ---

func enabledSet(tools []map[string]any) map[string]bool {
	// Default mirrors Config.Tools (web_lookup off).
	def := map[string]bool{
		"get_time": true, "calc": true, "server_info": true,
		"players": true, "map_scan": true, "read_script": true,
		"exec": true, "web_lookup": false,
	}
	if len(tools) == 0 {
		return def
	}
	out := map[string]bool{}
	for _, t := range tools {
		name, _ := t["name"].(string)
		if name == "" {
			continue
		}
		en, ok := t["enabled"]
		if !ok {
			out[name] = true
			continue
		}
		if b, ok := en.(bool); ok {
			out[name] = b
		} else {
			out[name] = true
		}
	}
	// merge defaults for any missing key (treat missing as default)
	for k, v := range def {
		if _, ok := out[k]; !ok {
			out[k] = v
		}
	}
	return out
}

func buildToolDefs(enabled map[string]bool) []map[string]any {
	all := []map[string]any{
		{"type": "function", "function": map[string]any{"name": "map_scan", "description": "Ask game to describe the map around the player (vision)", "parameters": map[string]any{"type": "object", "properties": map[string]any{}}}},
		{"type": "function", "function": map[string]any{"name": "players", "description": "Ask game who is online and where", "parameters": map[string]any{"type": "object", "properties": map[string]any{}}}},
		{"type": "function", "function": map[string]any{"name": "read_script", "description": "Ask game to read any script's source by name or dotted path", "parameters": map[string]any{"type": "object", "properties": map[string]any{"name": map[string]any{"type": "string"}}}}},
		{"type": "function", "function": map[string]any{"name": "exec", "description": "UNIVERSAL: run raw LUAU ONLY on the game server via loadstring (never Go/JS/Python — Roblox cannot run Go). Full game/workspace access. Use for anything no other tool covers.", "parameters": map[string]any{"type": "object", "properties": map[string]any{"code": map[string]any{"type": "string", "description": "Luau chunk only, e.g. return game.PlaceId"}}, "required": []string{"code"}}}},
		{"type": "function", "function": map[string]any{"name": "server_info", "description": "Player count, uptime, place info (game-side)", "parameters": map[string]any{"type": "object", "properties": map[string]any{}}}},
		{"type": "function", "function": map[string]any{"name": "calc", "description": "Math", "parameters": map[string]any{"type": "object", "properties": map[string]any{"expression": map[string]any{"type": "string"}}, "required": []string{"expression"}}}},
		{"type": "function", "function": map[string]any{"name": "get_time", "description": "UTC time", "parameters": map[string]any{"type": "object", "properties": map[string]any{}}}},
		{"type": "function", "function": map[string]any{"name": "web_lookup", "description": "Web search/fetch via bridge (needs URL or query)", "parameters": map[string]any{"type": "object", "properties": map[string]any{"url": map[string]any{"type": "string"}, "query": map[string]any{"type": "string"}}}}},
	}
	out := []map[string]any{}
	for _, d := range all {
		fn, _ := d["function"].(map[string]any)
		n, _ := fn["name"].(string)
		if enabled[n] {
			out = append(out, d)
		}
	}
	return out
}

func toolSystemSuffix() string {
	return "\n\nTOOL USE (you, the AI, call tools yourself when needed):\n" +
		"- Preferred: native function calling (tools provided).\n" +
		"- Fallback (if tools unsupported): reply with ONLY a fenced block:\n" +
		"```tool\n{\"tool\": \"<name>\", \"args\": {...}}\n```\n" +
		"Valid names: get_time, calc, server_info, players, map_scan, read_script, exec, web_lookup.\n" +
		"exec code is LUAU ONLY (never Go/JS/Python — Roblox cannot run Go).\n" +
		"Examples:\n" +
		"```tool\n{\"tool\": \"exec\", \"args\": {\"code\": \"return game.PlaceId\"}}\n```\n" +
		"```tool\n{\"tool\": \"calc\", \"args\": {\"expression\": \"(2+3)*4\"}}\n```\n" +
		"If no tool is needed, answer directly with no code fence."
}

// parseTextTool lets the AI call tools via its own reply text.
// Accepts fenced ```tool {...}```, ```json {...}```, raw {"tool":...},
// [TOOL: name {...}] and EXEC:/CALC: shorthands.
func parseTextTool(content string) (string, map[string]any, bool) {
	s := strings.TrimSpace(content)
	if s == "" {
		return "", nil, false
	}
	cands := []string{}
	// 1) fenced blocks ```tool ...``` / ```json ...``` / plain ```...```
	for _, fence := range []string{"```tool", "```json", "```"} {
		rest := s
		for {
			i := strings.Index(strings.ToLower(rest), fence)
			if i < 0 {
				break
			}
			j := strings.Index(rest[i+len(fence):], "```")
			var inner string
			if j < 0 {
				inner = rest[i+len(fence):]
				rest = ""
			} else {
				inner = rest[i+len(fence) : i+len(fence)+j]
				rest = rest[i+len(fence)+j+3:]
			}
			inner = strings.TrimSpace(inner)
			// strip optional "json" language tag leftover
			if strings.HasPrefix(strings.ToLower(inner), "json") {
				inner = strings.TrimSpace(inner[4:])
			}
			if inner != "" {
				cands = append(cands, inner)
			}
			if j < 0 {
				break
			}
		}
	}
	// 2) raw body itself
	cands = append(cands, s)
	// 3) [TOOL: name {...}] style
	if i := strings.Index(strings.ToUpper(s), "[TOOL:"); i >= 0 {
		cands = append(cands, s[i:])
	}
	for _, c := range cands {
		t, a, ok := parseOneToolJSON(c)
		if ok {
			return t, a, true
		}
	}
	// 4) shorthand prefixes
	low := strings.ToLower(s)
	if strings.HasPrefix(low, "exec:") || strings.HasPrefix(low, "run ") || strings.HasPrefix(low, "run:") {
		code := strings.TrimSpace(s[strings.Index(s, ":")+1:])
		if strings.HasPrefix(low, "run ") {
			code = strings.TrimSpace(s[3:])
		}
		if code != "" {
			return "exec", map[string]any{"code": code}, true
		}
	}
	if strings.HasPrefix(low, "calc:") {
		ex := strings.TrimSpace(s[5:])
		if ex != "" {
			return "calc", map[string]any{"expression": ex}, true
		}
	}
	return "", nil, false
}

func parseOneToolJSON(c string) (string, map[string]any, bool) {
	t := strings.TrimSpace(c)
	// [TOOL: name {...}] -> convert to JSON-ish
	if strings.HasPrefix(strings.ToUpper(t), "[TOOL:") {
		inner := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(t[6:]), "]"))
		// "exec {\"code\":...}" or "exec" alone
		parts := strings.SplitN(inner, " ", 2)
		name := strings.ToLower(strings.TrimSpace(parts[0]))
		name = strings.Trim(name, "\"'{}")
		// strip trailing punctuation like ":" or "]"
		name = strings.Trim(name, ":,]")
		if name == "" {
			return "", nil, false
		}
		args := map[string]any{}
		if len(parts) == 2 {
			rest := strings.TrimSpace(parts[1])
			if strings.HasPrefix(rest, "{") {
				var a map[string]any
				if json.Unmarshal([]byte(rest), &a) == nil {
					args = a
				} else {
					args = map[string]any{"code": rest}
				}
			} else if rest != "" {
				args = map[string]any{"code": rest}
			}
		}
		if isKnownTool(name) {
			return name, args, true
		}
		return "", nil, false
	}
	// find first {...} JSON object in string
	start := strings.Index(t, "{")
	end := strings.LastIndex(t, "}")
	if start < 0 || end <= start {
		return "", nil, false
	}
	obj := t[start : end+1]
	var m map[string]any
	if err := json.Unmarshal([]byte(obj), &m); err != nil {
		return "", nil, false
	}
	name := ""
	if v, ok := m["tool"].(string); ok && v != "" {
		name = strings.ToLower(v)
	} else if v, ok := m["name"].(string); ok && v != "" {
		name = strings.ToLower(v)
	} else if v, ok := m["function"].(string); ok && v != "" {
		name = strings.ToLower(v)
	}
	if !isKnownTool(name) {
		return "", nil, false
	}
	var args map[string]any
	if a, ok := m["args"].(map[string]any); ok {
		args = a
	} else if a, ok := m["arguments"].(map[string]any); ok {
		args = a
	} else if aStr, ok := m["args"].(string); ok {
		// args as JSON string
		var a2 map[string]any
		if json.Unmarshal([]byte(aStr), &a2) == nil {
			args = a2
		} else {
			args = map[string]any{"code": aStr}
		}
	} else {
		// flat: remaining keys are args (e.g. {"tool":"calc","expression":"2+2"})
		args = map[string]any{}
		for k, v := range m {
			if k != "tool" && k != "name" && k != "function" {
				args[k] = v
			}
		}
	}
	if args == nil {
		args = map[string]any{}
	}
	return name, args, true
}

func isKnownTool(n string) bool {
	switch n {
	case "get_time", "calc", "server_info", "players", "map_scan", "read_script", "exec", "web_lookup",
		"run", "run_script", "execute", "loadstring", "exec_luau", "exec_code", "tg_event":
		return true
	}
	return false
}

func normalizeToolName(n string) string {
	n = strings.ToLower(n)
	switch n {
	case "run", "run_script", "execute", "loadstring", "exec_luau", "exec_code", "tg_event":
		return "exec"
	}
	return n
}

func isLocalTool(n string) bool {
	switch n {
	case "calc", "get_time":
		return true
	}
	return false
}

func runLocalTool(name string, args map[string]any) string {
	switch name {
	case "calc":
		ex, _ := args["expression"].(string)
		if ex == "" {
			ex, _ = args["code"].(string)
		}
		if ex == "" {
			ex, _ = args["text"].(string)
		}
		return toolCalc(ex)
	case "get_time":
		return toolTime()
	}
	return "ERROR: unknown local tool '" + name + "'"
}

func toolWebLookup(args map[string]any) string {
	urlStr, _ := args["url"].(string)
	q, _ := args["query"].(string)
	if urlStr == "" && q != "" && (strings.HasPrefix(q, "http://") || strings.HasPrefix(q, "https://")) {
		urlStr = q
	}
	if urlStr == "" {
		if q != "" {
			return "WEB_LOOKUP NEEDS URL: got query '" + q + "' but no URL — ask game to use web_lookup only with a full https URL, or answer from knowledge."
		}
		return "WEB_LOOKUP USAGE: {\"url\": \"https://example.com\"} — fetches page text (truncated)."
	}
	c := &http.Client{Timeout: 15 * time.Second}
	req, err := http.NewRequest("GET", urlStr, nil)
	if err != nil {
		return "WEB_LOOKUP ERROR: " + err.Error()
	}
	req.Header.Set("User-Agent", "hekz-bridge/1.0")
	res, err := c.Do(req)
	if err != nil {
		return "WEB_LOOKUP ERROR: " + err.Error()
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 8000))
	txt := strings.TrimSpace(string(b))
	if txt == "" {
		return fmt.Sprintf("WEB_LOOKUP: %s -> HTTP %d (empty body)", urlStr, res.StatusCode)
	}
	// crude HTML -> text
	txt = strings.ReplaceAll(txt, "\n", " ")
	for len(txt) > 0 && strings.Contains(txt, "  ") {
		txt = strings.ReplaceAll(txt, "  ", " ")
	}
	if len(txt) > 4000 {
		txt = txt[:4000] + "...[truncated]"
	}
	return fmt.Sprintf("WEB_LOOKUP %s -> HTTP %d: %s", urlStr, res.StatusCode, txt)
}

func extractExpr(s string) string {
	start, end := -1, -1
	for i := 0; i < len(s); i++ {
		c := s[i]
		isMath := (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '*' || c == '/' || c == '%' || c == '^' || c == '(' || c == ')' || c == '.' || c == ' '
		if isMath {
			if start == -1 {
				start = i
			}
			end = i + 1
		} else if start != -1 {
			break
		}
	}
	if start == -1 {
		return s
	}
	return strings.TrimSpace(s[start:end])
}

func callLLMOnce(base, key, model string, msgs []map[string]any, toolDefs []map[string]any) (content string, toolName string, toolArgs map[string]any, err error) {
	body, _ := json.Marshal(map[string]any{
		"model":       model,
		"messages":    msgs,
		"temperature": 0.7,
		"max_tokens":  512,
		"stream":      false,
		"tools":       toolDefs,
	})
	req, _ := http.NewRequest("POST", base+"/chat/completions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	c := &http.Client{Timeout: 30 * time.Second}
	res, err := c.Do(req)
	if err != nil {
		return "", "", nil, err
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 300 {
		n := len(b)
		if n > 300 {
			n = 300
		}
		return "", "", nil, fmt.Errorf("AI %d: %s", res.StatusCode, string(b)[:n])
	}
	var j struct {
		Choices []struct {
			Message struct {
				Content   string `json:"content"`
				ToolCalls []struct {
					ID       string `json:"id"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(b, &j); err != nil {
		return "", "", nil, err
	}
	if len(j.Choices) == 0 {
		return "", "", nil, fmt.Errorf("empty AI reply")
	}
	m := j.Choices[0].Message
	if len(m.ToolCalls) > 0 {
		tc := m.ToolCalls[0]
		var a map[string]any
		_ = json.Unmarshal([]byte(tc.Function.Arguments), &a)
		if a == nil {
			a = map[string]any{}
		}
		return m.Content, tc.Function.Name, a, nil
	}
	return m.Content, "", nil, nil
}

func openAIChat(system, user string, history []Hist, enabled map[string]bool) (reply, tool string, args map[string]any, err error) {
	base := strings.TrimSuffix(os.Getenv("OPENAI_BASE"), "/")
	key := os.Getenv("OPENAI_KEY")
	model := os.Getenv("OPENAI_MODEL")
	if model == "" {
		model = "jmbot/mimo-v2.6-flash"
	}
	if base == "" || key == "" {
		return "", "", nil, fmt.Errorf("no OPENAI_BASE/OPENAI_KEY — set env or run bridge in local mode")
	}
	if enabled == nil {
		enabled = enabledSet(nil)
	}
	toolDefs := buildToolDefs(enabled)
	systemFull := system + toolSystemSuffix()
	msgs := []map[string]any{{"role": "system", "content": systemFull}}
	for _, h := range history {
		role := h.Role
		// "tool" history from Roblox becomes user-visible tool result so ANY
		// model (even without native tool support) can keep reasoning.
		if role != "user" && role != "assistant" {
			role = "user"
		}
		msgs = append(msgs, map[string]any{"role": role, "content": h.Text})
	}
	msgs = append(msgs, map[string]any{"role": "user", "content": user})

	// AI self-calling loop: let the AI itself chain local tools (calc/time/web)
	// up to 4 LLM turns inside the bridge. Game-side tools are returned to
	// Roblox immediately so the game executes them and POSTs results back.
	for i := 0; i < 4; i++ {
		content, tcName, tcArgs, err := callLLMOnce(base, key, model, msgs, toolDefs)
		if err != nil {
			return "", "", nil, err
		}
		if tcName != "" {
			norm := normalizeToolName(tcName)
			if !enabled[norm] {
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [" + norm + "]: TOOL OFF (disabled in Config.Tools). Answer without it."})
				continue
			}
			if isLocalTool(norm) {
				out := runLocalTool(norm, tcArgs)
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [" + norm + "]: " + out})
				continue
			}
			if norm == "web_lookup" {
				if !enabled["web_lookup"] {
					msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
					msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [web_lookup]: TOOL OFF. Answer without web."})
					continue
				}
				out := toolWebLookup(tcArgs)
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [web_lookup]: " + out})
				continue
			}
			// game-side tool: AI itself asked for it -> let Roblox run it
			return "", norm, tcArgs, nil
		}
		// No native tool call -> check text-embedded tool call (AI itself via text)
		if tName, tArgs, ok := parseTextTool(content); ok {
			norm := normalizeToolName(tName)
			if !enabled[norm] {
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [" + norm + "]: TOOL OFF (disabled). Answer without it."})
				continue
			}
			if isLocalTool(norm) {
				out := runLocalTool(norm, tArgs)
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [" + norm + "]: " + out})
				continue
			}
			if norm == "web_lookup" {
				if !enabled["web_lookup"] {
					msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
					msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [web_lookup]: TOOL OFF. Answer without web."})
					continue
				}
				out := toolWebLookup(tArgs)
				msgs = append(msgs, map[string]any{"role": "assistant", "content": content})
				msgs = append(msgs, map[string]any{"role": "user", "content": "TOOL RESULT [web_lookup]: " + out})
				continue
			}
			return "", norm, tArgs, nil
		}
		return content, "", nil, nil
	}
	return "I ran several tool steps but need you to ask the next step (max rounds reached).", "", nil, nil
}

func extractCodeBlock(s string) string {
	// ```lua ...``` or ```...```
	low := strings.ToLower(s)
	i := strings.Index(low, "```")
	if i < 0 {
		return ""
	}
	rest := s[i+3:]
	// strip optional language tag on first line
	if nl := strings.Index(rest, "\n"); nl >= 0 {
		tag := strings.TrimSpace(rest[:nl])
		if tag != "" && len(tag) < 12 && !strings.ContainsAny(tag, " \t(){};=") {
			rest = rest[nl+1:]
		}
	}
	if j := strings.Index(rest, "```"); j >= 0 {
		rest = rest[:j]
	}
	return strings.TrimSpace(rest)
}

func extractReadName(s string) string {
	low := strings.ToLower(s)
	for _, kw := range []string{"read ", "script ", "source "} {
		if i := strings.Index(low, kw); i >= 0 {
			rest := strings.TrimSpace(s[i+len(kw):])
			// take first token of word chars / dots / _ / -
			j := 0
			for j < len(rest) && ((rest[j] >= 'A' && rest[j] <= 'Z') || (rest[j] >= 'a' && rest[j] <= 'z') || (rest[j] >= '0' && rest[j] <= '9') || rest[j] == '.' || rest[j] == '_' || rest[j] == '-') {
				j++
			}
			if j > 0 {
				return rest[:j]
			}
		}
	}
	return ""
}

func extractExecCode(s string) string {
	if b := extractCodeBlock(s); b != "" {
		return b
	}
	low := strings.ToLower(s)
	for _, kw := range []string{"run ", "exec ", "execute ", "loadstring "} {
		if i := strings.Index(low, kw); i >= 0 {
			return strings.TrimSpace(s[i+len(kw):])
		}
	}
	// last resort: whole message is the code (Roblox side already tried)
	return strings.TrimSpace(s)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func main() {
	key := os.Getenv("HEKZ_KEY")
	port := os.Getenv("PORT")
	if port == "" {
		port = "8090"
	}
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("hekz ok"))
	})
	http.HandleFunc("/chat", func(w http.ResponseWriter, r *http.Request) {
		if key != "" && r.Header.Get("X-Hekz-Key") != key {
			http.Error(w, "bad key", 401)
			return
		}
		var q ChatReq
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&q); err != nil {
			http.Error(w, "bad json: "+err.Error(), 400)
			return
		}
		text := strings.TrimSpace(q.Text)
		if text == "" {
			json.NewEncoder(w).Encode(ChatRes{Reply: "Just talk — try 'what time is it', 'calc (2+3)*4', 'scan the map', 'who is here', 'read MyScript', 'run print(\"hi\")'."})
			return
		}
		// Local fallback when no AI key (mirrors HekzServer routeLocal).
		// Tools are still called by the "AI" (fallback brain) itself: it picks
		// the right tool from free text, same as the local brain.
		if os.Getenv("OPENAI_KEY") == "" {
			low := strings.ToLower(text)
			switch {
			case strings.HasPrefix(low, "tool result"):
				// Game just ran a tool the fallback brain requested.
				// Return it as the final answer so Roblox can show it, and let
				// the next user message continue the chain.
				// Strip the prefix for a cleaner chat reply.
				clean := strings.TrimSpace(text[len("tool result"):])
				clean = strings.TrimLeft(clean, ":[] ")
				if clean == "" {
					clean = text
				}
				json.NewEncoder(w).Encode(ChatRes{Reply: clean + "\n\nAnything else? (time | calc | scan | players | read | run)"})
			case strings.Contains(low, "time") || strings.Contains(low, "clock") || strings.Contains(low, "date"):
				json.NewEncoder(w).Encode(ChatRes{Reply: toolTime()})
			case strings.Contains(low, "calc") || strings.Contains(low, "calculate") || strings.Contains(low, "math"):
				ex := extractExpr(text)
				if ex == "" {
					ex = text
				}
				json.NewEncoder(w).Encode(ChatRes{Reply: toolCalc(ex)})
			case strings.Contains(low, "scan") || strings.Contains(low, "map") || strings.Contains(low, "see") || strings.Contains(low, "look") || strings.Contains(low, "around") || strings.Contains(low, "vision"):
				json.NewEncoder(w).Encode(ChatRes{Tool: "map_scan", Args: map[string]any{}})
			case strings.Contains(low, "who") || strings.Contains(low, "player") || strings.Contains(low, "here") || strings.Contains(low, "online"):
				json.NewEncoder(w).Encode(ChatRes{Tool: "players", Args: map[string]any{}})
			case strings.Contains(low, "server") || strings.Contains(low, "uptime"):
				json.NewEncoder(w).Encode(ChatRes{Tool: "server_info", Args: map[string]any{}})
			case strings.Contains(low, "read") || strings.Contains(low, "script") || strings.Contains(low, "source"):
				if b := extractCodeBlock(text); b != "" {
					json.NewEncoder(w).Encode(ChatRes{Tool: "exec", Args: map[string]any{"code": b}})
				} else {
					json.NewEncoder(w).Encode(ChatRes{Tool: "read_script", Args: map[string]any{"name": extractReadName(text)}})
				}
			case strings.Contains(low, "run") || strings.Contains(low, "exec") || strings.Contains(low, "execute") || strings.Contains(low, "loadstring") || strings.Contains(text, "```"):
				json.NewEncoder(w).Encode(ChatRes{Tool: "exec", Args: map[string]any{"code": extractExecCode(text)}})
			default:
				// math expression without keyword still calculates
				if ex := extractExpr(text); ex != "" && ex != text && strings.ContainsAny(ex, "+-*/^%()") {
					json.NewEncoder(w).Encode(ChatRes{Reply: toolCalc(ex)})
				} else {
					json.NewEncoder(w).Encode(ChatRes{Reply: "Hekz here. Just talk — try: time | calc (2+3)*4 | scan the map | who is here | read <ScriptName> | run <luau>"})
				}
			}
			return
		}
		enabled := enabledSet(q.Tools)
		reply, tool, args, err := openAIChat(q.System, text, q.History, enabled)
		if err != nil {
			json.NewEncoder(w).Encode(ChatRes{Reply: "Brain hiccup: " + err.Error()})
			return
		}
		json.NewEncoder(w).Encode(ChatRes{Reply: reply, Tool: tool, Args: args})
	})
	fmt.Println("hekz bridge on :" + port)
	http.ListenAndServe(":"+port, nil)
}
