package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var version = "0.3.1"

var clickMethodValues = []string{"auto", "accessibility", "app_post", "sky_click", "global"}

//go:embed runtime.ps1
var windowsRuntimeScript string

const serverInstructions = "Computer Use tools let you interact with Windows apps by performing UI actions.\n\nFor the window-level v2 flow, call `list_windows`, resolve exactly one target with `get_window`, call `activate_window` when foreground input is required, and observe it with `get_window_state`. The legacy `get_app_state` tool remains a compatibility adapter for app-name workflows.\n\nPrefer element-targeted interactions over coordinate clicks when an index for the targeted element is available. Observe again after every action and never reuse a WindowRef after `stale_window`. Window-scoped v2 actions verify the exact foreground HWND and use UI Automation or SendInput; coordinate actions reject non-target occlusion. Legacy app-name actions retain their best-effort window-message fallback. The Windows runtime does not auto-launch apps or enable legacy UIA focus/text fallbacks by default; these remain explicit runtime capabilities."

type toolDefinition struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Annotations map[string]any `json:"annotations,omitempty"`
	InputSchema map[string]any `json:"inputSchema"`
}

type contentItem struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

type toolCallResult struct {
	Content []contentItem `json:"content"`
	IsError bool          `json:"isError"`
}

func textResult(text string, isError bool) toolCallResult {
	return toolCallResult{Content: []contentItem{{Type: "text", Text: text}}, IsError: isError}
}

type appDescriptor struct {
	Name             string `json:"name"`
	BundleIdentifier string `json:"bundleIdentifier,omitempty"`
	PID              int    `json:"pid"`
}

type windowRef struct {
	AppID          string `json:"appId"`
	PID            int    `json:"pid"`
	HWND           string `json:"hwnd"`
	Title          string `json:"title,omitempty"`
	Generation     string `json:"generation"`
	OwnerHWND      string `json:"ownerHwnd,omitempty"`
	IsModal        bool   `json:"isModal,omitempty"`
	IsForeground   bool   `json:"isForeground,omitempty"`
	ProcessStarted string `json:"processStarted,omitempty"`
}

type frame struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
	Width  float64 `json:"width"`
	Height float64 `json:"height"`
}

func (f frame) renderedLocalFrame() string {
	return fmt.Sprintf("{{x: %.0f, y: %.0f, width: %.0f, height: %.0f}}", f.X, f.Y, f.Width, f.Height)
}

type elementRecord struct {
	Index                int      `json:"index"`
	RuntimeID            []int    `json:"runtimeId,omitempty"`
	AutomationID         string   `json:"automationId,omitempty"`
	Name                 string   `json:"name,omitempty"`
	ControlType          string   `json:"controlType,omitempty"`
	LocalizedControlType string   `json:"localizedControlType,omitempty"`
	ClassName            string   `json:"className,omitempty"`
	Value                string   `json:"value,omitempty"`
	NativeWindowHandle   int64    `json:"nativeWindowHandle,omitempty"`
	Frame                *frame   `json:"frame,omitempty"`
	Actions              []string `json:"actions,omitempty"`
}

type appSnapshot struct {
	App                 appDescriptor   `json:"app"`
	Window              *windowRef      `json:"window,omitempty"`
	ObservationID       string          `json:"observationId,omitempty"`
	ScreenshotID        string          `json:"screenshotId,omitempty"`
	ActionStatus        string          `json:"actionStatus,omitempty"`
	WindowTitle         string          `json:"windowTitle,omitempty"`
	WindowBounds        *frame          `json:"windowBounds,omitempty"`
	ScreenshotPNGBase64 string          `json:"screenshotPngBase64,omitempty"`
	TreeLines           []string        `json:"treeLines,omitempty"`
	FocusedSummary      string          `json:"focusedSummary,omitempty"`
	SelectedText        string          `json:"selectedText,omitempty"`
	Elements            []elementRecord `json:"elements,omitempty"`
}

func (s *appSnapshot) renderedText() string {
	if s == nil {
		return ""
	}
	appRef := s.App.BundleIdentifier
	if appRef == "" {
		appRef = s.App.Name
	}
	title := s.WindowTitle
	if strings.TrimSpace(title) == "" {
		title = s.App.Name
	}

	lines := []string{
		fmt.Sprintf("App=%s (pid %d)", appRef, s.App.PID),
		fmt.Sprintf("Window: %q, App: %s.", title, s.App.Name),
	}
	if s.Window != nil {
		windowJSON, _ := json.Marshal(s.Window)
		lines = append(lines, fmt.Sprintf("WindowRef: %s", windowJSON))
	}
	if s.ObservationID != "" {
		lines = append(lines, fmt.Sprintf("ObservationID: %s", s.ObservationID))
	}
	if s.ScreenshotID != "" {
		lines = append(lines, fmt.Sprintf("ScreenshotID: %s", s.ScreenshotID))
	}
	if s.ActionStatus != "" {
		lines = append(lines, fmt.Sprintf("ActionStatus: %s", s.ActionStatus))
	}
	lines = append(lines, s.TreeLines...)
	if strings.TrimSpace(s.SelectedText) != "" {
		lines = append(lines, "", fmt.Sprintf("Selected text: [%s]", s.SelectedText))
	} else if strings.TrimSpace(s.FocusedSummary) != "" {
		lines = append(lines, "", fmt.Sprintf("The focused UI element is %s.", s.FocusedSummary))
	}
	return strings.Join(lines, "\n")
}

func (s *appSnapshot) result() toolCallResult {
	result := toolCallResult{
		Content: []contentItem{{Type: "text", Text: s.renderedText()}},
	}
	if s != nil && s.ScreenshotPNGBase64 != "" {
		result.Content = append(result.Content, contentItem{
			Type:     "image",
			Data:     s.ScreenshotPNGBase64,
			MimeType: "image/png",
		})
	}
	return result
}

type psRequest struct {
	Tool          string         `json:"tool"`
	App           string         `json:"app,omitempty"`
	Title         string         `json:"title,omitempty"`
	Window        *windowRef     `json:"window,omitempty"`
	Element       *elementRecord `json:"element,omitempty"`
	X             *float64       `json:"x,omitempty"`
	Y             *float64       `json:"y,omitempty"`
	FromX         *float64       `json:"from_x,omitempty"`
	FromY         *float64       `json:"from_y,omitempty"`
	ToX           *float64       `json:"to_x,omitempty"`
	ToY           *float64       `json:"to_y,omitempty"`
	ClickCount    int            `json:"click_count,omitempty"`
	MouseButton   string         `json:"mouse_button,omitempty"`
	ClickMethod   string         `json:"click_method,omitempty"`
	Action        string         `json:"action,omitempty"`
	Direction     string         `json:"direction,omitempty"`
	Pages         float64        `json:"pages,omitempty"`
	Text          string         `json:"text,omitempty"`
	Key           string         `json:"key,omitempty"`
	Value         string         `json:"value,omitempty"`
	ObservationID string         `json:"observation_id,omitempty"`
	ScreenshotID  string         `json:"screenshot_id,omitempty"`
	WindowBounds  *frame         `json:"windowBounds,omitempty"`
	TextLimit     any            `json:"text_limit,omitempty"`
	MaxTreeNodes  int            `json:"max_tree_nodes,omitempty"`
	MaxTreeDepth  int            `json:"max_tree_depth,omitempty"`
}

type textLimit struct {
	max   bool
	count int
}

func (limit textLimit) runtimeValue() any {
	if limit.max {
		return "max"
	}
	return limit.count
}

type psResponse struct {
	OK       bool         `json:"ok"`
	Text     string       `json:"text,omitempty"`
	Error    string       `json:"error,omitempty"`
	Snapshot *appSnapshot `json:"snapshot,omitempty"`
	Window   *windowRef   `json:"window,omitempty"`
	Windows  []windowRef  `json:"windows,omitempty"`
	Status   string       `json:"status,omitempty"`
}

type service struct {
	snapshots map[string]*appSnapshot
	runPS     func(psRequest) (*psResponse, error)
}

type actionTarget struct {
	App           string
	Window        *windowRef
	ObservationID string
	ScreenshotID  string
}

type actionSnapshotRequirement int

const (
	actionSnapshotNone actionSnapshotRequirement = iota
	actionSnapshotObservation
	actionSnapshotScreenshot
)

type resolvedActionTarget struct {
	app      string
	window   *windowRef
	snapshot *appSnapshot
	cacheKey string
}

func newService() *service {
	return &service{
		snapshots: map[string]*appSnapshot{},
		runPS:     runPowerShell,
	}
}

func (s *service) callTool(name string, args map[string]any) toolCallResult {
	switch name {
	case "list_apps":
		return s.listApps()
	case "list_windows":
		return s.listWindows(requiredString(args, "app"))
	case "get_window":
		return s.getWindow(requiredString(args, "app"), optionalString(args, "title"))
	case "launch_app":
		return s.launchApp(requiredString(args, "app"))
	case "activate_window":
		window, err := requiredWindowRef(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.activateWindow(&window)
	case "get_window_state":
		window, err := requiredWindowRef(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		maxTreeNodes, err := optionalPositiveInt(args, "max_tree_nodes")
		if err != nil {
			return textResult(err.Error(), true)
		}
		maxTreeDepth, err := optionalPositiveInt(args, "max_tree_depth")
		if err != nil {
			return textResult(err.Error(), true)
		}
		textLimit, err := optionalTextLimit(args, "text_limit")
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.getWindowState(window, textLimit, maxTreeNodes, maxTreeDepth)
	case "get_app_state":
		maxTreeNodes, err := optionalPositiveInt(args, "max_tree_nodes")
		if err != nil {
			return textResult(err.Error(), true)
		}
		maxTreeDepth, err := optionalPositiveInt(args, "max_tree_depth")
		if err != nil {
			return textResult(err.Error(), true)
		}
		textLimit, err := optionalTextLimit(args, "text_limit")
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.getAppState(requiredString(args, "app"), textLimit, maxTreeNodes, maxTreeDepth)
	case "click":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		clickMethod, err := parseClickMethod(optionalString(args, "click_method"))
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.click(
			target,
			optionalElementIndex(args),
			optionalFloat(args, "x"),
			optionalFloat(args, "y"),
			intValue(optionalFloat(args, "click_count"), 1),
			defaultString(optionalString(args, "mouse_button"), "left"),
			clickMethod,
		)
	case "perform_secondary_action":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.performSecondaryAction(
			target,
			requiredElementIndex(args),
			requiredString(args, "action"),
		)
	case "scroll":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.scroll(
			target,
			requiredString(args, "direction"),
			requiredElementIndex(args),
			floatValue(optionalFloat(args, "pages"), 1),
		)
	case "drag":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.drag(
			target,
			requiredFloat(args, "from_x"),
			requiredFloat(args, "from_y"),
			requiredFloat(args, "to_x"),
			requiredFloat(args, "to_y"),
		)
	case "type_text":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.typeText(target, requiredString(args, "text"))
	case "press_key":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.pressKey(target, requiredString(args, "key"))
	case "set_value":
		target, err := requiredActionTarget(args)
		if err != nil {
			return textResult(err.Error(), true)
		}
		return s.setValue(target, requiredElementIndex(args), requiredString(args, "value"))
	default:
		return textResult(fmt.Sprintf("unsupportedTool(%q)", name), true)
	}
}

func (s *service) listApps() toolCallResult {
	response, err := s.runPS(psRequest{Tool: "list_apps"})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(responseErrorText(response), true)
	}
	if strings.TrimSpace(response.Text) == "" {
		response.Text = "No running top-level apps are visible to this Windows runtime."
	}
	return textResult(response.Text, false)
}

func (s *service) listWindows(app string) toolCallResult {
	response, err := s.runPS(psRequest{Tool: "list_windows", App: app})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(responseErrorText(response), true)
	}
	if strings.TrimSpace(response.Text) == "" {
		response.Text = "No running windows are visible to this Windows runtime."
	}
	return textResult(response.Text, false)
}

func (s *service) getWindow(app, title string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	response, err := s.runPS(psRequest{Tool: "get_window", App: app, Title: title})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(responseErrorText(response), true)
	}
	if response.Window == nil {
		return textResult("Windows runtime did not return a window reference.", true)
	}
	text, err := json.Marshal(response.Window)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return textResult(string(text), false)
}

func (s *service) launchApp(app string) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	response, err := s.runPS(psRequest{Tool: "launch_app", App: app})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(responseErrorText(response), true)
	}
	if response.Window == nil {
		return textResult("Windows runtime did not return the launched window reference.", true)
	}
	text, err := json.Marshal(response.Window)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return textResult(string(text), false)
}

func (s *service) activateWindow(window *windowRef) toolCallResult {
	if window == nil {
		return textResult("Missing required argument: window", true)
	}
	response, err := s.runPS(psRequest{Tool: "activate_window", Window: window})
	if err != nil {
		return textResult(err.Error(), true)
	}
	if !response.OK {
		return textResult(responseErrorText(response), true)
	}
	if response.Window == nil {
		return textResult("Windows runtime did not return the activated window reference.", true)
	}
	payload := map[string]any{"status": defaultString(response.Status, "applied"), "window": response.Window}
	text, err := json.Marshal(payload)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return textResult(string(text), false)
}

func (s *service) getWindowState(window windowRef, textLimit *textLimit, maxTreeNodes, maxTreeDepth *int) toolCallResult {
	request := psRequest{Tool: "get_window_state", Window: &window}
	if textLimit != nil {
		request.TextLimit = textLimit.runtimeValue()
	}
	if maxTreeNodes != nil {
		request.MaxTreeNodes = *maxTreeNodes
	}
	if maxTreeDepth != nil {
		request.MaxTreeDepth = *maxTreeDepth
	}
	snapshot, result := s.refreshSnapshot(snapshotWindowKey(window), request)
	if result.IsError {
		return result
	}
	return snapshot.result()
}

func (s *service) getAppState(app string, textLimit *textLimit, maxTreeNodes, maxTreeDepth *int) toolCallResult {
	if app == "" {
		return textResult("Missing required argument: app", true)
	}
	request := psRequest{Tool: "get_app_state", App: app}
	if textLimit != nil {
		request.TextLimit = textLimit.runtimeValue()
	}
	if maxTreeNodes != nil {
		request.MaxTreeNodes = *maxTreeNodes
	}
	if maxTreeDepth != nil {
		request.MaxTreeDepth = *maxTreeDepth
	}
	snapshot, result := s.refreshSnapshot(snapshotQueryKey(app), request)
	if result.IsError {
		return result
	}
	return snapshot.result()
}

func (s *service) click(target actionTarget, elementIndex string, x, y *float64, clickCount int, mouseButton, clickMethod string) toolCallResult {
	if elementIndex == "" && (x == nil || y == nil) {
		return textResult("click requires either element_index or x/y", true)
	}
	if clickMethod == "accessibility" && elementIndex == "" {
		return textResult("click_method 'accessibility' requires element_index", true)
	}
	if clickMethod == "global" {
		return textResult("click_method 'global' is not supported on Windows", true)
	}
	if clickMethod == "sky_click" {
		return textResult("click_method 'sky_click' is not supported on Windows", true)
	}
	requirement := actionSnapshotScreenshot
	if elementIndex != "" {
		requirement = actionSnapshotObservation
	}
	resolved, err := s.resolveActionTarget(target, requirement)
	if err != nil {
		return textResult(err.Error(), true)
	}
	snapshot := resolved.snapshot
	request := psRequest{
		Tool:          "click",
		App:           resolved.app,
		Window:        resolved.window,
		X:             x,
		Y:             y,
		ClickCount:    clickCount,
		MouseButton:   mouseButton,
		ClickMethod:   clickMethod,
		ObservationID: target.ObservationID,
		ScreenshotID:  target.ScreenshotID,
		WindowBounds:  snapshot.WindowBounds,
	}
	if elementIndex != "" {
		record, err := lookupElement(snapshot, elementIndex)
		if err != nil {
			return textResult(err.Error(), true)
		}
		request.Element = record
	}
	return s.actionResult(resolved.cacheKey, request)
}

func (s *service) performSecondaryAction(target actionTarget, elementIndex, action string) toolCallResult {
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	if action == "" {
		return textResult("Missing required argument: action", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotObservation)
	if err != nil {
		return textResult(err.Error(), true)
	}
	record, err := lookupElement(resolved.snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:          "perform_secondary_action",
		App:           resolved.app,
		Window:        resolved.window,
		Element:       record,
		Action:        action,
		ObservationID: target.ObservationID,
	})
}

func (s *service) scroll(target actionTarget, direction, elementIndex string, pages float64) toolCallResult {
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	normalized := strings.ToLower(direction)
	if normalized != "up" && normalized != "down" && normalized != "left" && normalized != "right" {
		return textResult("Invalid scroll direction: "+direction, true)
	}
	if pages <= 0 {
		return textResult("pages must be > 0", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotObservation)
	if err != nil {
		return textResult(err.Error(), true)
	}
	record, err := lookupElement(resolved.snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:          "scroll",
		App:           resolved.app,
		Window:        resolved.window,
		Element:       record,
		Direction:     normalized,
		Pages:         pages,
		ObservationID: target.ObservationID,
	})
}

func (s *service) drag(target actionTarget, fromX, fromY, toX, toY *float64) toolCallResult {
	if fromX == nil {
		return textResult("Missing required argument: from_x", true)
	}
	if fromY == nil {
		return textResult("Missing required argument: from_y", true)
	}
	if toX == nil {
		return textResult("Missing required argument: to_x", true)
	}
	if toY == nil {
		return textResult("Missing required argument: to_y", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotScreenshot)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:         "drag",
		App:          resolved.app,
		Window:       resolved.window,
		FromX:        fromX,
		FromY:        fromY,
		ToX:          toX,
		ToY:          toY,
		ScreenshotID: target.ScreenshotID,
		WindowBounds: resolved.snapshot.WindowBounds,
	})
}

func (s *service) typeText(target actionTarget, text string) toolCallResult {
	if text == "" {
		return textResult("Missing required argument: text", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotObservation)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:          "type_text",
		App:           resolved.app,
		Window:        resolved.window,
		Text:          text,
		ObservationID: target.ObservationID,
	})
}

func (s *service) pressKey(target actionTarget, key string) toolCallResult {
	if key == "" {
		return textResult("Missing required argument: key", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotObservation)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:          "press_key",
		App:           resolved.app,
		Window:        resolved.window,
		Key:           key,
		ObservationID: target.ObservationID,
	})
}

func (s *service) setValue(target actionTarget, elementIndex, value string) toolCallResult {
	if elementIndex == "" {
		return textResult("Missing required argument: element_index", true)
	}
	resolved, err := s.resolveActionTarget(target, actionSnapshotObservation)
	if err != nil {
		return textResult(err.Error(), true)
	}
	record, err := lookupElement(resolved.snapshot, elementIndex)
	if err != nil {
		return textResult(err.Error(), true)
	}
	return s.actionResult(resolved.cacheKey, psRequest{
		Tool:          "set_value",
		App:           resolved.app,
		Window:        resolved.window,
		Element:       record,
		Value:         value,
		ObservationID: target.ObservationID,
	})
}

func (s *service) actionResult(cacheKey string, request psRequest) toolCallResult {
	snapshot, result := s.refreshSnapshot(cacheKey, request)
	if result.IsError {
		return result
	}
	return snapshot.result()
}

func (s *service) currentSnapshot(app string) *appSnapshot {
	return s.snapshots[snapshotQueryKey(app)]
}

func (s *service) refreshSnapshot(cacheKey string, request psRequest) (*appSnapshot, toolCallResult) {
	response, err := s.runPS(request)
	if err != nil {
		return nil, textResult(err.Error(), true)
	}
	if !response.OK {
		return nil, textResult(responseErrorText(response), true)
	}
	if response.Snapshot == nil {
		return nil, textResult("Windows runtime did not return an app snapshot.", true)
	}
	if response.Snapshot.ObservationID != "" && response.Snapshot.ScreenshotID == "" {
		response.Snapshot.ScreenshotID = response.Snapshot.ObservationID
	}
	if isMutatingTool(request.Tool) {
		response.Snapshot.ActionStatus = defaultString(response.Status, "applied")
	}
	s.rememberSnapshot(cacheKey, response.Snapshot)
	return response.Snapshot, toolCallResult{}
}

func (s *service) rememberSnapshot(cacheKey string, snapshot *appSnapshot) {
	keys := []string{cacheKey, snapshotQueryKey(snapshot.App.Name), snapshotQueryKey(snapshot.App.BundleIdentifier), snapshotPIDKey(snapshot.App.PID)}
	if snapshot.Window != nil {
		keys = append(keys, snapshotWindowKey(*snapshot.Window), snapshotHWNDKey(snapshot.Window.HWND))
	}
	for _, key := range keys {
		if key != "" {
			s.snapshots[key] = snapshot
		}
	}
}

func (s *service) resolveActionTarget(target actionTarget, requirement actionSnapshotRequirement) (*resolvedActionTarget, error) {
	if target.Window != nil {
		snapshot := s.snapshots[snapshotWindowKey(*target.Window)]
		if snapshot == nil || snapshot.Window == nil || !sameWindowIdentity(snapshot.Window, target.Window) {
			return nil, fmt.Errorf("No window state is available for hwnd %s. Run get_window_state before action tools.", target.Window.HWND)
		}
		switch requirement {
		case actionSnapshotObservation:
			if target.ObservationID == "" {
				return nil, errors.New("Missing required argument: observation_id")
			}
			if snapshot.ObservationID != target.ObservationID {
				return nil, fmt.Errorf("observation_id does not match the latest snapshot for hwnd %s. Run get_window_state again before action tools.", target.Window.HWND)
			}
		case actionSnapshotScreenshot:
			if target.ScreenshotID == "" {
				return nil, errors.New("Missing required argument: screenshot_id")
			}
			if snapshot.ScreenshotID != target.ScreenshotID {
				return nil, fmt.Errorf("screenshot_id does not match the latest snapshot for hwnd %s. Run get_window_state again before action tools.", target.Window.HWND)
			}
		}
		return &resolvedActionTarget{
			app:      defaultString(target.App, snapshot.App.Name),
			window:   snapshot.Window,
			snapshot: snapshot,
			cacheKey: snapshotWindowKey(*snapshot.Window),
		}, nil
	}
	if target.App == "" {
		return nil, errors.New("One of app or window is required")
	}
	snapshot := s.currentSnapshot(target.App)
	if snapshot == nil {
		return nil, fmt.Errorf("No app state is available for %s. Run get_app_state before action tools.", target.App)
	}
	window := snapshot.Window
	cacheKey := snapshotQueryKey(target.App)
	if window != nil {
		cacheKey = snapshotWindowKey(*window)
	}
	if requirement == actionSnapshotObservation && target.ObservationID != "" && snapshot.ObservationID != target.ObservationID {
		return nil, fmt.Errorf("observation_id does not match the latest snapshot for %s. Run get_app_state again before action tools.", target.App)
	}
	if requirement == actionSnapshotScreenshot && target.ScreenshotID != "" && snapshot.ScreenshotID != target.ScreenshotID {
		return nil, fmt.Errorf("screenshot_id does not match the latest snapshot for %s. Run get_app_state again before action tools.", target.App)
	}
	return &resolvedActionTarget{
		app:      target.App,
		window:   window,
		snapshot: snapshot,
		cacheKey: cacheKey,
	}, nil
}

func sameWindowIdentity(left, right *windowRef) bool {
	if left == nil || right == nil {
		return false
	}
	return left.AppID == right.AppID && left.PID == right.PID && left.HWND == right.HWND && left.Generation == right.Generation
}

func snapshotQueryKey(query string) string {
	return normalizedSnapshotKey("query", query)
}

func snapshotPIDKey(pid int) string {
	return normalizedSnapshotKey("pid", strconv.Itoa(pid))
}

func snapshotHWNDKey(hwnd string) string {
	return normalizedSnapshotKey("hwnd", hwnd)
}

func snapshotWindowKey(window windowRef) string {
	return normalizedSnapshotKey("window", window.AppID, strconv.Itoa(window.PID), window.HWND, window.Generation)
}

func normalizedSnapshotKey(parts ...string) string {
	normalized := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.ToLower(strings.TrimSpace(part))
		if part != "" {
			normalized = append(normalized, part)
		}
	}
	return strings.Join(normalized, "|")
}

func isMutatingTool(name string) bool {
	switch name {
	case "click", "drag", "perform_secondary_action", "press_key", "scroll", "set_value", "type_text":
		return true
	default:
		return false
	}
}

func responseErrorText(response *psResponse) string {
	if response == nil {
		return "Windows runtime failed."
	}
	if response.Status != "" {
		return fmt.Sprintf("%s [status=%s]", response.Error, response.Status)
	}
	return response.Error
}

func lookupElement(snapshot *appSnapshot, elementIndex string) (*elementRecord, error) {
	index, err := strconv.Atoi(elementIndex)
	if err != nil {
		return nil, fmt.Errorf("unknown element_index %q", elementIndex)
	}
	for _, record := range snapshot.Elements {
		if record.Index == index {
			copy := record
			return &copy, nil
		}
	}
	return nil, fmt.Errorf("unknown element_index %q", elementIndex)
}

func runPowerShell(request psRequest) (*psResponse, error) {
	if runtime.GOOS != "windows" {
		return nil, errors.New("Windows Computer Use runtime requires powershell.exe on Windows")
	}

	tempDir, err := os.MkdirTemp("", "open-computer-use-windows-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tempDir)

	scriptPath := filepath.Join(tempDir, "runtime.ps1")
	operationPath := filepath.Join(tempDir, "operation.json")
	if err := os.WriteFile(scriptPath, []byte(windowsRuntimeScript), 0o600); err != nil {
		return nil, err
	}
	operationData, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(operationPath, operationData, 0o600); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, operationPath)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		if isMutatingTool(request.Tool) {
			return &psResponse{OK: false, Error: "Windows runtime timed out after 30s", Status: "unknown"}, nil
		}
		return nil, errors.New("Windows runtime timed out after 30s")
	}
	if err != nil {
		text := strings.TrimSpace(string(output))
		if text == "" {
			text = err.Error()
		}
		if isMutatingTool(request.Tool) {
			return &psResponse{OK: false, Error: "Windows runtime failed: " + text, Status: "unknown"}, nil
		}
		return nil, fmt.Errorf("Windows runtime failed: %s", text)
	}

	var response psResponse
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, fmt.Errorf("Windows runtime returned invalid JSON: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return &response, nil
}

func requiredString(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return strings.TrimSpace(value)
}

func optionalString(args map[string]any, key string) string {
	value, _ := args[key].(string)
	return value
}

func requiredElementIndex(args map[string]any) string {
	return strings.TrimSpace(optionalElementIndex(args))
}

func requiredWindowRef(args map[string]any) (windowRef, error) {
	value, ok := args["window"].(map[string]any)
	if !ok || value == nil {
		return windowRef{}, errors.New("Missing required argument: window")
	}
	payload, err := json.Marshal(value)
	if err != nil {
		return windowRef{}, errors.New("Invalid window reference")
	}
	var window windowRef
	if err := json.Unmarshal(payload, &window); err != nil {
		return windowRef{}, errors.New("Invalid window reference")
	}
	window.AppID = strings.TrimSpace(window.AppID)
	window.HWND = strings.TrimSpace(window.HWND)
	window.Generation = strings.TrimSpace(window.Generation)
	if window.AppID == "" || window.PID <= 0 || window.HWND == "" || window.Generation == "" {
		return windowRef{}, errors.New("WindowRef requires appId, pid, hwnd, and generation")
	}
	if _, err := strconv.ParseInt(window.HWND, 10, 64); err != nil {
		return windowRef{}, errors.New("WindowRef hwnd must be a decimal string")
	}
	return window, nil
}

func optionalWindowRef(args map[string]any) (*windowRef, error) {
	if _, ok := args["window"]; !ok {
		return nil, nil
	}
	window, err := requiredWindowRef(args)
	if err != nil {
		return nil, err
	}
	return &window, nil
}

func requiredActionTarget(args map[string]any) (actionTarget, error) {
	window, err := optionalWindowRef(args)
	if err != nil {
		return actionTarget{}, err
	}
	app := requiredString(args, "app")
	if window == nil && app == "" {
		return actionTarget{}, errors.New("One of app or window is required")
	}
	return actionTarget{
		App:           app,
		Window:        window,
		ObservationID: requiredString(args, "observation_id"),
		ScreenshotID:  requiredString(args, "screenshot_id"),
	}, nil
}

func optionalElementIndex(args map[string]any) string {
	return elementIndexString(args["element_index"])
}

func elementIndexString(value any) string {
	switch value := value.(type) {
	case string:
		return value
	case json.Number:
		if integer, err := value.Int64(); err == nil {
			return strconv.FormatInt(integer, 10)
		}
		if float, err := value.Float64(); err == nil {
			return integerElementIndexFloat(float)
		}
	case float64:
		return integerElementIndexFloat(value)
	case int:
		return strconv.Itoa(value)
	case int64:
		return strconv.FormatInt(value, 10)
	}
	return ""
}

func integerElementIndexFloat(value float64) string {
	if math.IsNaN(value) || math.IsInf(value, 0) || math.Trunc(value) != value {
		return ""
	}
	return strconv.FormatInt(int64(value), 10)
}

func requiredFloat(args map[string]any, key string) *float64 {
	return optionalFloat(args, key)
}

func optionalFloat(args map[string]any, key string) *float64 {
	switch value := args[key].(type) {
	case float64:
		return &value
	case int:
		float := float64(value)
		return &float
	case json.Number:
		float, err := value.Float64()
		if err == nil {
			return &float
		}
	}
	return nil
}

func optionalTextLimit(args map[string]any, key string) (*textLimit, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return textLimitFromValue(value, key)
}

func textLimitFromValue(value any, key string) (*textLimit, error) {
	if stringValue, ok := value.(string); ok {
		if strings.EqualFold(stringValue, "max") {
			return &textLimit{max: true}, nil
		}
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	integer, err := positiveIntFromValue(value, key)
	if err != nil {
		return nil, fmt.Errorf("%s must be a positive integer or max", key)
	}
	return &textLimit{count: *integer}, nil
}

func optionalPositiveInt(args map[string]any, key string) (*int, error) {
	value, ok := args[key]
	if !ok {
		return nil, nil
	}
	return positiveIntFromValue(value, key)
}

func positiveIntFromValue(value any, key string) (*int, error) {
	switch typed := value.(type) {
	case int:
		return positiveIntFromInt64(int64(typed), key)
	case float64:
		if !isWholeNumber(typed) {
			return nil, fmt.Errorf("%s must be a positive integer", key)
		}
		return positiveIntFromFloat64(typed, key)
	case json.Number:
		integer, err := typed.Int64()
		if err != nil {
			return nil, fmt.Errorf("%s must be a positive integer", key)
		}
		return positiveIntFromInt64(integer, key)
	default:
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
}

func positiveIntFromFloat64(value float64, key string) (*int, error) {
	if !isWholeNumber(value) || value <= 0 || value > float64(maxInt()) {
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
	integer := int(value)
	return &integer, nil
}

func positiveIntFromInt64(value int64, key string) (*int, error) {
	if value <= 0 || value > int64(maxInt()) {
		return nil, fmt.Errorf("%s must be a positive integer", key)
	}
	integer := int(value)
	return &integer, nil
}

func isWholeNumber(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0) && math.Trunc(value) == value
}

func maxInt() int {
	return int(^uint(0) >> 1)
}

func intValue(value *float64, fallback int) int {
	if value == nil {
		return fallback
	}
	return int(*value)
}

func floatValue(value *float64, fallback float64) float64 {
	if value == nil {
		return fallback
	}
	return *value
}

func defaultString(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func parseClickMethod(value string) (string, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	if normalized == "" {
		return "auto", nil
	}
	for _, candidate := range clickMethodValues {
		if normalized == candidate {
			return normalized, nil
		}
	}
	return "", fmt.Errorf("Invalid click_method %q. Expected one of: %s", value, strings.Join(clickMethodValues, ", "))
}

func toolDefinitions() []toolDefinition {
	return []toolDefinition{
		{
			Name:        "activate_window",
			Description: "Bring one specific top-level window to the foreground and verify that it became the active window. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"window": windowRefProperty("Concrete target window reference returned by list_windows or get_window"),
			}, []string{"window"}),
		},
		{
			Name:        "click",
			Description: "Click an element by index or pixel coordinates from screenshot. Prefer window-level v2 calls with WindowRef plus observation_id or screenshot_id. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"element_index":  stringProperty("Element index to click"),
				"observation_id": stringProperty("Required with window+element_index. Must match the latest snapshot for that WindowRef"),
				"screenshot_id":  stringProperty("Required with window+x/y coordinates. Must match the latest screenshot for that WindowRef"),
				"x":              numberProperty("X coordinate in screenshot pixel coordinates"),
				"y":              numberProperty("Y coordinate in screenshot pixel coordinates"),
				"click_count":    integerProperty("Number of clicks. Defaults to 1"),
				"mouse_button":   enumStringProperty("Mouse button to click. Defaults to left.", []string{"left", "right", "middle"}),
				"click_method":   enumStringProperty("Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. Windows supports app_post through HWND messages and does not currently support sky_click or global.", clickMethodValues),
			}, nil),
		},
		{
			Name:        "drag",
			Description: "Drag from one point to another using pixel coordinates. Prefer window-level v2 calls with WindowRef and screenshot_id. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":           stringProperty("Legacy app name or bundle identifier fallback"),
				"window":        windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"screenshot_id": stringProperty("Required with window. Must match the latest screenshot for that WindowRef"),
				"from_x":        numberProperty("Start X coordinate"),
				"from_y":        numberProperty("Start Y coordinate"),
				"to_x":          numberProperty("End X coordinate"),
				"to_y":          numberProperty("End Y coordinate"),
			}, []string{"from_x", "from_y", "to_x", "to_y"}),
		},
		{
			Name:        "get_window",
			Description: "Resolve exactly one visible top-level window. Multiple matches return ambiguous_window instead of guessing. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":   stringProperty("Exact process name or app id"),
				"title": stringProperty("Optional case-insensitive title substring used to narrow candidates"),
			}, []string{"app"}),
		},
		{
			Name:        "get_window_state",
			Description: "Observe one exact WindowRef and reject it when its identity generation is stale. Returns a screenshot and accessibility tree. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"window":         windowRefProperty("Concrete target window reference returned by list_windows, get_window, or launch_app"),
				"text_limit":     textLimitProperty("Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
				"max_tree_nodes": positiveIntegerProperty("Maximum accessibility tree nodes to render. Defaults to 1200."),
				"max_tree_depth": positiveIntegerProperty("Maximum accessibility tree depth to render. Defaults to 64."),
			}, []string{"window"}),
		},
		{
			Name:        "get_app_state",
			Description: "Get the state of an already running app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("App name or bundle identifier"),
				"text_limit":     textLimitProperty("Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
				"max_tree_nodes": positiveIntegerProperty("Maximum accessibility tree nodes to render. Defaults to 1200."),
				"max_tree_depth": positiveIntegerProperty("Maximum accessibility tree depth to render. Defaults to 64."),
			}, []string{"app"}),
		},
		{
			Name:        "list_apps",
			Description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{}, nil),
		},
		{
			Name:        "list_windows",
			Description: "List visible top-level windows and return stable window references for later calls. This tool is part of plugin `Computer Use`.",
			Annotations: readOnlyAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app": stringProperty("Optional app name or bundle identifier filter"),
			}, nil),
		},
		{
			Name:        "launch_app",
			Description: "Launch an app and return its WindowRef. Requires OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app": stringProperty("Executable name or path to launch"),
			}, []string{"app"}),
		},
		{
			Name:        "perform_secondary_action",
			Description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"element_index":  stringProperty("Element identifier"),
				"observation_id": stringProperty("Required with window. Must match the latest snapshot for that WindowRef"),
				"action":         stringProperty("Secondary accessibility action name"),
			}, []string{"element_index", "action"}),
		},
		{
			Name:        "press_key",
			Description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0). This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"observation_id": stringProperty("Required with window. Must match the latest snapshot for that WindowRef"),
				"key":            stringProperty("Key or key-combination to press"),
			}, []string{"key"}),
		},
		{
			Name:        "scroll",
			Description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"direction":      stringProperty("Scroll direction: up, down, left, or right"),
				"element_index":  stringProperty("Element identifier"),
				"observation_id": stringProperty("Required with window. Must match the latest snapshot for that WindowRef"),
				"pages":          numberProperty("Number of pages to scroll. Fractional values are supported. Defaults to 1"),
			}, []string{"element_index", "direction"}),
		},
		{
			Name:        "set_value",
			Description: "Set the value of a settable accessibility element. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"element_index":  stringProperty("Element identifier"),
				"observation_id": stringProperty("Required with window. Must match the latest snapshot for that WindowRef"),
				"value":          stringProperty("Value to assign"),
			}, []string{"element_index", "value"}),
		},
		{
			Name:        "type_text",
			Description: "Type literal text using keyboard input. This tool is part of plugin `Computer Use`.",
			Annotations: defaultAnnotations(),
			InputSchema: objectSchema(map[string]any{
				"app":            stringProperty("Legacy app name or bundle identifier fallback"),
				"window":         windowRefProperty("Preferred exact target window reference returned by get_window or get_window_state"),
				"observation_id": stringProperty("Required with window. Must match the latest snapshot for that WindowRef"),
				"text":           stringProperty("Literal text to type"),
			}, []string{"text"}),
		},
	}
}

func objectSchema(properties map[string]any, required []string) map[string]any {
	schema := map[string]any{
		"type":                 "object",
		"properties":           properties,
		"additionalProperties": false,
	}
	if len(required) > 0 {
		schema["required"] = required
	}
	return schema
}

func defaultAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "openWorldHint": false}
}

func readOnlyAnnotations() map[string]any {
	return map[string]any{"destructiveHint": false, "idempotentHint": true, "openWorldHint": false, "readOnlyHint": true}
}

func stringProperty(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

func windowRefProperty(description string) map[string]any {
	return map[string]any{
		"type":        "object",
		"description": description,
		"properties": map[string]any{
			"appId":          stringProperty("Owning process name used as the app id"),
			"pid":            integerProperty("Owning process id"),
			"hwnd":           stringProperty("Top-level window handle encoded as a decimal string"),
			"title":          stringProperty("Best-effort current window title"),
			"generation":     stringProperty("Opaque generation string for stale-window detection"),
			"ownerHwnd":      stringProperty("Optional owner window handle encoded as a decimal string"),
			"isModal":        map[string]any{"type": "boolean", "description": "Whether the top-level window has an owner"},
			"isForeground":   map[string]any{"type": "boolean", "description": "Whether the window was foreground when observed"},
			"processStarted": stringProperty("UTC process start time used to derive generation"),
		},
		"required":             []string{"appId", "pid", "hwnd", "generation"},
		"additionalProperties": false,
	}
}

func enumStringProperty(description string, values []string) map[string]any {
	property := stringProperty(description)
	property["enum"] = values
	return property
}

func numberProperty(description string) map[string]any {
	return map[string]any{"type": "number", "description": description}
}

func integerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "description": description}
}

func positiveIntegerProperty(description string) map[string]any {
	return map[string]any{"type": "integer", "minimum": 1, "description": description}
}

func textLimitProperty(description string) map[string]any {
	return map[string]any{
		"anyOf": []any{
			map[string]any{"type": "integer", "minimum": 1},
			map[string]any{"type": "string", "enum": []string{"max"}},
		},
		"description": description,
	}
}

func main() {
	if err := runCLI(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runCLI(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		fmt.Fprint(stdout, helpText(""))
		return nil
	}

	switch args[0] {
	case "-h", "--help", "help":
		topic := ""
		if len(args) > 1 {
			topic = args[1]
		}
		fmt.Fprint(stdout, helpText(topic))
		return nil
	case "-v", "--version", "version":
		fmt.Fprintln(stdout, version)
		return nil
	case "mcp":
		return runMCP(os.Stdin, stdout)
	case "doctor":
		fmt.Fprintln(stdout, "Windows runtime: UI Automation and Win32 window-message bridge are available when this process runs in the signed-in desktop session.")
		return nil
	case "list-apps":
		result := newService().callTool("list_apps", map[string]any{})
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "snapshot":
		app, textLimit, maxTreeNodes, maxTreeDepth, err := parseSnapshotArgs(args[1:])
		if err != nil {
			return err
		}
		toolArgs := map[string]any{
			"app": app,
		}
		if textLimit != nil {
			toolArgs["text_limit"] = textLimit.runtimeValue()
		}
		if maxTreeNodes != nil {
			toolArgs["max_tree_nodes"] = *maxTreeNodes
		}
		if maxTreeDepth != nil {
			toolArgs["max_tree_depth"] = *maxTreeDepth
		}
		result := newService().callTool("get_app_state", toolArgs)
		if result.IsError {
			return errors.New(result.Content[0].Text)
		}
		fmt.Fprintln(stdout, result.Content[0].Text)
		return nil
	case "call":
		output, hasError, err := runCallCommand(args[1:], newService())
		if err != nil {
			return err
		}
		encoded, err := json.MarshalIndent(output, "", "  ")
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, string(encoded))
		if hasError {
			return errors.New("tool call returned isError=true")
		}
		return nil
	default:
		return fmt.Errorf("unknown command: %s\n\n%s", args[0], helpText(""))
	}
}

func parseSnapshotArgs(args []string) (string, *textLimit, *int, *int, error) {
	var app string
	var textLimit *textLimit
	var maxTreeNodes *int
	var maxTreeDepth *int
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--text-limit":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--text-limit requires a positive integer or max value")
			}
			value, err := parseTextLimitOption(args[index], "--text-limit")
			if err != nil {
				return "", nil, nil, nil, err
			}
			textLimit = value
		case "--max-tree-nodes":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-nodes requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-nodes")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeNodes = &value
		case "--max-tree-depth":
			index++
			if index >= len(args) {
				return "", nil, nil, nil, errors.New("--max-tree-depth requires a positive integer value")
			}
			value, err := parsePositiveIntegerOption(args[index], "--max-tree-depth")
			if err != nil {
				return "", nil, nil, nil, err
			}
			maxTreeDepth = &value
		default:
			if strings.HasPrefix(arg, "-") {
				return "", nil, nil, nil, fmt.Errorf("unknown snapshot option: %s", arg)
			}
			if app != "" {
				return "", nil, nil, nil, errors.New("snapshot accepts exactly one app name, process name, window title, or pid")
			}
			app = arg
		}
	}
	if app == "" {
		return "", nil, nil, nil, errors.New("snapshot requires an app name, process name, window title, or pid")
	}
	return app, textLimit, maxTreeNodes, maxTreeDepth, nil
}

func parseTextLimitOption(value, option string) (*textLimit, error) {
	if strings.EqualFold(value, "max") {
		return &textLimit{max: true}, nil
	}
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return nil, fmt.Errorf("%s must be a positive integer or max", option)
	}
	return &textLimit{count: integer}, nil
}

func parsePositiveIntegerOption(value, option string) (int, error) {
	integer, err := strconv.Atoi(value)
	if err != nil || integer <= 0 {
		return 0, fmt.Errorf("%s must be a positive integer", option)
	}
	return integer, nil
}

func runCallCommand(args []string, svc *service) (any, bool, error) {
	if len(args) == 0 {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}

	var toolName, argsJSON, argsFile, callsJSON, callsFile string
	for index := 0; index < len(args); index++ {
		arg := args[index]
		switch arg {
		case "--args":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args requires a value")
			}
			argsJSON = args[index]
		case "--args-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--args-file requires a value")
			}
			argsFile = args[index]
		case "--calls":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls requires a value")
			}
			callsJSON = args[index]
		case "--calls-file":
			index++
			if index >= len(args) {
				return nil, false, errors.New("--calls-file requires a value")
			}
			callsFile = args[index]
		default:
			if strings.HasPrefix(arg, "-") {
				return nil, false, fmt.Errorf("unknown call option: %s", arg)
			}
			if toolName != "" {
				return nil, false, errors.New("call accepts at most one tool name")
			}
			toolName = arg
		}
	}

	if callsJSON != "" || callsFile != "" {
		if toolName != "" || argsJSON != "" || argsFile != "" {
			return nil, false, errors.New("call sequence does not accept a tool name, --args, or --args-file")
		}
		calls, err := readCallSequence(callsJSON, callsFile)
		if err != nil {
			return nil, false, err
		}
		var outputs []map[string]any
		hasError := false
		for _, call := range calls {
			result := svc.callTool(call.Tool, call.Args)
			outputs = append(outputs, map[string]any{"tool": call.Tool, "result": result})
			if result.IsError {
				hasError = true
				break
			}
		}
		return outputs, hasError, nil
	}

	if toolName == "" {
		return nil, false, errors.New("call requires a tool name or --calls/--calls-file")
	}
	arguments, err := readArguments(argsJSON, argsFile)
	if err != nil {
		return nil, false, err
	}
	result := svc.callTool(toolName, arguments)
	return result, result.IsError, nil
}

type callSpec struct {
	Tool string
	Args map[string]any
}

func readArguments(inline, file string) (map[string]any, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either inline JSON or a JSON file, not both")
	}
	if inline == "" && file == "" {
		return map[string]any{}, nil
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var args map[string]any
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	if err := decoder.Decode(&args); err != nil {
		return nil, fmt.Errorf("Invalid JSON input: %w", err)
	}
	if args == nil {
		return nil, errors.New("--args must be a JSON object")
	}
	return args, nil
}

func readCallSequence(inline, file string) ([]callSpec, error) {
	if inline != "" && file != "" {
		return nil, errors.New("Use either --calls or --calls-file, not both")
	}
	source, err := readJSONSource(inline, file)
	if err != nil {
		return nil, err
	}
	var raw []map[string]any
	decoder := json.NewDecoder(strings.NewReader(source))
	decoder.UseNumber()
	if err := decoder.Decode(&raw); err != nil {
		return nil, fmt.Errorf("Invalid JSON input: %w", err)
	}
	calls := make([]callSpec, 0, len(raw))
	for index, item := range raw {
		name, _ := item["tool"].(string)
		if name == "" {
			name, _ = item["name"].(string)
		}
		if name == "" {
			return nil, fmt.Errorf("call sequence item #%d requires a non-empty tool", index+1)
		}
		args, _ := item["args"].(map[string]any)
		if args == nil {
			args, _ = item["arguments"].(map[string]any)
		}
		if args == nil {
			args = map[string]any{}
		}
		calls = append(calls, callSpec{Tool: name, Args: args})
	}
	return calls, nil
}

func readJSONSource(inline, file string) (string, error) {
	if inline != "" {
		return inline, nil
	}
	if file == "" {
		return "", errors.New("JSON input is required")
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func runMCP(stdin io.Reader, stdout io.Writer) error {
	svc := newService()
	decoder := json.NewDecoder(stdin)
	encoder := json.NewEncoder(stdout)
	for {
		var request map[string]any
		if err := decoder.Decode(&request); err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			_ = encoder.Encode(jsonRPCError(nil, -32700, "Invalid JSON-RPC payload"))
			continue
		}
		response := handleMCPRequest(request, svc)
		if response != nil {
			if err := encoder.Encode(response); err != nil {
				return err
			}
		}
	}
}

func handleMCPRequest(request map[string]any, svc *service) map[string]any {
	id := request["id"]
	method, _ := request["method"].(string)
	params, _ := request["params"].(map[string]any)
	switch method {
	case "initialize":
		return jsonRPCResult(id, map[string]any{
			"protocolVersion": "2025-03-26",
			"serverInfo": map[string]any{
				"name":    "open-computer-use",
				"version": version,
			},
			"capabilities": map[string]any{"tools": map[string]any{"listChanged": false}},
			"instructions": serverInstructions,
		})
	case "notifications/initialized", "notifications/turn-ended":
		return nil
	case "ping":
		return jsonRPCResult(id, map[string]any{})
	case "tools/list":
		return jsonRPCResult(id, map[string]any{"tools": toolDefinitions()})
	case "tools/call":
		name, _ := params["name"].(string)
		arguments, _ := params["arguments"].(map[string]any)
		if arguments == nil {
			arguments = map[string]any{}
		}
		return jsonRPCResult(id, svc.callTool(name, arguments))
	default:
		if method == "" {
			return nil
		}
		return jsonRPCError(id, -32601, "Method not found: "+method)
	}
}

func jsonRPCResult(id any, result any) map[string]any {
	return map[string]any{"jsonrpc": "2.0", "id": id, "result": result}
}

func jsonRPCError(id any, code int, message string) map[string]any {
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   map[string]any{"code": code, "message": message},
	}
}

func helpText(command string) string {
	switch command {
	case "mcp":
		return "Usage:\n  open-computer-use.exe mcp\n\nStart the stdio MCP server.\n"
	case "call":
		return "Usage:\n  open-computer-use.exe call <tool> [--args '<json-object>']\n  open-computer-use.exe call --calls '<json-array>'\n\nThe JSON array form keeps all calls in one process so element_index state can be reused.\n"
	case "snapshot":
		return "Usage:\n  open-computer-use.exe snapshot [--text-limit <positive-int|max>] [--max-tree-nodes <positive-int>] [--max-tree-depth <positive-int>] <app>\n\nPrint the current Windows UI Automation snapshot for the target app.\n"
	default:
		return `Open Computer Use for Windows

Usage:
  open-computer-use.exe [command] [options]

Commands:
  mcp                  Start the stdio MCP server.
  doctor               Print Windows runtime notes.
  list-apps            Print running apps with top-level windows.
  snapshot <app>       Print the current UI Automation snapshot for an app.
  call <tool>           Call one tool, or run a JSON array of tool calls.
  help [command]       Show general or command-specific help.
  version              Print the CLI version.

Notes:
  The Windows runtime uses UI Automation first, then Win32 window messages for
  fallback input. Run it in the signed-in desktop session, not as a service.
`
	}
}
