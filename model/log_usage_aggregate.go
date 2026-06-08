package model

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"
)

// UsageAggOpts 用量聚合过滤条件：租户级默认读 quota_data；带 token_name 或单 Key 明细时读 logs。
type UsageAggOpts struct {
	UserId    int
	StartTs   int64
	EndTs     int64
	TokenName string
	Group     string // quota_data 无 group；logs 查询时生效
	ModelLike string // 已通过 sanitizeLikePattern
}

const usageAggMaxRangeSeconds int64 = 400 * 86400

func ValidateUsageTimeRange(startTs, endTs int64) error {
	if startTs <= 0 || endTs <= 0 {
		return errors.New("start_timestamp 与 end_timestamp 为必填 Unix 秒，或使用 start_date 与 end_date")
	}
	if endTs < startTs {
		return errors.New("end_timestamp 不得小于 start_timestamp")
	}
	if endTs-startTs > usageAggMaxRangeSeconds {
		return errors.New("查询时间跨度过大")
	}
	return nil
}

// ResolveUsageTimeRange 支持 Unix 秒或自然日 YYYY-MM-DD（含起止日全天，按 timezone_offset 切日）。
func ResolveUsageTimeRange(startTs, endTs int64, startDate, endDate string, tzOffsetSec int64) (int64, int64, error) {
	startDate = strings.TrimSpace(startDate)
	endDate = strings.TrimSpace(endDate)
	if startDate != "" || endDate != "" {
		if startDate == "" || endDate == "" {
			return 0, 0, errors.New("start_date 与 end_date 需同时提供，格式 YYYY-MM-DD")
		}
		loc := time.FixedZone("usage_tz", int(tzOffsetSec))
		startDay, err := time.ParseInLocation("2006-01-02", startDate, loc)
		if err != nil {
			return 0, 0, errors.New("start_date 格式应为 YYYY-MM-DD")
		}
		endDay, err := time.ParseInLocation("2006-01-02", endDate, loc)
		if err != nil {
			return 0, 0, errors.New("end_date 格式应为 YYYY-MM-DD")
		}
		if endDay.Before(startDay) {
			return 0, 0, errors.New("end_date 不得早于 start_date")
		}
		startTs = startDay.Unix()
		endTs = endDay.Add(24*time.Hour).Unix() - 1
		return startTs, endTs, ValidateUsageTimeRange(startTs, endTs)
	}
	if err := ValidateUsageTimeRange(startTs, endTs); err != nil {
		return 0, 0, err
	}
	return startTs, endTs, nil
}

func usageDayExpr(tableAlias string, tzOffsetSec int64) string {
	return fmt.Sprintf("(%s.created_at + %d) / 86400", tableAlias, tzOffsetSec)
}

func dayIDToDateStr(dayID, tzOffsetSec int64) string {
	sec := dayID*86400 - tzOffsetSec
	loc := time.FixedZone("usage_tz", int(tzOffsetSec))
	return time.Unix(sec, 0).In(loc).Format("2006-01-02")
}

func enumerateDayIDs(startTs, endTs, tzOffsetSec int64) []int64 {
	if startTs <= 0 || endTs < startTs {
		return nil
	}
	startDay := (startTs + tzOffsetSec) / 86400
	endDay := (endTs + tzOffsetSec) / 86400
	if endDay < startDay {
		return nil
	}
	out := make([]int64, 0, endDay-startDay+1)
	for d := startDay; d <= endDay; d++ {
		out = append(out, d)
	}
	return out
}

func baseQuotaDataQuery(o UsageAggOpts) *gorm.DB {
	tx := DB.Table("quota_data").Where("quota_data.user_id = ?", o.UserId)
	if o.StartTs > 0 {
		tx = tx.Where("quota_data.created_at >= ?", o.StartTs)
	}
	if o.EndTs > 0 {
		tx = tx.Where("quota_data.created_at <= ?", o.EndTs)
	}
	if o.ModelLike != "" {
		tx = tx.Where("quota_data.model_name LIKE ? ESCAPE '!'", o.ModelLike)
	}
	return tx
}

func baseLogUsageQuery(o UsageAggOpts, logTypes ...int) *gorm.DB {
	tx := LOG_DB.Table("logs").Where("logs.user_id = ?", o.UserId)
	if len(logTypes) == 0 {
		tx = tx.Where("logs.type = ?", LogTypeConsume)
	} else if len(logTypes) == 1 {
		tx = tx.Where("logs.type = ?", logTypes[0])
	} else {
		tx = tx.Where("logs.type IN ?", logTypes)
	}
	if o.StartTs > 0 {
		tx = tx.Where("logs.created_at >= ?", o.StartTs)
	}
	if o.EndTs > 0 {
		tx = tx.Where("logs.created_at <= ?", o.EndTs)
	}
	if o.TokenName != "" {
		tx = tx.Where("logs.token_name = ?", o.TokenName)
	}
	if o.ModelLike != "" {
		tx = tx.Where("logs.model_name LIKE ? ESCAPE '!'", o.ModelLike)
	}
	if o.Group != "" {
		tx = tx.Where("logs."+logGroupCol+" = ?", o.Group)
	}
	return tx
}

type logUsageTotalsRow struct {
	Quota int64
	Tu    int64
	C     int64
}

func queryLogUsageTotals(o UsageAggOpts) (logUsageTotalsRow, error) {
	var row logUsageTotalsRow
	err := baseLogUsageQuery(o).
		Select("COALESCE(SUM(logs.quota),0) as quota, COALESCE(SUM(logs.prompt_tokens)+SUM(logs.completion_tokens),0) as tu, COUNT(*) as c").
		Scan(&row).Error
	return row, err
}

func aggregateLogUsageByModel(o UsageAggOpts, tenantTokenSum int64) ([]UsageModelAgg, error) {
	var rows []struct {
		ModelName string `gorm:"column:model_name"`
		Quota     int64
		Tu        int64
		C         int64
	}
	err := baseLogUsageQuery(o).
		Select("logs.model_name as model_name, COALESCE(SUM(logs.quota),0) as quota, COALESCE(SUM(logs.prompt_tokens)+SUM(logs.completion_tokens),0) as tu, COUNT(*) as c").
		Group("logs.model_name").
		Order("COALESCE(SUM(logs.prompt_tokens)+SUM(logs.completion_tokens),0) DESC").
		Find(&rows).Error
	if err != nil {
		return nil, err
	}
	out := make([]UsageModelAgg, 0, len(rows))
	for _, r := range rows {
		share := 0.0
		if tenantTokenSum > 0 {
			share = 100.0 * float64(r.Tu) / float64(tenantTokenSum)
		}
		out = append(out, UsageModelAgg{
			ModelName:        r.ModelName,
			PromptTokens:     r.Tu,
			CompletionTokens: 0,
			ConsumeRows:      r.C,
			ErrorRows:        0,
			TokenTotal:       r.Tu,
			QuotaUsed:        r.Quota,
			UsageAmount:      r.Tu,
			UsageCount:       r.C,
			OkRate:           100,
			TokenShare:       share,
		})
	}
	return out, nil
}

func queryLogDailyUsage(o UsageAggOpts, tzOffsetSec int64) (map[int64]UsageDailyRow, error) {
	dayExpr := usageDayExpr("logs", tzOffsetSec)
	var parts []struct {
		DayID int64 `gorm:"column:day_id"`
		Quota int64
		Tu    int64
		C     int64
	}
	err := baseLogUsageQuery(o).
		Select(dayExpr + " as day_id, COALESCE(SUM(logs.quota),0) as quota, COALESCE(SUM(logs.prompt_tokens)+SUM(logs.completion_tokens),0) as tu, COUNT(*) as c").
		Group(dayExpr).
		Order(dayExpr + " ASC").
		Find(&parts).Error
	if err != nil {
		return nil, err
	}
	out := make(map[int64]UsageDailyRow, len(parts))
	for _, r := range parts {
		out[r.DayID] = usageDailyRowFromParts(r.DayID, r.Tu, r.C, r.Quota, tzOffsetSec)
	}
	return out, nil
}

func usageDailyRowFromParts(dayID, tu, c, quota int64, tzOffsetSec int64) UsageDailyRow {
	return UsageDailyRow{
		Date:             dayIDToDateStr(dayID, tzOffsetSec),
		DayID:            dayID,
		PromptTokens:     tu,
		CompletionTokens: 0,
		ConsumeRows:      c,
		ErrorRows:        0,
		TokenTotal:       tu,
		QuotaUsed:        quota,
		UsageAmount:      tu,
		UsageCount:       c,
		OkRate:           100,
	}
}

func fillUsageDailyRows(startTs, endTs, tzOffsetSec int64, byDay map[int64]UsageDailyRow) []UsageDailyRow {
	dayIDs := enumerateDayIDs(startTs, endTs, tzOffsetSec)
	out := make([]UsageDailyRow, 0, len(dayIDs))
	for _, dayID := range dayIDs {
		if row, ok := byDay[dayID]; ok {
			out = append(out, row)
			continue
		}
		out = append(out, usageDailyRowFromParts(dayID, 0, 0, 0, tzOffsetSec))
	}
	return out
}

// UsageTotals 为兼容原 JSON 字段：prompt+completion 对应「Token 量」；无错误维度时 error_rows=0。
// 非日志口径下：prompt_tokens = quota_data.token_used 合计，completion_tokens=0，consume_rows=请求次数合计。
type UsageTotals struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	ConsumeRows      int64 `json:"consume_rows"`
	ErrorRows        int64 `json:"error_rows"`
}

func queryQuotaTotals(o UsageAggOpts) (UsageTotals, error) {
	var out UsageTotals
	var row struct {
		Tu int64 `gorm:"column:tu"`
		C  int64 `gorm:"column:c"`
	}
	err := baseQuotaDataQuery(o).
		Select("COALESCE(SUM(quota_data.token_used),0) as tu, COALESCE(SUM(quota_data.count),0) as c").
		Scan(&row).Error
	if err != nil {
		return out, err
	}
	out.PromptTokens = row.Tu
	out.CompletionTokens = 0
	out.ConsumeRows = row.C
	out.ErrorRows = 0
	return out, nil
}

// UsageModelAgg 按模型聚合。
type UsageModelAgg struct {
	ModelName        string  `json:"model_name"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	ConsumeRows      int64   `json:"consume_rows"`
	ErrorRows        int64   `json:"error_rows"`
	TokenTotal       int64   `json:"token_total"`
	QuotaUsed        int64   `json:"quota_used"`
	UsageAmount      int64   `json:"usage_amount"` // Token 总量（prompt+completion）
	UsageCount       int64   `json:"usage_count"`  // 请求次数
	OkRate           float64 `json:"ok_rate"`
	TokenShare       float64 `json:"token_share"`
}

func aggregateQuotaByModel(o UsageAggOpts, tenantTokenSum int64) ([]UsageModelAgg, error) {
	var rows []struct {
		ModelName string `gorm:"column:model_name"`
		Tu        int64
		C         int64
	}
	err := baseQuotaDataQuery(o).
		Select("quota_data.model_name as model_name, COALESCE(SUM(quota_data.token_used),0) as tu, COALESCE(SUM(quota_data.count),0) as c").
		Group("quota_data.model_name").
		Order("COALESCE(SUM(quota_data.token_used),0) DESC").
		Find(&rows).Error
	if err != nil {
		return nil, err
	}
	out := make([]UsageModelAgg, 0, len(rows))
	for _, r := range rows {
		share := 0.0
		if tenantTokenSum > 0 {
			share = 100.0 * float64(r.Tu) / float64(tenantTokenSum)
		}
		out = append(out, UsageModelAgg{
			ModelName:        r.ModelName,
			PromptTokens:     r.Tu,
			CompletionTokens: 0,
			ConsumeRows:      r.C,
			ErrorRows:        0,
			TokenTotal:       r.Tu,
			QuotaUsed:        0,
			UsageAmount:      r.Tu,
			UsageCount:       r.C,
			OkRate:           100,
			TokenShare:       share,
		})
	}
	return out, nil
}

// PrepareUsageModelLikePattern 将请求中的 model_name 转为安全 LIKE 模式；空字符串表示不过滤。
func PrepareUsageModelLikePattern(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	return sanitizeLikePattern(raw)
}

// UsageByKeyPayload 单 Key 在指定时间窗内的用量（消费日志聚合）及令牌元信息。
type UsageByKeyPayload struct {
	TokenName        string           `json:"token_name"`
	TokenId          int              `json:"token_id"`
	StartDate        string           `json:"start_date"` // YYYY-MM-DD（与请求时间窗一致）
	EndDate          string           `json:"end_date"`
	QuotaUsed        int64            `json:"quota_used"`
	TokenUsed        int64            `json:"token_used"`
	RequestCount     int64            `json:"request_count"`
	UsageAmount      int64            `json:"usage_amount"` // = token_used
	UsageCount       int64            `json:"usage_count"`  // = request_count
	UsedQuota        int              `json:"used_quota"`   // 令牌表累计
	RemainQuota      int              `json:"remain_quota"`
	UnlimitedQuota   bool             `json:"unlimited_quota"`
	AccessedTime     int64            `json:"accessed_time"`
	CreatedTime      int64            `json:"created_time"`
	ModelLimits      string           `json:"model_limits,omitempty"`
	Daily            []UsageDailyRow  `json:"daily"`    // 时间窗内按自然日拆分（含无数据日 0）
	ByModel          []UsageModelAgg  `json:"by_model"`
	TimeRangeUnix    map[string]int64 `json:"time_range_unix"`
}

func usageDateLabels(startTs, endTs, tzOffsetSec int64) (startDate, endDate string) {
	if startTs <= 0 || endTs <= 0 {
		return "", ""
	}
	startDate = dayIDToDateStr((startTs+tzOffsetSec)/86400, tzOffsetSec)
	endDate = dayIDToDateStr((endTs+tzOffsetSec)/86400, tzOffsetSec)
	return startDate, endDate
}

// GetUsageByKey 单 Key 在 time range 内的使用量（Token/额度）与使用次数（请求数），数据来自消费日志。
func GetUsageByKey(o UsageAggOpts, tzOffsetSec int64) (*UsageByKeyPayload, error) {
	tokenName := strings.TrimSpace(o.TokenName)
	if tokenName == "" {
		return nil, errors.New("token_name 不能为空")
	}
	var t Token
	err := DB.Select("id", "name", "used_quota", "remain_quota", "unlimited_quota", "accessed_time", "created_time", "model_limits").
		Where("user_id = ? AND name = ?", o.UserId, tokenName).First(&t).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, errors.New("令牌不存在或不属于该用户")
		}
		return nil, err
	}
	o.TokenName = t.Name
	totals, err := queryLogUsageTotals(o)
	if err != nil {
		return nil, err
	}
	byModel, err := aggregateLogUsageByModel(o, totals.Tu)
	if err != nil {
		return nil, err
	}
	byDay, err := queryLogDailyUsage(o, tzOffsetSec)
	if err != nil {
		return nil, err
	}
	daily := fillUsageDailyRows(o.StartTs, o.EndTs, tzOffsetSec, byDay)
	startDate, endDate := usageDateLabels(o.StartTs, o.EndTs, tzOffsetSec)
	ml := ""
	if t.ModelLimits != "" {
		ml = t.ModelLimits
	}
	return &UsageByKeyPayload{
		TokenName:      t.Name,
		TokenId:        t.Id,
		StartDate:      startDate,
		EndDate:        endDate,
		QuotaUsed:      totals.Quota,
		TokenUsed:      totals.Tu,
		RequestCount:   totals.C,
		UsageAmount:    totals.Tu,
		UsageCount:     totals.C,
		UsedQuota:      t.UsedQuota,
		RemainQuota:    t.RemainQuota,
		UnlimitedQuota: t.UnlimitedQuota,
		AccessedTime:   t.AccessedTime,
		CreatedTime:    t.CreatedTime,
		ModelLimits:    ml,
		Daily:          daily,
		ByModel:        byModel,
		TimeRangeUnix:  map[string]int64{"start": o.StartTs, "end": o.EndTs},
	}, nil
}

// UsageOverviewResult PRD §4。
type UsageOverviewResult struct {
	Current       UsageOverviewSnapshot  `json:"current"`
	Previous      *UsageOverviewSnapshot `json:"previous,omitempty"`
	TotalKeys     int64                  `json:"total_keys"`
	ActiveKeys    int64                  `json:"active_keys"` // accessed_time 落在时间窗内的令牌数
	TimezoneNotes string                 `json:"timezone_notes"`
}

type UsageOverviewSnapshot struct {
	UsageTotals
	TokenSum int64 `json:"token_total"`
}

// GetUsageOverview 基于 quota_data + tokens。
func GetUsageOverview(o UsageAggOpts, comparePrev bool, tzOffsetSec int64) (*UsageOverviewResult, error) {
	if o.TokenName != "" {
		return nil, errors.New("overview 不应带 token_name，请留空")
	}
	totals, err := queryQuotaTotals(o)
	if err != nil {
		return nil, err
	}
	var active int64
	err = DB.Model(&Token{}).
		Where("user_id = ? AND accessed_time >= ? AND accessed_time <= ?", o.UserId, o.StartTs, o.EndTs).
		Count(&active).Error
	if err != nil {
		return nil, err
	}
	tk, err := CountUserTokens(o.UserId)
	if err != nil {
		return nil, err
	}
	res := &UsageOverviewResult{
		Current: UsageOverviewSnapshot{
			UsageTotals: totals,
			TokenSum:    totals.PromptTokens + totals.CompletionTokens,
		},
		TotalKeys:     tk,
		ActiveKeys:    active,
		TimezoneNotes: "指标来自 quota_data（需开启数据导出写入）；active_keys 按令牌 accessed_time 落在时间窗内统计。环比为上一等长 Unix 窗口的 quota_data 合计。",
	}
	if comparePrev && o.StartTs > 0 && o.EndTs > 0 {
		dur := o.EndTs - o.StartTs
		prevEnd := o.StartTs - 1
		prevStart := prevEnd - dur
		po := o
		po.StartTs = prevStart
		po.EndTs = prevEnd
		pt, err := queryQuotaTotals(po)
		if err != nil {
			return nil, err
		}
		res.Previous = &UsageOverviewSnapshot{
			UsageTotals: pt,
			TokenSum:    pt.PromptTokens + pt.CompletionTokens,
		}
	}
	_ = tzOffsetSec
	return res, nil
}

// UsageDailyRow 按自然日聚合的用量与次数。
type UsageDailyRow struct {
	Date             string  `json:"date"`
	DayID            int64   `json:"day_id"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	ConsumeRows      int64   `json:"consume_rows"`
	ErrorRows        int64   `json:"error_rows"`
	TokenTotal       int64   `json:"token_total"`
	QuotaUsed        int64   `json:"quota_used"`
	UsageAmount      int64   `json:"usage_amount"` // = token_total
	UsageCount       int64   `json:"usage_count"`  // = consume_rows
	OkRate           float64 `json:"ok_rate"`
}

func queryQuotaDailyUsage(o UsageAggOpts, tzOffsetSec int64) (map[int64]UsageDailyRow, error) {
	dayExpr := usageDayExpr("quota_data", tzOffsetSec)
	var parts []struct {
		DayID int64 `gorm:"column:day_id"`
		Tu    int64
		C     int64
	}
	err := baseQuotaDataQuery(o).
		Select(dayExpr + " as day_id, COALESCE(SUM(quota_data.token_used),0) as tu, COALESCE(SUM(quota_data.count),0) as c").
		Group(dayExpr).
		Order(dayExpr + " ASC").
		Find(&parts).Error
	if err != nil {
		return nil, err
	}
	out := make(map[int64]UsageDailyRow, len(parts))
	for _, r := range parts {
		out[r.DayID] = usageDailyRowFromParts(r.DayID, r.Tu, r.C, 0, tzOffsetSec)
	}
	return out, nil
}

// GetUsageDailyTrend 按日聚合；租户级读 quota_data，指定 token_name 时读消费日志；补全时间窗内无数据的日期。
func GetUsageDailyTrend(o UsageAggOpts, tzOffsetSec int64) ([]UsageDailyRow, error) {
	var byDay map[int64]UsageDailyRow
	var err error
	if strings.TrimSpace(o.TokenName) != "" {
		byDay, err = queryLogDailyUsage(o, tzOffsetSec)
	} else {
		byDay, err = queryQuotaDailyUsage(o, tzOffsetSec)
	}
	if err != nil {
		return nil, err
	}
	return fillUsageDailyRows(o.StartTs, o.EndTs, tzOffsetSec, byDay), nil
}

// GetUsageByModel 时间段内按模型统计；指定 token_name 或 group 时读消费日志，否则读 quota_data。
func GetUsageByModel(o UsageAggOpts) ([]UsageModelAgg, error) {
	if strings.TrimSpace(o.TokenName) != "" || strings.TrimSpace(o.Group) != "" {
		totals, err := queryLogUsageTotals(o)
		if err != nil {
			return nil, err
		}
		return aggregateLogUsageByModel(o, totals.Tu)
	}
	totals, err := queryQuotaTotals(o)
	if err != nil {
		return nil, err
	}
	sum := totals.PromptTokens + totals.CompletionTokens
	return aggregateQuotaByModel(o, sum)
}

// UsageKeyRankRow PRD §7：按令牌表 used_quota 排行（时间窗内消耗量无分 Key 非日志存储）。
type UsageKeyRankRow struct {
	TokenName        string   `json:"token_name"`
	PromptTokens     int64    `json:"prompt_tokens"`     // 映射 used_quota
	CompletionTokens int64    `json:"completion_tokens"` // 0
	ConsumeRows      int64    `json:"consume_rows"`      // 0
	ErrorRows        int64    `json:"error_rows"`        // 0
	TokenTotal       int64    `json:"token_total"`       // = used_quota
	OkRate           float64  `json:"ok_rate"`
	LastUsedAt       int64    `json:"last_used_at"`
	TopModel         string   `json:"top_model"`
	ModelsBreakdown  []string `json:"models_breakdown,omitempty"`
}

// GetUsageKeysRanking rank_by: "used_quota"（默认）或 "accessed_in_range"（仅列出时间窗内有访问的 Key，仍按 used_quota 排序）。
func GetUsageKeysRanking(o UsageAggOpts, page, pageSize int, rankBy string) (items []UsageKeyRankRow, total int64, err error) {
	if o.TokenName != "" {
		return nil, 0, errors.New("ranking 不应带 token_name")
	}
	if page < 1 {
		page = 1
	}
	if pageSize < 1 {
		pageSize = 10
	}
	if pageSize > 100 {
		pageSize = 100
	}
	q := DB.Model(&Token{}).Where("user_id = ?", o.UserId)
	if rankBy == "accessed_in_range" {
		q = q.Where("accessed_time >= ? AND accessed_time <= ?", o.StartTs, o.EndTs)
	}
	err = q.Count(&total).Error
	if err != nil {
		return nil, 0, err
	}
	start := (page - 1) * pageSize
	var tokens []Token
	err = q.Select("name", "used_quota", "remain_quota", "accessed_time").
		Order("used_quota DESC, id DESC").
		Offset(start).Limit(pageSize).
		Find(&tokens).Error
	if err != nil {
		return nil, 0, err
	}
	items = make([]UsageKeyRankRow, 0, len(tokens))
	for _, t := range tokens {
		uq := int64(t.UsedQuota)
		items = append(items, UsageKeyRankRow{
			TokenName:        t.Name,
			PromptTokens:     uq,
			CompletionTokens: 0,
			ConsumeRows:      0,
			ErrorRows:        0,
			TokenTotal:       uq,
			OkRate:           100,
			LastUsedAt:       t.AccessedTime,
			TopModel:         "",
		})
	}
	return items, total, nil
}
