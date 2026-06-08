package model

import (
	"testing"
)

func TestResolveUsageTimeRangeUnix(t *testing.T) {
	start, end, err := ResolveUsageTimeRange(100, 200, "", "", 28800)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if start != 100 || end != 200 {
		t.Fatalf("got %d %d", start, end)
	}
}

func TestResolveUsageTimeRangeDates(t *testing.T) {
	const off int64 = 28800
	start, end, err := ResolveUsageTimeRange(0, 0, "2026-06-01", "2026-06-03", off)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if start <= 0 || end <= start {
		t.Fatalf("invalid range: %d %d", start, end)
	}
	rows := fillUsageDailyRows(start, end, off, map[int64]UsageDailyRow{})
	if len(rows) != 3 {
		t.Fatalf("expected 3 days, got %d", len(rows))
	}
	if rows[0].Date != "2026-06-01" || rows[2].Date != "2026-06-03" {
		t.Fatalf("unexpected dates: %s %s", rows[0].Date, rows[2].Date)
	}
	if rows[1].UsageCount != 0 || rows[1].UsageAmount != 0 {
		t.Fatalf("expected zero usage on empty day")
	}
}

func TestResolveUsageTimeRangeDateValidation(t *testing.T) {
	_, _, err := ResolveUsageTimeRange(0, 0, "2026-06-03", "2026-06-01", 28800)
	if err == nil {
		t.Fatal("expected error for reversed dates")
	}
	_, _, err = ResolveUsageTimeRange(0, 0, "2026-06-01", "", 28800)
	if err == nil {
		t.Fatal("expected error when only one date provided")
	}
}
