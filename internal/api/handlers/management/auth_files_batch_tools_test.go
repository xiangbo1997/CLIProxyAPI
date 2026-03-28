package management

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v6/internal/config"
	coreauth "github.com/router-for-me/CLIProxyAPI/v6/sdk/cliproxy/auth"
	cliproxyexecutor "github.com/router-for-me/CLIProxyAPI/v6/sdk/cliproxy/executor"
)

type statusErrTest struct {
	code int
	msg  string
}

func (e statusErrTest) Error() string   { return e.msg }
func (e statusErrTest) StatusCode() int { return e.code }

type inspectionExecutor struct {
	id      string
	refresh func(context.Context, *coreauth.Auth) (*coreauth.Auth, error)
}

func (e inspectionExecutor) Identifier() string { return e.id }
func (e inspectionExecutor) Execute(context.Context, *coreauth.Auth, cliproxyexecutor.Request, cliproxyexecutor.Options) (cliproxyexecutor.Response, error) {
	return cliproxyexecutor.Response{}, nil
}
func (e inspectionExecutor) ExecuteStream(context.Context, *coreauth.Auth, cliproxyexecutor.Request, cliproxyexecutor.Options) (*cliproxyexecutor.StreamResult, error) {
	return nil, nil
}
func (e inspectionExecutor) Refresh(ctx context.Context, auth *coreauth.Auth) (*coreauth.Auth, error) {
	if e.refresh == nil {
		return auth, nil
	}
	return e.refresh(ctx, auth)
}
func (e inspectionExecutor) CountTokens(context.Context, *coreauth.Auth, cliproxyexecutor.Request, cliproxyexecutor.Options) (cliproxyexecutor.Response, error) {
	return cliproxyexecutor.Response{}, nil
}
func (e inspectionExecutor) HttpRequest(context.Context, *coreauth.Auth, *http.Request) (*http.Response, error) {
	return nil, nil
}

func TestPatchAuthFileFields_UpdatesAccountSource(t *testing.T) {
	t.Setenv("MANAGEMENT_PASSWORD", "")
	gin.SetMode(gin.TestMode)

	store := &memoryAuthStore{}
	manager := coreauth.NewManager(store, nil, nil)
	auth := &coreauth.Auth{
		ID:       "batch-user.json",
		FileName: "batch-user.json",
		Provider: "codex",
		Metadata: map[string]any{"type": "codex"},
	}
	if _, err := manager.Register(context.Background(), auth); err != nil {
		t.Fatalf("register auth: %v", err)
	}

	h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: t.TempDir()}, manager)
	h.tokenStore = store

	body := strings.NewReader(`{"name":"batch-user.json","account_source":"batch"}`)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodPatch, "/v0/management/auth-files/fields", body)
	req.Header.Set("Content-Type", "application/json")
	ctx.Request = req
	h.PatchAuthFileFields(ctx)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	updated, ok := manager.GetByID("batch-user.json")
	if !ok {
		t.Fatal("expected updated auth to exist")
	}
	if got := updated.AccountSource(); got != coreauth.AccountSourceBatch {
		t.Fatalf("account source = %q, want %q", got, coreauth.AccountSourceBatch)
	}
}

func TestInspectBatchAuthFiles_OnlyInspectsBatchAuths(t *testing.T) {
	t.Setenv("MANAGEMENT_PASSWORD", "")
	gin.SetMode(gin.TestMode)

	manager := coreauth.NewManager(nil, nil, nil)
	manager.RegisterExecutor(inspectionExecutor{
		id: "codex",
		refresh: func(_ context.Context, auth *coreauth.Auth) (*coreauth.Auth, error) {
			if auth.AccountSource() == coreauth.AccountSourceBatch {
				return nil, statusErrTest{code: http.StatusUnauthorized, msg: "expired"}
			}
			return auth, nil
		},
	})

	batch := &coreauth.Auth{
		ID:       "batch.json",
		FileName: "batch.json",
		Provider: "codex",
		Metadata: map[string]any{"type": "codex", "account_source": "batch"},
	}
	owned := &coreauth.Auth{
		ID:       "owned.json",
		FileName: "owned.json",
		Provider: "codex",
		Metadata: map[string]any{"type": "codex", "account_source": "owned"},
	}
	if _, err := manager.Register(context.Background(), batch); err != nil {
		t.Fatalf("register batch: %v", err)
	}
	if _, err := manager.Register(context.Background(), owned); err != nil {
		t.Fatalf("register owned: %v", err)
	}

	h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: t.TempDir()}, manager)
	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodPost, "/v0/management/auth-files/inspect", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	ctx.Request = req
	h.InspectBatchAuthFiles(ctx)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	var payload struct {
		Results []authInspectionRow `json:"results"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	if len(payload.Results) != 1 {
		t.Fatalf("expected 1 inspection result, got %d", len(payload.Results))
	}
	if payload.Results[0].ID != "batch.json" || payload.Results[0].Outcome != "invalid" {
		t.Fatalf("unexpected inspection row: %+v", payload.Results[0])
	}
}

func TestCleanupBatchAuthFiles_DisableSkipsOwnedAuths(t *testing.T) {
	t.Setenv("MANAGEMENT_PASSWORD", "")
	gin.SetMode(gin.TestMode)

	store := &memoryAuthStore{}
	manager := coreauth.NewManager(store, nil, nil)
	batch := &coreauth.Auth{
		ID:       "batch.json",
		FileName: "batch.json",
		Provider: "codex",
		Metadata: map[string]any{"type": "codex", "account_source": "batch"},
	}
	owned := &coreauth.Auth{
		ID:       "owned.json",
		FileName: "owned.json",
		Provider: "codex",
		Metadata: map[string]any{"type": "codex", "account_source": "owned"},
	}
	if _, err := manager.Register(context.Background(), batch); err != nil {
		t.Fatalf("register batch: %v", err)
	}
	if _, err := manager.Register(context.Background(), owned); err != nil {
		t.Fatalf("register owned: %v", err)
	}

	h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: t.TempDir()}, manager)
	h.tokenStore = store

	rec := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(rec)
	req := httptest.NewRequest(http.MethodPost, "/v0/management/auth-files/cleanup", strings.NewReader(`{"ids":["batch.json","owned.json"],"mode":"disable"}`))
	req.Header.Set("Content-Type", "application/json")
	ctx.Request = req
	h.CleanupBatchAuthFiles(ctx)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	updatedBatch, _ := manager.GetByID("batch.json")
	if !updatedBatch.Disabled || updatedBatch.Status != coreauth.StatusDisabled {
		t.Fatalf("expected batch auth disabled, got %+v", updatedBatch)
	}
	updatedOwned, _ := manager.GetByID("owned.json")
	if updatedOwned.Disabled || updatedOwned.Status == coreauth.StatusDisabled {
		t.Fatalf("expected owned auth untouched, got %+v", updatedOwned)
	}
}
