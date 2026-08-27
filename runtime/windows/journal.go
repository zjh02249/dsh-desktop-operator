package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	actionJournalSchemaVersion = 1
	defaultJournalRetention    = 30 * 24 * time.Hour
	defaultJournalMaxEvents    = 4096
	journalLockTimeoutMS       = 10000
	maxJournalBytes            = 32 << 20
)

type actionAuditState string

const (
	actionReserved   actionAuditState = "reserved"
	actionDispatched actionAuditState = "dispatched"
	actionApplied    actionAuditState = "applied"
	actionRejected   actionAuditState = "rejected"
	actionUnknown    actionAuditState = "unknown"
)

type actionAuditTarget struct {
	AppID      string `json:"appId,omitempty"`
	PID        int    `json:"pid,omitempty"`
	HWND       string `json:"hwnd,omitempty"`
	Generation string `json:"generation,omitempty"`
}

type actionAuditEvent struct {
	SchemaVersion      int               `json:"schemaVersion"`
	TimestampUTC       time.Time         `json:"timestampUtc"`
	IdempotencyKeyHash string            `json:"idempotencyKeyHash"`
	ActionIDHash       string            `json:"actionIdHash"`
	ActionFingerprint  string            `json:"actionFingerprint"`
	RuntimeID          string            `json:"runtimeId"`
	ProcessID          int               `json:"processId"`
	Tool               string            `json:"tool"`
	IntentKind         string            `json:"intentKind,omitempty"`
	Target             actionAuditTarget `json:"target,omitempty"`
	State              actionAuditState  `json:"state"`
	ErrorCode          string            `json:"errorCode,omitempty"`
	DurationMS         int64             `json:"durationMs,omitempty"`
	Recovered          bool              `json:"recovered,omitempty"`
	PreviousState      actionAuditState  `json:"previousState,omitempty"`
}

type actionJournalStatus struct {
	Enabled             bool                     `json:"enabled"`
	Path                string                   `json:"path,omitempty"`
	SchemaVersion       int                      `json:"schemaVersion"`
	EventCount          int                      `json:"eventCount"`
	ActionCount         int                      `json:"actionCount"`
	PendingCount        int                      `json:"pendingCount"`
	AppliedCount        int                      `json:"appliedCount"`
	RejectedCount       int                      `json:"rejectedCount"`
	UnknownCount        int                      `json:"unknownCount"`
	RecoveredTailBytes  int                      `json:"recoveredTailBytes,omitempty"`
	RetentionDays       int                      `json:"retentionDays,omitempty"`
	MaximumEvents       int                      `json:"maximumEvents,omitempty"`
	LatestByState       map[actionAuditState]int `json:"latestByState,omitempty"`
	InitializationError string                   `json:"initializationError,omitempty"`
}

type actionJournal interface {
	Recover() error
	Reserve(request psRequest) error
	MarkDispatched(request psRequest) error
	Complete(request psRequest, state actionAuditState, errorCode string, duration time.Duration) error
	Status() (actionJournalStatus, error)
	Audit(limit int) ([]actionAuditEvent, error)
	Prune() (actionJournalStatus, error)
}

type memoryActionJournal struct {
	mu      sync.Mutex
	events  []actionAuditEvent
	latest  map[string]actionAuditEvent
	runtime string
}

func newMemoryActionJournal() *memoryActionJournal {
	return &memoryActionJournal{latest: map[string]actionAuditEvent{}, runtime: newRuntimeID()}
}

func (journal *memoryActionJournal) Recover() error { return nil }

func (journal *memoryActionJournal) Reserve(request psRequest) error {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	event := auditEventForRequest(request, journal.runtime, actionReserved, "", 0)
	if previous, exists := journal.latest[event.IdempotencyKeyHash]; exists {
		return duplicateActionError(request.IdempotencyKey, previous)
	}
	journal.events = append(journal.events, event)
	journal.latest[event.IdempotencyKeyHash] = event
	return nil
}

func (journal *memoryActionJournal) MarkDispatched(request psRequest) error {
	return journal.transition(request, actionDispatched, "", 0)
}

func (journal *memoryActionJournal) Complete(request psRequest, state actionAuditState, errorCode string, duration time.Duration) error {
	return journal.transition(request, state, errorCode, duration)
}

func (journal *memoryActionJournal) transition(request psRequest, state actionAuditState, errorCode string, duration time.Duration) error {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	event := auditEventForRequest(request, journal.runtime, state, errorCode, duration)
	journal.events = append(journal.events, event)
	journal.latest[event.IdempotencyKeyHash] = event
	return nil
}

func (journal *memoryActionJournal) Status() (actionJournalStatus, error) {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	return summarizeJournal("", false, journal.events, 0, 0, 0), nil
}

func (journal *memoryActionJournal) Audit(limit int) ([]actionAuditEvent, error) {
	journal.mu.Lock()
	defer journal.mu.Unlock()
	return tailEvents(journal.events, limit), nil
}

func (journal *memoryActionJournal) Prune() (actionJournalStatus, error) {
	return journal.Status()
}

type failingActionJournal struct {
	err error
}

func (journal *failingActionJournal) Reserve(psRequest) error { return journal.err }
func (journal *failingActionJournal) Recover() error          { return journal.err }
func (journal *failingActionJournal) MarkDispatched(psRequest) error {
	return journal.err
}
func (journal *failingActionJournal) Complete(psRequest, actionAuditState, string, time.Duration) error {
	return journal.err
}
func (journal *failingActionJournal) Status() (actionJournalStatus, error) {
	return actionJournalStatus{Enabled: true, SchemaVersion: actionJournalSchemaVersion, InitializationError: journal.err.Error()}, journal.err
}
func (journal *failingActionJournal) Audit(int) ([]actionAuditEvent, error) { return nil, journal.err }
func (journal *failingActionJournal) Prune() (actionJournalStatus, error) {
	return actionJournalStatus{}, journal.err
}

type fileActionJournal struct {
	path       string
	mutexName  string
	retention  time.Duration
	maxEvents  int
	runtimeID  string
	now        func() time.Time
	lockWaitMS uint32
}

func newConfiguredActionJournal() (actionJournal, error) {
	if envFlag("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_DISABLED") {
		return newMemoryActionJournal(), nil
	}
	path, err := configuredJournalPath()
	if err != nil {
		return nil, err
	}
	retentionDays, err := journalIntegerEnvironment("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_RETENTION_DAYS", 30, 1, 3650)
	if err != nil {
		return nil, err
	}
	maxEvents, err := journalIntegerEnvironment("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_MAX_EVENTS", defaultJournalMaxEvents, 100, 100000)
	if err != nil {
		return nil, err
	}
	journal := newFileActionJournal(path, time.Duration(retentionDays)*24*time.Hour, maxEvents)
	if err := journal.Recover(); err != nil {
		return nil, err
	}
	return journal, nil
}

func (journal *fileActionJournal) Recover() error {
	return journal.withLock(func() error {
		events, truncated, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		originalCount := len(events)
		events = journal.retainedEvents(events)
		latest := map[string]actionAuditEvent{}
		for _, event := range events {
			latest[event.IdempotencyKeyHash] = event
		}
		for _, previous := range latest {
			if previous.State != actionReserved && previous.State != actionDispatched {
				continue
			}
			if previous.ProcessID <= 0 || isProcessAlive(previous.ProcessID) {
				continue
			}
			recovered := previous
			recovered.TimestampUTC = journal.now()
			recovered.RuntimeID = journal.runtimeID
			recovered.ProcessID = os.Getpid()
			recovered.State = actionUnknown
			recovered.ErrorCode = "runtime_process_terminated"
			recovered.DurationMS = 0
			recovered.Recovered = true
			recovered.PreviousState = previous.State
			events = append(events, recovered)
		}
		if truncated > 0 || len(events) != originalCount {
			return journal.rewriteLocked(events)
		}
		return nil
	})
}

func configuredJournalPath() (string, error) {
	configured := strings.TrimSpace(os.Getenv("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_PATH"))
	if configured != "" {
		if !filepath.IsAbs(configured) {
			return "", errors.New("journal_path_invalid: OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_PATH must be absolute")
		}
		return filepath.Clean(configured), nil
	}
	root := strings.TrimSpace(os.Getenv("LOCALAPPDATA"))
	if root == "" {
		return "", errors.New("journal_path_unavailable: LOCALAPPDATA is not set")
	}
	return filepath.Join(root, "dsh-desktop-operator", "action-journal-v1.jsonl"), nil
}

func newFileActionJournal(path string, retention time.Duration, maxEvents int) *fileActionJournal {
	absolute, _ := filepath.Abs(path)
	digest := sha256.Sum256([]byte(strings.ToLower(filepath.Clean(absolute))))
	return &fileActionJournal{
		path:       absolute,
		mutexName:  `Local\DSHDesktopOperator.ActionJournal.` + hex.EncodeToString(digest[:16]),
		retention:  retention,
		maxEvents:  maxEvents,
		runtimeID:  newRuntimeID(),
		now:        func() time.Time { return time.Now().UTC() },
		lockWaitMS: journalLockTimeoutMS,
	}
}

func (journal *fileActionJournal) Reserve(request psRequest) error {
	return journal.withLock(func() error {
		events, truncated, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		originalCount := len(events)
		events = journal.retainedEvents(events)
		if truncated > 0 || len(events) != originalCount || len(events) >= journal.maxEvents {
			if err := journal.rewriteLocked(events); err != nil {
				return err
			}
		}
		event := auditEventForRequestAt(request, journal.runtimeID, actionReserved, "", 0, journal.now())
		for index := len(events) - 1; index >= 0; index-- {
			if events[index].IdempotencyKeyHash == event.IdempotencyKeyHash {
				return duplicateActionError(request.IdempotencyKey, events[index])
			}
		}
		return journal.appendLocked(event)
	})
}

func (journal *fileActionJournal) MarkDispatched(request psRequest) error {
	return journal.appendTransition(request, actionDispatched, "", 0)
}

func (journal *fileActionJournal) Complete(request psRequest, state actionAuditState, errorCode string, duration time.Duration) error {
	if state != actionApplied && state != actionRejected && state != actionUnknown {
		return fmt.Errorf("journal_state_invalid: %s", state)
	}
	return journal.appendTransition(request, state, sanitizeErrorCode(errorCode), duration)
}

func (journal *fileActionJournal) appendTransition(request psRequest, state actionAuditState, errorCode string, duration time.Duration) error {
	return journal.withLock(func() error {
		events, truncated, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		if truncated > 0 {
			if err := journal.rewriteLocked(events); err != nil {
				return err
			}
		}
		return journal.appendLocked(auditEventForRequestAt(request, journal.runtimeID, state, errorCode, duration, journal.now()))
	})
}

func (journal *fileActionJournal) Status() (actionJournalStatus, error) {
	var status actionJournalStatus
	err := journal.withLock(func() error {
		events, truncated, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		status = summarizeJournal(journal.path, true, events, truncated, journal.retention, journal.maxEvents)
		return nil
	})
	return status, err
}

func (journal *fileActionJournal) Audit(limit int) ([]actionAuditEvent, error) {
	var audit []actionAuditEvent
	err := journal.withLock(func() error {
		events, _, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		audit = tailEvents(events, limit)
		return nil
	})
	return audit, err
}

func (journal *fileActionJournal) Prune() (actionJournalStatus, error) {
	var status actionJournalStatus
	err := journal.withLock(func() error {
		events, _, err := journal.readEventsLocked()
		if err != nil {
			return err
		}
		events = journal.retainedEvents(events)
		if err := journal.rewriteLocked(events); err != nil {
			return err
		}
		status = summarizeJournal(journal.path, true, events, 0, journal.retention, journal.maxEvents)
		return nil
	})
	return status, err
}

func (journal *fileActionJournal) withLock(action func() error) error {
	return withNamedMutex(journal.mutexName, journal.lockWaitMS, action)
}

func (journal *fileActionJournal) readEventsLocked() ([]actionAuditEvent, int, error) {
	data, err := os.ReadFile(journal.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, 0, nil
	}
	if err != nil {
		return nil, 0, fmt.Errorf("journal_read_failed: %w", err)
	}
	if len(data) > maxJournalBytes {
		return nil, 0, fmt.Errorf("journal_too_large(size=%d,max=%d)", len(data), maxJournalBytes)
	}
	lines := strings.Split(string(data), "\n")
	events := make([]actionAuditEvent, 0, len(lines))
	truncatedBytes := 0
	for index, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var event actionAuditEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			isTail := index == len(lines)-1 || (index == len(lines)-2 && lines[len(lines)-1] == "")
			if isTail {
				truncatedBytes = len(line)
				continue
			}
			return nil, 0, fmt.Errorf("journal_corrupt(line=%d): %w", index+1, err)
		}
		if event.SchemaVersion != actionJournalSchemaVersion {
			return nil, 0, fmt.Errorf("journal_schema_unsupported(line=%d,version=%d)", index+1, event.SchemaVersion)
		}
		events = append(events, event)
	}
	return events, truncatedBytes, nil
}

func (journal *fileActionJournal) appendLocked(event actionAuditEvent) error {
	if err := os.MkdirAll(filepath.Dir(journal.path), 0o700); err != nil {
		return fmt.Errorf("journal_directory_failed: %w", err)
	}
	file, err := os.OpenFile(journal.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("journal_open_failed: %w", err)
	}
	writer := bufio.NewWriter(file)
	encodeErr := json.NewEncoder(writer).Encode(event)
	flushErr := writer.Flush()
	syncErr := file.Sync()
	closeErr := file.Close()
	for _, candidate := range []error{encodeErr, flushErr, syncErr, closeErr} {
		if candidate != nil {
			return fmt.Errorf("journal_append_failed: %w", candidate)
		}
	}
	return nil
}

func (journal *fileActionJournal) rewriteLocked(events []actionAuditEvent) error {
	if err := os.MkdirAll(filepath.Dir(journal.path), 0o700); err != nil {
		return fmt.Errorf("journal_directory_failed: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(journal.path), ".action-journal-*.tmp")
	if err != nil {
		return fmt.Errorf("journal_compaction_create_failed: %w", err)
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	_ = temporary.Chmod(0o600)
	encoder := json.NewEncoder(temporary)
	for _, event := range events {
		if err := encoder.Encode(event); err != nil {
			_ = temporary.Close()
			return fmt.Errorf("journal_compaction_encode_failed: %w", err)
		}
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("journal_compaction_sync_failed: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("journal_compaction_close_failed: %w", err)
	}
	if err := replaceFileAtomic(temporaryPath, journal.path); err != nil {
		return fmt.Errorf("journal_compaction_replace_failed: %w", err)
	}
	removeTemporary = false
	return nil
}

func (journal *fileActionJournal) retainedEvents(events []actionAuditEvent) []actionAuditEvent {
	cutoff := journal.now().Add(-journal.retention)
	retained := make([]actionAuditEvent, 0, len(events))
	for _, event := range events {
		if !event.TimestampUTC.Before(cutoff) {
			retained = append(retained, event)
		}
	}
	if len(retained) > journal.maxEvents {
		retained = append([]actionAuditEvent(nil), retained[len(retained)-journal.maxEvents:]...)
	}
	return retained
}

func auditEventForRequest(request psRequest, runtimeID string, state actionAuditState, errorCode string, duration time.Duration) actionAuditEvent {
	return auditEventForRequestAt(request, runtimeID, state, errorCode, duration, time.Now().UTC())
}

func auditEventForRequestAt(request psRequest, runtimeID string, state actionAuditState, errorCode string, duration time.Duration, timestamp time.Time) actionAuditEvent {
	fingerprint := journalActionFingerprint(request)
	target := actionAuditTarget{}
	if request.Window != nil {
		target = actionAuditTarget{
			AppID:      request.Window.AppID,
			PID:        request.Window.PID,
			HWND:       request.Window.HWND,
			Generation: request.Window.Generation,
		}
	}
	return actionAuditEvent{
		SchemaVersion:      actionJournalSchemaVersion,
		TimestampUTC:       timestamp.UTC(),
		IdempotencyKeyHash: hashJournalValue(request.IdempotencyKey),
		ActionIDHash:       hashJournalValue(request.ActionID),
		ActionFingerprint:  fingerprint,
		RuntimeID:          runtimeID,
		ProcessID:          os.Getpid(),
		Tool:               request.Tool,
		IntentKind:         request.ActionIntent.Kind,
		Target:             target,
		State:              state,
		ErrorCode:          sanitizeErrorCode(errorCode),
		DurationMS:         duration.Milliseconds(),
	}
}

func duplicateActionError(key string, previous actionAuditEvent) error {
	return fmt.Errorf(
		"duplicate_action(idempotency_key_hash=%q, first_action_id_hash=%q, durable_state=%q): this action is already recorded; re-observe before deciding what to do next",
		hashJournalValue(key), previous.ActionIDHash, previous.State,
	)
}

func journalActionFingerprint(request psRequest) string {
	redacted := request
	redacted.Title = ""
	redacted.Text = ""
	redacted.Key = ""
	redacted.Value = ""
	redacted.ExpectedPostcondition = nil
	redacted.ActionIntent.Summary = ""
	redacted.Capture = nil
	if request.Element != nil {
		redacted.Element = &elementRecord{
			Index:              request.Element.Index,
			RuntimeID:          append([]int(nil), request.Element.RuntimeID...),
			AutomationID:       request.Element.AutomationID,
			ControlType:        request.Element.ControlType,
			ClassName:          request.Element.ClassName,
			NativeWindowHandle: request.Element.NativeWindowHandle,
		}
	}
	return actionFingerprint(redacted)
}

func actionCompletionState(response *psResponse, err error) (actionAuditState, string) {
	if err != nil {
		return actionUnknown, sanitizeErrorCode(err.Error())
	}
	if response == nil {
		return actionUnknown, "runtime_response_missing"
	}
	if response.OK {
		if strings.EqualFold(strings.TrimSpace(response.Status), "unknown") {
			return actionUnknown, "postcondition_unknown"
		}
		return actionApplied, ""
	}
	if strings.EqualFold(strings.TrimSpace(response.Status), "unknown") {
		return actionUnknown, sanitizeErrorCode(response.Error)
	}
	return actionRejected, sanitizeErrorCode(response.Error)
}

func sanitizeErrorCode(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	var builder strings.Builder
	for _, char := range value {
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || char == '_' || char == '-' || char == '.' {
			builder.WriteRune(char)
			if builder.Len() >= 80 {
				break
			}
			continue
		}
		break
	}
	if builder.Len() == 0 {
		return "runtime_error"
	}
	return strings.ToLower(builder.String())
}

func hashJournalValue(value string) string {
	digest := sha256.Sum256([]byte(strings.TrimSpace(value)))
	return hex.EncodeToString(digest[:])
}

func newRuntimeID() string {
	data := make([]byte, 8)
	if _, err := io.ReadFull(rand.Reader, data); err == nil {
		return hex.EncodeToString(data)
	}
	return strconv.FormatInt(time.Now().UTC().UnixNano(), 36)
}

func journalIntegerEnvironment(name string, fallback, minimum, maximum int) (int, error) {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < minimum || parsed > maximum {
		return 0, fmt.Errorf("journal_config_invalid: %s must be an integer from %d to %d", name, minimum, maximum)
	}
	return parsed, nil
}

func envFlag(name string) bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(name)))
	return value == "1" || value == "true" || value == "yes" || value == "on"
}

func summarizeJournal(path string, enabled bool, events []actionAuditEvent, truncated int, retention time.Duration, maximum int) actionJournalStatus {
	latest := map[string]actionAuditEvent{}
	for _, event := range events {
		latest[event.IdempotencyKeyHash] = event
	}
	counts := map[actionAuditState]int{}
	for _, event := range latest {
		counts[event.State]++
	}
	return actionJournalStatus{
		Enabled:            enabled,
		Path:               path,
		SchemaVersion:      actionJournalSchemaVersion,
		EventCount:         len(events),
		ActionCount:        len(latest),
		PendingCount:       counts[actionReserved] + counts[actionDispatched],
		AppliedCount:       counts[actionApplied],
		RejectedCount:      counts[actionRejected],
		UnknownCount:       counts[actionUnknown],
		RecoveredTailBytes: truncated,
		RetentionDays:      int(retention / (24 * time.Hour)),
		MaximumEvents:      maximum,
		LatestByState:      counts,
	}
}

func tailEvents(events []actionAuditEvent, limit int) []actionAuditEvent {
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}
	start := len(events) - limit
	if start < 0 {
		start = 0
	}
	result := append([]actionAuditEvent(nil), events[start:]...)
	sort.SliceStable(result, func(left, right int) bool {
		return result[left].TimestampUTC.Before(result[right].TimestampUTC)
	})
	return result
}
