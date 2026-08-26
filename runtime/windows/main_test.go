package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestMain(m *testing.M) {
	_ = os.Setenv("OPEN_COMPUTER_USE_WINDOWS_VISUAL_INDICATOR", "0")
	os.Exit(m.Run())
}

func TestToolDefinitionCount(t *testing.T) {
	if got := len(toolDefinitions()); got != 14 {
		t.Fatalf("toolDefinitions() count = %d, want 14 (13 window-level tools plus get_app_state compatibility adapter)", got)
	}
}

func TestWindowToolSchemas(t *testing.T) {
	for _, name := range []string{"list_windows", "get_window", "get_window_state", "activate_window", "launch_app"} {
		findToolDefinition(t, name)
	}

	for _, name := range []string{"get_window_state", "activate_window"} {
		tool := findToolDefinition(t, name)
		properties := tool.InputSchema["properties"].(map[string]any)
		window := properties["window"].(map[string]any)
		if got := window["type"]; got != "object" {
			t.Fatalf("%s window schema type = %v, want object", name, got)
		}
		fields := window["properties"].(map[string]any)
		for _, field := range []string{"appId", "pid", "hwnd", "title", "generation"} {
			if _, ok := fields[field]; !ok {
				t.Fatalf("%s window schema missing %s", name, field)
			}
		}
		required := window["required"].([]string)
		if strings.Join(required, ",") != "appId,pid,hwnd,generation" {
			t.Fatalf("%s WindowRef required = %#v", name, required)
		}
	}

	for _, name := range []string{"click", "drag", "perform_secondary_action", "press_key", "scroll", "set_value", "type_text"} {
		properties := findToolDefinition(t, name).InputSchema["properties"].(map[string]any)
		if _, ok := properties["window"]; !ok {
			t.Fatalf("%s should expose window", name)
		}
	}

	clickProperties := findToolDefinition(t, "click").InputSchema["properties"].(map[string]any)
	if _, ok := clickProperties["observation_id"]; !ok {
		t.Fatal("click should expose observation_id")
	}
	if _, ok := clickProperties["screenshot_id"]; !ok {
		t.Fatal("click should expose screenshot_id")
	}
}

func TestRequiredWindowRef(t *testing.T) {
	input := map[string]any{
		"window": map[string]any{
			"appId":      "notepad",
			"pid":        json.Number("42"),
			"hwnd":       "1234",
			"title":      "notes.txt - Notepad",
			"generation": "42-1234-999",
		},
	}
	got, err := requiredWindowRef(input)
	if err != nil {
		t.Fatal(err)
	}
	if got.AppID != "notepad" || got.PID != 42 || got.HWND != "1234" || got.Generation != "42-1234-999" {
		t.Fatalf("requiredWindowRef() = %#v", got)
	}

	for _, invalid := range []map[string]any{
		{},
		{"window": "not-an-object"},
		{"window": map[string]any{"appId": "notepad", "pid": 42, "hwnd": "1234"}},
	} {
		if _, err := requiredWindowRef(invalid); err == nil {
			t.Fatalf("requiredWindowRef(%#v) unexpectedly succeeded", invalid)
		}
	}
}

func TestRequiredActionTarget(t *testing.T) {
	target, err := requiredActionTarget(map[string]any{
		"window": map[string]any{
			"appId":      "notepad",
			"pid":        42,
			"hwnd":       "1234",
			"generation": "42-1234-999",
		},
		"observation_id": "obs-1",
		"screenshot_id":  "shot-1",
	})
	if err != nil {
		t.Fatal(err)
	}
	if target.Window == nil || target.Window.HWND != "1234" || target.ObservationID != "obs-1" || target.ScreenshotID != "shot-1" {
		t.Fatalf("requiredActionTarget() = %#v", target)
	}
	if _, err := requiredActionTarget(map[string]any{}); err == nil || err.Error() != "One of app or window is required" {
		t.Fatalf("missing action target error = %v", err)
	}
}

func TestWindowToolDispatchPreservesIdentity(t *testing.T) {
	want := windowRef{AppID: "notepad", PID: 42, HWND: "1234", Title: "notes.txt - Notepad", Generation: "42-1234-999"}
	windowArgs := map[string]any{
		"window": map[string]any{
			"appId":      want.AppID,
			"pid":        want.PID,
			"hwnd":       want.HWND,
			"title":      want.Title,
			"generation": want.Generation,
		},
	}
	service := newService()
	var requests []psRequest
	service.runPS = func(request psRequest) (*psResponse, error) {
		requests = append(requests, request)
		switch request.Tool {
		case "get_window":
			return &psResponse{OK: true, Window: &want}, nil
		case "launch_app":
			return &psResponse{OK: true, Window: &want}, nil
		case "activate_window":
			return &psResponse{OK: true, Status: "applied", Window: &want}, nil
		case "get_window_state":
			return &psResponse{OK: true, Snapshot: &appSnapshot{
				App:           appDescriptor{Name: want.AppID, BundleIdentifier: want.AppID, PID: want.PID},
				Window:        &want,
				ObservationID: "obs-1",
				ScreenshotID:  "shot-1",
			}}, nil
		default:
			t.Fatalf("unexpected PowerShell request: %#v", request)
			return nil, nil
		}
	}

	if result := service.callTool("get_window", map[string]any{"app": "notepad", "title": "notes.txt"}); result.IsError {
		t.Fatalf("get_window failed: %#v", result)
	}
	if result := service.callTool("launch_app", map[string]any{"app": "notepad.exe"}); result.IsError {
		t.Fatalf("launch_app failed: %#v", result)
	}
	if result := service.callTool("activate_window", windowArgs); result.IsError || !strings.Contains(result.Content[0].Text, `"status":"applied"`) {
		t.Fatalf("activate_window result = %#v", result)
	}
	if result := service.callTool("get_window_state", windowArgs); result.IsError {
		t.Fatalf("get_window_state failed: %#v", result)
	}

	if len(requests) != 4 {
		t.Fatalf("PowerShell request count = %d, want 4", len(requests))
	}
	if requests[0].App != "notepad" || requests[0].Title != "notes.txt" {
		t.Fatalf("get_window request = %#v", requests[0])
	}
	for _, index := range []int{2, 3} {
		if requests[index].Window == nil || *requests[index].Window != want {
			t.Fatalf("request %d WindowRef = %#v, want %#v", index, requests[index].Window, want)
		}
	}
}

func TestClickMethodSchemaAndParser(t *testing.T) {
	tool := findToolDefinition(t, "click")
	properties := tool.InputSchema["properties"].(map[string]any)
	method := properties["click_method"].(map[string]any)
	values := method["enum"].([]string)
	if strings.Join(values, ",") != "auto,accessibility,app_post,sky_click,global" {
		t.Fatalf("click_method enum = %#v", values)
	}

	for input, want := range map[string]string{
		"":              "auto",
		" AUTO ":        "auto",
		"Accessibility": "accessibility",
		"app_post":      "app_post",
		"SKY_CLICK":     "sky_click",
		"GLOBAL":        "global",
	} {
		got, err := parseClickMethod(input)
		if err != nil {
			t.Fatalf("parseClickMethod(%q): %v", input, err)
		}
		if got != want {
			t.Fatalf("parseClickMethod(%q) = %q, want %q", input, got, want)
		}
	}

	for _, input := range []string{"physical", "targeted"} {
		if _, err := parseClickMethod(input); err == nil || !strings.Contains(err.Error(), "Expected one of: auto, accessibility, app_post, sky_click, global") {
			t.Fatalf("parseClickMethod(%s) error = %v", input, err)
		}
	}
}

func TestWindowsRejectsUnsupportedGlobalClickBeforeSnapshotLookup(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click(actionTarget{App: "Notepad"}, "", &x, &y, 1, "left", "global")
	if !result.IsError || result.Content[0].Text != "click_method 'global' is not supported on Windows" {
		t.Fatalf("global click result = %#v", result)
	}
}

func TestWindowsRejectsUnsupportedSkyClickBeforeSnapshotLookup(t *testing.T) {
	x, y := 10.0, 20.0
	result := newService().click(actionTarget{App: "Notepad"}, "", &x, &y, 1, "left", "sky_click")
	if !result.IsError || result.Content[0].Text != "click_method 'sky_click' is not supported on Windows" {
		t.Fatalf("sky_click result = %#v", result)
	}
}

func TestWindowActionsRequireMatchingSnapshotIDs(t *testing.T) {
	window := windowRef{AppID: "notepad", PID: 42, HWND: "1234", Generation: "42-1234-999"}
	snapshot := &appSnapshot{
		App:           appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 42},
		Window:        &window,
		ObservationID: "obs-1",
		ScreenshotID:  "shot-1",
		WindowBounds:  &frame{X: 10, Y: 10, Width: 100, Height: 100},
		Elements:      []elementRecord{{Index: 7}},
	}
	service := newService()
	service.rememberSnapshot(snapshotWindowKey(window), snapshot)

	if result := service.click(actionTarget{Window: &window}, "7", nil, nil, 1, "left", "auto"); !result.IsError || result.Content[0].Text != "Missing required argument: observation_id" {
		t.Fatalf("missing observation_id result = %#v", result)
	}
	if result := service.typeText(actionTarget{Window: &window}, "hello"); !result.IsError || result.Content[0].Text != "Missing required argument: observation_id" {
		t.Fatalf("type_text should require observation_id for window target: %#v", result)
	}
	if result := service.drag(actionTarget{Window: &window}, floatPtr(1), floatPtr(2), floatPtr(3), floatPtr(4)); !result.IsError || result.Content[0].Text != "Missing required argument: screenshot_id" {
		t.Fatalf("drag should require screenshot_id for window target: %#v", result)
	}
	if result := service.click(actionTarget{Window: &window, ObservationID: "stale"}, "7", nil, nil, 1, "left", "auto"); !result.IsError || !strings.Contains(result.Content[0].Text, "observation_id does not match") {
		t.Fatalf("stale observation_id result = %#v", result)
	}
	if result := service.drag(actionTarget{Window: &window, ScreenshotID: "stale"}, floatPtr(1), floatPtr(2), floatPtr(3), floatPtr(4)); !result.IsError || !strings.Contains(result.Content[0].Text, "screenshot_id does not match") {
		t.Fatalf("stale screenshot_id result = %#v", result)
	}
}

func TestCoordinateActionForwardsCaptureMappingContract(t *testing.T) {
	window := windowRef{AppID: "notepad", PID: 42, HWND: "1234", Generation: "42-1234-999"}
	capture := &captureDescriptor{
		Method:          "windows-graphics-capture",
		Width:           800,
		Height:          600,
		CoordinateSpace: "physical-screen-pixels",
		DPI:             192,
		WindowDPI:       96,
		ScaleFactor:     2,
	}
	service := newService()
	service.rememberSnapshot(snapshotWindowKey(window), &appSnapshot{
		App:           appDescriptor{Name: "notepad", PID: 42},
		Window:        &window,
		ObservationID: "obs-1",
		ScreenshotID:  "shot-1",
		WindowBounds:  &frame{X: -400, Y: 20, Width: 800, Height: 600},
		Capture:       capture,
	})
	var request psRequest
	service.runPS = func(input psRequest) (*psResponse, error) {
		request = input
		return &psResponse{OK: true, Status: "applied", Snapshot: &appSnapshot{
			App:           appDescriptor{Name: "notepad", PID: 42},
			Window:        &window,
			ObservationID: "obs-2",
			ScreenshotID:  "shot-2",
		}}, nil
	}
	x, y := 100.0, 50.0
	result := service.click(actionTarget{Window: &window, ScreenshotID: "shot-1"}, "", &x, &y, 1, "left", "auto")
	if result.IsError {
		t.Fatalf("coordinate click failed: %#v", result)
	}
	if request.Capture != capture || request.WindowBounds == nil || request.WindowBounds.X != -400 {
		t.Fatalf("coordinate action did not preserve screenshot mapping metadata: %#v", request)
	}
}

func TestLegacyActionUsesCachedWindowIdentity(t *testing.T) {
	window := windowRef{AppID: "notepad", PID: 42, HWND: "1234", Generation: "42-1234-999"}
	service := newService()
	service.rememberSnapshot(snapshotQueryKey("Notepad"), &appSnapshot{
		App:           appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 42},
		Window:        &window,
		ObservationID: "obs-1",
		ScreenshotID:  "shot-1",
		WindowBounds:  &frame{X: 10, Y: 10, Width: 100, Height: 100},
	})
	var request psRequest
	service.runPS = func(input psRequest) (*psResponse, error) {
		request = input
		return &psResponse{OK: true, Status: "applied", Snapshot: &appSnapshot{
			App:           appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 42},
			Window:        &window,
			ObservationID: "obs-2",
			ScreenshotID:  "shot-2",
		}}, nil
	}
	result := service.pressKey(actionTarget{App: "Notepad"}, "Return")
	if result.IsError {
		t.Fatalf("legacy press_key failed: %#v", result)
	}
	if request.Window == nil || *request.Window != window {
		t.Fatalf("legacy action should reuse cached WindowRef: %#v", request)
	}
	if !strings.Contains(result.Content[0].Text, "ActionStatus: applied") {
		t.Fatalf("result should render action status: %#v", result)
	}
}

func TestWindowTextActionForwardsObservationID(t *testing.T) {
	window := windowRef{AppID: "notepad", PID: 42, HWND: "1234", Generation: "42-1234-999"}
	service := newService()
	service.rememberSnapshot(snapshotWindowKey(window), &appSnapshot{
		App:           appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 42},
		Window:        &window,
		ObservationID: "obs-1",
		ScreenshotID:  "shot-1",
	})
	var request psRequest
	service.runPS = func(input psRequest) (*psResponse, error) {
		request = input
		return &psResponse{OK: true, Status: "applied", Snapshot: &appSnapshot{
			App:           appDescriptor{Name: "notepad", BundleIdentifier: "notepad", PID: 42},
			Window:        &window,
			ObservationID: "obs-2",
			ScreenshotID:  "shot-2",
		}}, nil
	}

	result := service.typeText(actionTarget{Window: &window, ObservationID: "obs-1"}, "hello")
	if result.IsError {
		t.Fatalf("window type_text failed: %#v", result)
	}
	if request.ObservationID != "obs-1" {
		t.Fatalf("type_text ObservationID = %q, want obs-1", request.ObservationID)
	}
}

func TestGetAppStateSchemaIncludesTextLimit(t *testing.T) {
	tool := findToolDefinition(t, "get_app_state")
	properties := tool.InputSchema["properties"].(map[string]any)
	if _, ok := properties["show_full_text"]; ok {
		t.Fatal("get_app_state schema should not expose show_full_text")
	}
	textLimit := properties["text_limit"].(map[string]any)
	anyOf := textLimit["anyOf"].([]any)
	integerLimit := anyOf[0].(map[string]any)
	if got := integerLimit["type"]; got != "integer" {
		t.Fatalf("text_limit integer type = %v, want integer", got)
	}
	if got := integerLimit["minimum"]; got != 1 {
		t.Fatalf("text_limit integer minimum = %v, want 1", got)
	}
	maxLimit := anyOf[1].(map[string]any)
	if got := maxLimit["type"]; got != "string" {
		t.Fatalf("text_limit max type = %v, want string", got)
	}
	enum := maxLimit["enum"].([]string)
	if len(enum) != 1 || enum[0] != "max" {
		t.Fatalf("text_limit enum = %#v, want [max]", enum)
	}
	maxTreeNodes := properties["max_tree_nodes"].(map[string]any)
	if got := maxTreeNodes["type"]; got != "integer" {
		t.Fatalf("max_tree_nodes type = %v, want integer", got)
	}
	if got := maxTreeNodes["minimum"]; got != 1 {
		t.Fatalf("max_tree_nodes minimum = %v, want 1", got)
	}
	maxTreeDepth := properties["max_tree_depth"].(map[string]any)
	if got := maxTreeDepth["type"]; got != "integer" {
		t.Fatalf("max_tree_depth type = %v, want integer", got)
	}
	if got := maxTreeDepth["minimum"]; got != 1 {
		t.Fatalf("max_tree_depth minimum = %v, want 1", got)
	}
	required := tool.InputSchema["required"].([]string)
	if len(required) != 1 || required[0] != "app" {
		t.Fatalf("required = %#v, want [app]", required)
	}
}

func TestParseSnapshotArgsSupportsTextLimit(t *testing.T) {
	app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs([]string{"--text-limit", "1000", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != 1000 || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs = (%q, %#v, %v, %v), want (Notepad, 1000, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad", "--text-limit", "max"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit == nil || textLimit.runtimeValue() != "max" || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs max = (%q, %#v, %v, %v), want (Notepad, max, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes != nil || maxTreeDepth != nil {
		t.Fatalf("parseSnapshotArgs default = (%q, %#v, %v, %v), want (Notepad, nil, nil, nil)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}

	app, textLimit, maxTreeNodes, maxTreeDepth, err = parseSnapshotArgs([]string{"--max-tree-nodes", "3000", "--max-tree-depth", "96", "Notepad"})
	if err != nil {
		t.Fatal(err)
	}
	if app != "Notepad" || textLimit != nil || maxTreeNodes == nil || *maxTreeNodes != 3000 || maxTreeDepth == nil || *maxTreeDepth != 96 {
		t.Fatalf("parseSnapshotArgs custom tree budget = (%q, %#v, %v, %v), want (Notepad, nil, 3000, 96)", app, textLimit, maxTreeNodes, maxTreeDepth)
	}
}

func TestParseSnapshotArgsRejectsInvalidTextLimit(t *testing.T) {
	for _, value := range []string{"0", "-1", "1.5", "full"} {
		if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit", value, "Notepad"}); err == nil || err.Error() != "--text-limit must be a positive integer or max" {
			t.Fatalf("invalid text_limit %q error = %v", value, err)
		}
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--text-limit"}); err == nil || err.Error() != "--text-limit requires a positive integer or max value" {
		t.Fatalf("missing text_limit error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--show-full-text", "Notepad"}); err == nil || err.Error() != "unknown snapshot option: --show-full-text" {
		t.Fatalf("old show_full_text flag error = %v", err)
	}
}

func TestParseSnapshotArgsRejectsInvalidTreeBudget(t *testing.T) {
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes", "0", "Notepad"}); err == nil || err.Error() != "--max-tree-nodes must be a positive integer" {
		t.Fatalf("invalid max_tree_nodes error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-depth", "1.5", "Notepad"}); err == nil || err.Error() != "--max-tree-depth must be a positive integer" {
		t.Fatalf("invalid max_tree_depth error = %v", err)
	}
	if _, _, _, _, err := parseSnapshotArgs([]string{"--max-tree-nodes"}); err == nil || err.Error() != "--max-tree-nodes requires a positive integer value" {
		t.Fatalf("missing max_tree_nodes error = %v", err)
	}
}

func TestCallSequenceStopsAfterFirstToolError(t *testing.T) {
	output, hasError, err := runCallCommand([]string{
		"--calls",
		`[{"tool":"not_a_tool"},{"tool":"list_apps"}]`,
	}, newService())
	if err != nil {
		t.Fatal(err)
	}
	if !hasError {
		t.Fatal("expected hasError")
	}
	items, ok := output.([]map[string]any)
	if !ok {
		t.Fatalf("output type = %T", output)
	}
	if len(items) != 1 {
		t.Fatalf("sequence output count = %d, want 1", len(items))
	}
}

func TestReadArgumentsAcceptsJSONObject(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","pages":2}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if args["app"] != "Notepad" {
		t.Fatalf("app = %v", args["app"])
	}
	if args["pages"].(json.Number).String() != "2" {
		t.Fatalf("pages = %v", args["pages"])
	}
}

func TestElementIndexAcceptsStringAndJSONNumber(t *testing.T) {
	args, err := readArguments(`{"app":"Notepad","element_index":0}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := optionalElementIndex(args); got != "0" {
		t.Fatalf("numeric element_index = %q, want 0", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": "14"}); got != "14" {
		t.Fatalf("string element_index = %q, want 14", got)
	}
	if got := optionalElementIndex(map[string]any{"element_index": json.Number("1.5")}); got != "" {
		t.Fatalf("fractional element_index = %q, want empty", got)
	}
}

func TestMCPInitializeResponseContainsToolsCapability(t *testing.T) {
	request := map[string]any{
		"jsonrpc": "2.0",
		"id":      float64(1),
		"method":  "initialize",
		"params":  map[string]any{},
	}
	response := handleMCPRequest(request, newService())
	result, ok := response["result"].(map[string]any)
	if !ok {
		t.Fatalf("missing result: %#v", response)
	}
	capabilities := result["capabilities"].(map[string]any)
	if _, ok := capabilities["tools"]; !ok {
		t.Fatalf("missing tools capability: %#v", capabilities)
	}
}

func TestCLIHelpMentionsWindowsRuntime(t *testing.T) {
	var out bytes.Buffer
	if err := runCLI([]string{"--help"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Open Computer Use for Windows") {
		t.Fatalf("help text did not mention Windows runtime:\n%s", out.String())
	}
}

func TestWindowsRuntimeForegroundActionsRequireOptIn(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
		t.Fatal("Windows app launch fallback must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") {
		t.Fatal("Windows SetFocus action must remain opt-in")
	}
	if !strings.Contains(windowsRuntimeScript, "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK") {
		t.Fatal("Windows UIA text fallback must remain opt-in")
	}
	if !strings.Contains(serverInstructions, "does not auto-launch apps or enable legacy UIA focus/text fallbacks by default") {
		t.Fatal("MCP instructions must document the Windows background-focus policy")
	}
}

func TestWindowsRuntimeWindowIdentityAndActivationContract(t *testing.T) {
	for _, marker := range []string{
		"EnumWindows",
		"GetForegroundWindow",
		"IsWindowEnabled",
		"SendInput",
		"RootWindowAtPoint",
		"occluded_by_non_target",
		"SetForegroundWindow",
		"AttachThreadInput",
		"ambiguous_window",
		"stale_window",
		"function Get-WindowRecords",
		"function Resolve-ProcessWindow",
		"function Resolve-WindowRef",
		"function Activate-Window",
		"function Resolve-ActionContext",
		"screenshotId = $snapshotID",
		"actionStatus -NotePropertyValue \"applied\"",
	} {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime missing window contract marker %q", marker)
		}
	}
	if !strings.Contains(serverInstructions, "list_windows") || !strings.Contains(serverInstructions, "activate_window") {
		t.Fatal("MCP instructions must describe the v2 window flow")
	}
}

func TestUTF8EncodingInPowerShellScript(t *testing.T) {
	// Verify that the PowerShell script sets UTF-8 encoding
	if !strings.Contains(windowsRuntimeScript, "$OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set $OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
	if !strings.Contains(windowsRuntimeScript, "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8") {
		t.Fatal("PowerShell script must set [Console]::OutputEncoding to UTF-8 for proper non-ASCII character handling")
	}
}

func TestWindowsRuntimeRetriesTransientAddTypeCompilation(t *testing.T) {
	markers := []string{
		"$win32Source = @\"",
		"for ($attempt = 1; $attempt -le 3; $attempt++)",
		"$_.FullyQualifiedErrorId -like \"SOURCE_CODE_ERROR*\"",
		"Add-Type -TypeDefinition $win32Source -ErrorAction Stop",
	}
	for _, marker := range markers {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows runtime should retry transient Add-Type compilation failures; missing %q", marker)
		}
	}
}

func TestWindowsRuntimeTextLimitSupportsMaxMode(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$DefaultTextLimit = 500") {
		t.Fatal("Windows runtime should define the shared 500 character text limit")
	}
	if !strings.Contains(windowsRuntimeScript, "Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit)") {
		t.Fatal("Windows get_app_state should pass text_limit into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq \"max\"") {
		t.Fatal("Windows runtime should support max text limit mode")
	}
	if !strings.Contains(windowsRuntimeScript, "([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth)") {
		t.Fatal("Windows get_app_state should pass tree budget into snapshot rendering")
	}
	if !strings.Contains(windowsRuntimeScript, "$maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }") {
		t.Fatal("Windows selected text should use full UIA text only in max text mode")
	}
}

func TestWindowsRuntimeTreeBudgetDefaultsMatchMacOS(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxNodeCount = 1200") {
		t.Fatal("Windows runtime should default to the shared 1200 node tree budget")
	}
	if !strings.Contains(windowsRuntimeScript, "$AccessibilityTreeMaxDepth = 64") {
		t.Fatal("Windows runtime should default to the shared 64 level tree depth")
	}
	if !strings.Contains(windowsRuntimeScript, "$script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth") {
		t.Fatal("Windows runtime should use shared tree budget constants while rendering")
	}
}

func TestSnapshotRendersExactFocusedElementIdentity(t *testing.T) {
	snapshot := &appSnapshot{
		App: appDescriptor{Name: "DingTalk", PID: 42},
		FocusedElement: &elementRecord{
			Index:                17,
			RuntimeID:            []int{42, 17},
			AutomationID:         "contact-search",
			Name:                 "搜索",
			LocalizedControlType: "编辑",
			HasKeyboardFocus:     true,
		},
	}

	text := snapshot.renderedText()
	for _, marker := range []string{"FocusedElement: index=17", "runtimeId=[42 17]", `automationId="contact-search"`, `name="搜索"`} {
		if !strings.Contains(text, marker) {
			t.Fatalf("rendered snapshot should expose exact focused element identity; missing %q in %q", marker, text)
		}
	}
}

func TestWindowsRuntimeUIAFocusAndSetValueAreVerified(t *testing.T) {
	markers := []string{
		`$names.Add("SetFocus")`,
		"function Set-ElementFocusVerified",
		"Same-RuntimeId @($focused.GetRuntimeId()) @($element.GetRuntimeId())",
		"focusedElement = $focusedElement",
		"function Set-ElementValueVerified",
		`throw "value_not_applied`,
		`throw "value_verification_unknown`,
	}
	for _, marker := range markers {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows UIA semantic action loop missing %q", marker)
		}
	}
}

func TestSnapshotRendersCaptureProvenance(t *testing.T) {
	snapshot := &appSnapshot{
		App: appDescriptor{Name: "DingTalk", PID: 42},
		Capture: &captureDescriptor{
			Method:               "windows-graphics-capture",
			Width:                1200,
			Height:               800,
			OcclusionIndependent: true,
			CoordinateSpace:      "physical-screen-pixels",
			DPI:                  192,
			WindowDPI:            96,
			ScaleFactor:          2,
			DPIAwareness:         "per-monitor-v2",
		},
	}
	text := snapshot.renderedText()
	for _, marker := range []string{"Capture: method=windows-graphics-capture", "size=1200x800", "occlusionIndependent=true", "coordinateSpace=physical-screen-pixels", "dpi=192", "windowDpi=96", "scale=2.00", "dpiAwareness=per-monitor-v2"} {
		if !strings.Contains(text, marker) {
			t.Fatalf("rendered snapshot should expose capture provenance; missing %q in %q", marker, text)
		}
	}
}

func TestWindowsRuntimeUsesPhysicalCoordinateMappingAndMinimizedRecovery(t *testing.T) {
	markers := []string{
		"EnablePerMonitorV2DpiAwareness",
		"GetDpiForWindow",
		"GetEffectiveMonitorDpi",
		`coordinateSpace = "physical-screen-pixels"`,
		"function Convert-ScreenshotPoint",
		"coordinate_out_of_bounds",
		"stale_screenshot(window_bounds_changed",
		"window_minimized_activate_window_required",
		"isMinimized = [OCUWin32]::IsIconic($hwnd)",
	}
	for _, marker := range markers {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows DPI/minimized contract missing %q", marker)
		}
	}
}

func TestWindowsRuntimeUsesGraphicsCaptureBeforeDiagnosticFallbacks(t *testing.T) {
	runtimeMarkers := []string{
		`Assembly]::LoadFrom($captureHelperPath)`,
		"[OCUWindowsGraphicsCapture]::CaptureWindow",
		`New-CaptureDescriptor "windows-graphics-capture"`,
		"PrintWindow",
		"PW_RENDERFULLCONTENT",
		`New-CaptureDescriptor "print-window"`,
		"CopyFromScreen",
		`New-CaptureDescriptor "screen-copy-fallback"`,
		"capture = $capture.descriptor",
	}
	for _, marker := range runtimeMarkers {
		if !strings.Contains(windowsRuntimeScript, marker) {
			t.Fatalf("Windows capture pipeline missing %q", marker)
		}
	}

	helperSource, err := os.ReadFile("capture_helper.cs")
	if err != nil {
		t.Fatalf("read Windows capture helper source: %v", err)
	}
	for _, marker := range []string{"CreateForWindow", "CreateFreeThreaded", "CreateCopyFromSurfaceAsync", "BitmapEncoder.PngEncoderId"} {
		if !strings.Contains(string(helperSource), marker) {
			t.Fatalf("Windows capture helper missing %q", marker)
		}
	}
	if len(windowsCaptureHelper) == 0 {
		t.Fatal("compiled Windows capture helper must be embedded into the runtime")
	}
}

func TestControlActionShowsVisualIndicatorBeforePowerShell(t *testing.T) {
	service := newService()
	var order []string
	service.showIndicator = func(request psRequest) {
		order = append(order, "indicator:"+request.Tool)
	}
	service.runPS = func(request psRequest) (*psResponse, error) {
		order = append(order, "powershell:"+request.Tool)
		return &psResponse{
			OK: true,
			Snapshot: &appSnapshot{
				App:           appDescriptor{Name: "notepad", PID: 42},
				ObservationID: "obs-after-click",
				ScreenshotID:  "shot-after-click",
			},
		}, nil
	}

	_, result := service.refreshSnapshot("notepad", psRequest{Tool: "click", App: "notepad"})
	if result.IsError {
		t.Fatalf("refreshSnapshot failed: %#v", result)
	}
	if got, want := strings.Join(order, ","), "indicator:click,powershell:click"; got != want {
		t.Fatalf("control action order = %q, want %q", got, want)
	}
}

func TestWindowsIndicatorIsTopmostClickThroughAndTracksCursor(t *testing.T) {
	markers := []string{
		"DeepSeek 正在控制电脑",
		"WS_EX_TRANSPARENT",
		"WS_EX_NOACTIVATE",
		"HTTRANSPARENT",
		"TopMost = $true",
		"GetCursorPos",
		"SetProcessDpiAwarenessContext",
		"OwnerProcessId",
	}
	for _, marker := range markers {
		if !strings.Contains(windowsIndicatorScript, marker) {
			t.Fatalf("Windows control indicator must be visible without stealing input; missing %q", marker)
		}
	}
}

func TestWindowsMouseActionsAnimateTheSystemCursor(t *testing.T) {
	if !strings.Contains(windowsRuntimeScript, "MoveCursorSmoothly") {
		t.Fatal("Windows mouse actions should animate the system cursor so automated control is obvious")
	}
}

func findToolDefinition(t *testing.T, name string) toolDefinition {
	t.Helper()
	for _, tool := range toolDefinitions() {
		if tool.Name == name {
			return tool
		}
	}
	t.Fatalf("missing tool definition %q", name)
	return toolDefinition{}
}

func floatPtr(value float64) *float64 {
	return &value
}
