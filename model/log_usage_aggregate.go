package model

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"gorm.io/gorm"
)

// UsageAggOpts 用量聚合过滤条件：数据来自主库 quota_data（按 user_id）与 tokens；不读 logs。
// Group 为历史字段，quota_data 无对应列，当前实现中忽略。
type UsageAggOpts struct {
	UserId    int
	StartTs   int64
	EndTs     int64
	TokenName string
	Group     string // 忽略（quota_data 无 group）
	ModelLike string // 已通过 sanitizeLikePattern，作用于 quota_data.model_name
}

const usageAggMaxRangeSeconds int64 = 400 * 86400

func ValidateUsageTimeRange(startTs, endTs int64) error {
	if startTs <= 0 || endTs <= 0 {
		return errors.New("start_timestamp 与 end_timestamp 为必填 Unix 秒")
	}
	if endTs < startTs {
		return errors.New("end_timestamp 不得小于 start_timestamp")
	}
	if endTs-startTs > usageAggMaxRangeSeconds {
		return errors.New("查询时间跨度过大")
	}
	return nil
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

// UsageModelAgg 按模型聚合（来自 quota_data：仅合计 token_used 与 count，无失败拆分）。
type UsageModelAgg struct {
	ModelName        string  `json:"model_name"`
	PromptTokens     int64   `json:"prompt_tokens"`     // 实为 token_used 合计
	CompletionTokens int64   `json:"completion_tokens"` // 非日志口径下恒为 0
	ConsumeRows      int64   `json:"consume_rows"`      // count 合计
	ErrorRows        int64   `json:"error_rows"`        // 恒 0
	TokenTotal       int64   `json:"token_total"`
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

// UsageByKeyNonLogPayload §3 不依赖日志：仅令牌表累计 + 请求时间窗说明；by_model 为空。
type UsageByKeyNonLogPayload struct {
	TokenName       string           `json:"token_name"`
	TokenId         int              `json:"token_id"`
	UsedQuota       int              `json:"used_quota"`
	RemainQuota     int              `json:"remain_quota"`
	UnlimitedQuota  bool             `json:"unlimited_quota"`
	AccessedTime    int64            `json:"accessed_time"`
	CreatedTime     int64            `json:"created_time"`
	ModelLimits     string           `json:"model_limits,omitempty"`
	ByModel         []UsageModelAgg  `json:"by_model"`
	NonLogNote      string           `json:"non_log_note"`
	RequestedWindow map[string]int64 `json:"requested_range_unix"`
}

// GetUsageByKeyNonLog 单 Key：不读 logs；时间窗内按模型明细不可用，返回令牌累计与空 by_model。
func GetUsageByKeyNonLog(userId int, tokenName string, startTs, endTs int64) (*UsageByKeyNonLogPayload, error) {
	tokenName = strings.TrimSpace(tokenName)
	if tokenName == "" {
		return nil, errors.New("token_name 不能为空")
	}
	var t Token
	err := DB.Select("id", "name", "used_quota", "remain_quota", "unlimited_quota", "accessed_time", "created_time", "model_limits").
		Where("user_id = ? AND name = ?", userId, tokenName).First(&t).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, errors.New("令牌不存在或不属于该用户")
		}
		return nil, err
	}
	ml := ""
	if t.ModelLimits != "" {
		ml = t.ModelLimits
	}
	return &UsageByKeyNonLogPayload{
		TokenName:       t.Name,
		TokenId:         t.Id,
		UsedQuota:       t.UsedQuota,
		RemainQuota:     t.RemainQuota,
		UnlimitedQuota:  t.UnlimitedQuota,
		AccessedTime:    t.AccessedTime,
		CreatedTime:     t.CreatedTime,
		ModelLimits:     ml,
		ByModel:         []UsageModelAgg{},
		NonLogNote:      "非日志口径：无单 Key 在时间窗内的按模型用量；used_quota/remain_quota 为令牌表累计。租户级按模型请用 GET /api/usage/by_model（quota_data）。",
		RequestedWindow: map[string]int64{"start": startTs, "end": endTs},
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

// UsageDailyRow PRD §5（按 quota_data.created_at 小时桶聚合成自然日）。
type UsageDailyRow struct {
	Date             string  `json:"date"`
	DayID            int64   `json:"day_id"`
	PromptTokens     int64   `json:"prompt_tokens"`
	CompletionTokens int64   `json:"completion_tokens"`
	ConsumeRows      int64   `json:"consume_rows"`
	ErrorRows        int64   `json:"error_rows"`
	TokenTotal       int64   `json:"token_total"`
	OkRate           float64 `json:"ok_rate"`
}

// GetUsageDailyTrend 按日聚合 quota_data。
func GetUsageDailyTrend(o UsageAggOpts, tzOffsetSec int64) ([]UsageDailyRow, error) {
	if o.TokenName != "" {
		return nil, errors.New("trend 请勿传 token_name")
	}
	dayExpr := fmt.Sprintf("(quota_data.created_at + %d) / 86400", tzOffsetSec)
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
	loc := time.FixedZone("usage_tz", int(tzOffsetSec))
	out := make([]UsageDailyRow, 0, len(parts))
	for _, r := range parts {
		sec := r.DayID*86400 - tzOffsetSec
		dateStr := time.Unix(sec, 0).In(loc).Format("2006-01-02")
		out = append(out, UsageDailyRow{
			Date:             dateStr,
			DayID:            r.DayID,
			PromptTokens:     r.Tu,
			CompletionTokens: 0,
			ConsumeRows:      r.C,
			ErrorRows:        0,
			TokenTotal:       r.Tu,
			OkRate:           100,
		})
	}
	return out, nil
}

// GetUsageByModel PRD §6。
func GetUsageByModel(o UsageAggOpts) ([]UsageModelAgg, error) {
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
