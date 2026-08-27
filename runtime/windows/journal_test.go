package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func journalTestRequest(key, actionID string) psRequest {
	return psRequest{
		Tool:           "type_text",
		ActionID:       actionID,
		IdempotencyKey: key,
		ActionIntent:   actionIntent{Kind: "edit", Summary: "secret summary must never be persisted"},
		Text:           "secret typed text must never be persisted",
		Value:          "secret value must never be persisted",
		Window: &windowRef{
			AppID:      "notepad",
			PID:        42,
			HWND:       "1001",
			Generation: "generation-1",
		},
	}
}

func TestPersistentJournalRejectsDuplicateAfterRuntimeRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	request := journalTestRequest("operation-across-restart", "action-first")
	first := newFileActionJournal(path, defaultJournalRetention, 100)
	if err := first.Reserve(request); err != nil {
		t.Fatal(err)
	}
	if err := first.MarkDispatched(request); err != nil {
		t.Fatal(err)
	}

	restarted := newFileActionJournal(path, defaultJournalRetention, 100)
	// Model a crashed runtime without depending on a real subprocess PID.
	events, _, err := restarted.readEventsLocked()
	if err != nil {
		t.Fatal(err)
	}
	for index := range events {
		events[index].ProcessID = 99999999
	}
	if err := restarted.withLock(func() error { return restarted.rewriteLocked(events) }); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Recover(); err != nil {
		t.Fatal(err)
	}
	err = restarted.Reserve(journalTestRequest("operation-across-restart", "action-retry"))
	if err == nil || !strings.Contains(err.Error(), "duplicate_action") || !strings.Contains(err.Error(), `durable_state="unknown"`) {
		t.Fatalf("restart duplicate error = %v", err)
	}
	status, err := restarted.Status()
	if err != nil {
		t.Fatal(err)
	}
	if status.ActionCount != 1 || status.PendingCount != 0 || status.UnknownCount != 1 || status.EventCount != 3 {
		t.Fatalf("restart status = %#v", status)
	}

	audit, err := restarted.Audit(100)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(audit)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{request.Text, request.Value, request.ActionIntent.Summary, request.IdempotencyKey, request.ActionID} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("audit persisted sensitive action payload %q: %s", secret, encoded)
		}
	}
}

func TestPersistentJournalDoesNotRecoverLiveProcess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	request := journalTestRequest("live-operation", "live-action")
	journal := newFileActionJournal(path, defaultJournalRetention, 100)
	if err := journal.Reserve(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.MarkDispatched(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.Recover(); err != nil {
		t.Fatal(err)
	}
	status, err := journal.Status()
	if err != nil {
		t.Fatal(err)
	}
	if status.PendingCount != 1 || status.UnknownCount != 0 || status.EventCount != 2 {
		t.Fatalf("live process status = %#v", status)
	}
}

func TestPersistentJournalTerminalStateSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	request := journalTestRequest("completed-operation", "completed-action")
	journal := newFileActionJournal(path, defaultJournalRetention, 100)
	if err := journal.Reserve(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.MarkDispatched(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.Complete(request, actionApplied, "", 250*time.Millisecond); err != nil {
		t.Fatal(err)
	}

	restarted := newFileActionJournal(path, defaultJournalRetention, 100)
	err := restarted.Reserve(journalTestRequest("completed-operation", "retry-action"))
	if err == nil || !strings.Contains(err.Error(), `durable_state="applied"`) {
		t.Fatalf("terminal duplicate error = %v", err)
	}
	status, err := restarted.Status()
	if err != nil {
		t.Fatal(err)
	}
	if status.AppliedCount != 1 || status.PendingCount != 0 {
		t.Fatalf("terminal status = %#v", status)
	}
}

func TestPersistentJournalSerializesConcurrentReservations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	const attempts = 20
	var successes atomic.Int32
	var duplicates atomic.Int32
	var unexpected atomic.Int32
	var wait sync.WaitGroup
	for index := 0; index < attempts; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			journal := newFileActionJournal(path, defaultJournalRetention, 100)
			err := journal.Reserve(journalTestRequest("concurrent-operation", "concurrent-action"))
			switch {
			case err == nil:
				successes.Add(1)
			case strings.Contains(err.Error(), "duplicate_action"):
				duplicates.Add(1)
			default:
				unexpected.Add(1)
			}
		}()
	}
	wait.Wait()
	if successes.Load() != 1 || duplicates.Load() != attempts-1 || unexpected.Load() != 0 {
		t.Fatalf("successes=%d duplicates=%d unexpected=%d", successes.Load(), duplicates.Load(), unexpected.Load())
	}
}

func TestPersistentJournalRecoversOnlyTruncatedTail(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	journal := newFileActionJournal(path, defaultJournalRetention, 100)
	request := journalTestRequest("valid-before-tail", "valid-action")
	if err := journal.Reserve(request); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(`{"schemaVersion":1,"timestampUtc":"truncated`); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	status, err := journal.Status()
	if err != nil {
		t.Fatal(err)
	}
	if status.RecoveredTailBytes == 0 || status.ActionCount != 1 {
		t.Fatalf("truncated status = %#v", status)
	}
	if err := journal.Reserve(journalTestRequest("after-tail-recovery", "recovery-action")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "truncated") {
		t.Fatalf("truncated tail was not removed: %s", data)
	}
}

func TestPersistentJournalRejectsInteriorCorruption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	if err := os.WriteFile(path, []byte("{broken}\n{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	journal := newFileActionJournal(path, defaultJournalRetention, 100)
	err := journal.Reserve(journalTestRequest("blocked-by-corruption", "blocked-action"))
	if err == nil || !strings.Contains(err.Error(), "journal_corrupt") {
		t.Fatalf("interior corruption error = %v", err)
	}
}

func TestPersistentJournalPrunesExpiredAndBoundsEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	journal := newFileActionJournal(path, 24*time.Hour, 3)
	now := time.Now().UTC()
	journal.now = func() time.Time { return now }
	events := []actionAuditEvent{
		{SchemaVersion: 1, TimestampUTC: now.Add(-48 * time.Hour), IdempotencyKeyHash: "old", ActionIDHash: "old", State: actionApplied},
		{SchemaVersion: 1, TimestampUTC: now.Add(-3 * time.Hour), IdempotencyKeyHash: "one", ActionIDHash: "one", State: actionReserved},
		{SchemaVersion: 1, TimestampUTC: now.Add(-2 * time.Hour), IdempotencyKeyHash: "one", ActionIDHash: "one", State: actionApplied},
		{SchemaVersion: 1, TimestampUTC: now.Add(-time.Hour), IdempotencyKeyHash: "two", ActionIDHash: "two", State: actionRejected},
		{SchemaVersion: 1, TimestampUTC: now, IdempotencyKeyHash: "three", ActionIDHash: "three", State: actionUnknown},
	}
	if err := journal.withLock(func() error { return journal.rewriteLocked(events) }); err != nil {
		t.Fatal(err)
	}
	status, err := journal.Prune()
	if err != nil {
		t.Fatal(err)
	}
	if status.EventCount != 3 || status.ActionCount != 3 || status.AppliedCount != 1 || status.RejectedCount != 1 || status.UnknownCount != 1 {
		t.Fatalf("pruned status = %#v", status)
	}
}

func TestActionExecutionRecordsUnknownAfterRuntimeFailure(t *testing.T) {
	journal := newMemoryActionJournal()
	service := newServiceWithJournal(journal)
	request := journalTestRequest("runtime-failure", "runtime-failure-action")
	if err := service.beginAction(&request); err != nil {
		t.Fatal(err)
	}
	service.runPS = func(context.Context, psRequest) (*psResponse, error) {
		return nil, context.Canceled
	}
	_, err := service.executePS(request)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("execute error = %v", err)
	}
	status, err := journal.Status()
	if err != nil {
		t.Fatal(err)
	}
	if status.UnknownCount != 1 || status.PendingCount != 0 {
		t.Fatalf("runtime failure status = %#v", status)
	}
}

func TestActionJournalFailureBlocksBeforeDispatch(t *testing.T) {
	expected := errors.New("journal unavailable")
	service := newServiceWithJournal(&failingActionJournal{err: expected})
	request := journalTestRequest("blocked", "blocked-action")
	if err := service.beginAction(&request); !errors.Is(err, expected) {
		t.Fatalf("begin action error = %v", err)
	}
}

func TestActionCompletionStateAndErrorRedaction(t *testing.T) {
	state, code := actionCompletionState(&psResponse{OK: false, Status: "unknown", Error: "focus_not_acquired: secret window title"}, nil)
	if state != actionUnknown || code != "focus_not_acquired" {
		t.Fatalf("unknown completion = %s %q", state, code)
	}
	state, code = actionCompletionState(&psResponse{OK: false, Status: "not_applied", Error: "stale_window(hwnd=123): secret"}, nil)
	if state != actionRejected || code != "stale_window" {
		t.Fatalf("rejected completion = %s %q", state, code)
	}
}

func TestJournalFingerprintExcludesSensitivePayload(t *testing.T) {
	first := journalTestRequest("first-key", "first-action")
	second := first
	second.Text = "different secret text"
	second.Value = "different secret value"
	second.Key = "different secret key"
	second.Title = "different secret title"
	second.ActionIntent.Summary = "different secret summary"
	second.ActionID = "second-action"
	second.IdempotencyKey = "second-key"
	if journalActionFingerprint(first) != journalActionFingerprint(second) {
		t.Fatal("redacted journal fingerprint changed with sensitive action payload")
	}
}

func TestActionJournalCLIReportsRedactedPersistentState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.jsonl")
	t.Setenv("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_DISABLED", "0")
	t.Setenv("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_PATH", path)
	t.Setenv("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_RETENTION_DAYS", "30")
	t.Setenv("OPEN_COMPUTER_USE_WINDOWS_ACTION_JOURNAL_MAX_EVENTS", "100")
	journal := newFileActionJournal(path, defaultJournalRetention, 100)
	request := journalTestRequest("cli-secret-idempotency-key", "cli-action")
	if err := journal.Reserve(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.MarkDispatched(request); err != nil {
		t.Fatal(err)
	}
	if err := journal.Complete(request, actionApplied, "", 25*time.Millisecond); err != nil {
		t.Fatal(err)
	}

	var audit bytes.Buffer
	if err := runCLI([]string{"action-audit", "10"}, &audit); err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{request.Text, request.Value, request.ActionIntent.Summary, request.IdempotencyKey, request.ActionID} {
		if strings.Contains(audit.String(), secret) {
			t.Fatalf("action-audit exposed sensitive value %q: %s", secret, audit.String())
		}
	}
	var payload struct {
		SchemaVersion int                `json:"schemaVersion"`
		Events        []actionAuditEvent `json:"events"`
	}
	if err := json.Unmarshal(audit.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.SchemaVersion != actionJournalSchemaVersion || len(payload.Events) != 3 || payload.Events[2].State != actionApplied {
		t.Fatalf("action-audit payload = %#v", payload)
	}

	var doctor bytes.Buffer
	if err := runCLI([]string{"doctor"}, &doctor); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(doctor.String(), `"appliedCount":1`) || !strings.Contains(doctor.String(), filepath.Base(path)) {
		t.Fatalf("doctor output = %s", doctor.String())
	}

	var pruned bytes.Buffer
	if err := runCLI([]string{"action-journal-prune"}, &pruned); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(pruned.String(), `"actionCount":1`) {
		t.Fatalf("prune output = %s", pruned.String())
	}
}
