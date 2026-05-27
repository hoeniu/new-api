package model

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/constant"
	"github.com/QuantumNous/new-api/setting/operation_setting"
)

// AutoSetupFromEnv performs first-time initialization from environment variables.
// Required: INIT_ADMIN_USERNAME, INIT_ADMIN_PASSWORD
// Optional: INIT_WEB_ACCESS_TOKEN (root user API access token), INIT_USAGE_MODE (external|self|demo)
func AutoSetupFromEnv() error {
	if constant.Setup {
		return nil
	}

	username := strings.TrimSpace(os.Getenv("INIT_ADMIN_USERNAME"))
	password := os.Getenv("INIT_ADMIN_PASSWORD")
	if username == "" || password == "" {
		common.SysLog("auto setup skipped: set INIT_ADMIN_USERNAME and INIT_ADMIN_PASSWORD to initialize automatically")
		return nil
	}

	if len(username) > 12 {
		return fmt.Errorf("INIT_ADMIN_USERNAME must be at most 12 characters")
	}
	if len(password) < 8 {
		return fmt.Errorf("INIT_ADMIN_PASSWORD must be at least 8 characters")
	}

	accessToken := strings.TrimSpace(os.Getenv("INIT_WEB_ACCESS_TOKEN"))
	if accessToken != "" {
		if len(accessToken) > 32 {
			return fmt.Errorf("INIT_WEB_ACCESS_TOKEN must be at most 32 characters")
		}
		var existing User
		if err := DB.Where("access_token = ?", accessToken).First(&existing).Error; err == nil {
			return fmt.Errorf("INIT_WEB_ACCESS_TOKEN is already in use")
		}
	}

	selfUseMode, demoSiteMode, err := parseInitUsageMode(os.Getenv("INIT_USAGE_MODE"))
	if err != nil {
		return err
	}

	if RootUserExists() {
		common.SysLog("auto setup skipped: root user already exists")
		return nil
	}

	hashedPassword, err := common.Password2Hash(password)
	if err != nil {
		return fmt.Errorf("failed to hash admin password: %w", err)
	}

	rootUser := User{
		Username:    username,
		Password:    hashedPassword,
		Role:        common.RoleRootUser,
		Status:      common.UserStatusEnabled,
		DisplayName: "Root User",
		Quota:       100000000,
	}
	if accessToken != "" {
		rootUser.SetAccessToken(accessToken)
	}

	if err := DB.Create(&rootUser).Error; err != nil {
		return fmt.Errorf("failed to create admin account: %w", err)
	}

	operation_setting.SelfUseModeEnabled = selfUseMode
	operation_setting.DemoSiteEnabled = demoSiteMode

	if err := UpdateOption("SelfUseModeEnabled", strconv.FormatBool(selfUseMode)); err != nil {
		return fmt.Errorf("failed to save SelfUseModeEnabled: %w", err)
	}
	if err := UpdateOption("DemoSiteEnabled", strconv.FormatBool(demoSiteMode)); err != nil {
		return fmt.Errorf("failed to save DemoSiteEnabled: %w", err)
	}

	setup := Setup{
		Version:       common.Version,
		InitializedAt: time.Now().Unix(),
	}
	if err := DB.Create(&setup).Error; err != nil {
		return fmt.Errorf("failed to create setup record: %w", err)
	}

	constant.Setup = true
	common.SysLog("system auto-initialized from environment variables (usage mode: " + initUsageModeLabel(selfUseMode, demoSiteMode) + ")")
	return nil
}

func parseInitUsageMode(raw string) (selfUseMode bool, demoSiteMode bool, err error) {
	mode := strings.ToLower(strings.TrimSpace(raw))
	if mode == "" || mode == "external" {
		return false, false, nil
	}
	switch mode {
	case "self":
		return true, false, nil
	case "demo":
		return false, true, nil
	default:
		return false, false, fmt.Errorf("INIT_USAGE_MODE must be external, self, or demo")
	}
}

func initUsageModeLabel(selfUseMode, demoSiteMode bool) string {
	switch {
	case demoSiteMode:
		return "demo"
	case selfUseMode:
		return "self"
	default:
		return "external"
	}
}
