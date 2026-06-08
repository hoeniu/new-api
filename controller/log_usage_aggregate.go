package controller

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"

	"github.com/gin-gonic/gin"
)

func resolveUsageTargetUserId(c *gin.Context) (int, error) {
	callerId := c.GetInt("id")
	u := strings.TrimSpace(c.Query("username"))
	if u == "" {
		return callerId, nil
	}
	if !model.IsAdmin(callerId) {
		return 0, errors.New("无权限使用 username 查询其他用户")
	}
	return model.GetUserIdByUsername(u)
}

func parseUsageAggOpts(c *gin.Context) (model.UsageAggOpts, error) {
	start, _ := strconv.ParseInt(c.Query("start_timestamp"), 10, 64)
	end, _ := strconv.ParseInt(c.Query("end_timestamp"), 10, 64)
	off := parseTimezoneOffsetSec(c)
	start, end, err := model.ResolveUsageTimeRange(start, end, c.Query("start_date"), c.Query("end_date"), off)
	if err != nil {
		return model.UsageAggOpts{}, err
	}
	uid, err := resolveUsageTargetUserId(c)
	if err != nil {
		return model.UsageAggOpts{}, err
	}
	ml, err := model.PrepareUsageModelLikePattern(c.Query("model_name"))
	if err != nil {
		return model.UsageAggOpts{}, err
	}
	return model.UsageAggOpts{
		UserId:    uid,
		StartTs:   start,
		EndTs:     end,
		TokenName: strings.TrimSpace(c.Query("token_name")),
		Group:     strings.TrimSpace(c.Query("group")),
		ModelLike: ml,
	}, nil
}

func parseTimezoneOffsetSec(c *gin.Context) int64 {
	v := strings.TrimSpace(c.DefaultQuery("timezone_offset", "28800"))
	off, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 28800
	}
	if off < -50400 || off > 50400 {
		return 28800
	}
	return off
}

// GetUsageByKey GET /api/usage/by_key — 指定 Key 在时间窗内的使用量（Token/额度）与使用次数。
func GetUsageByKey(c *gin.Context) {
	o, err := parseUsageAggOpts(c)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": err.Error()})
		return
	}
	if o.TokenName == "" {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": "token_name 必填"})
		return
	}
	ok, err := model.TokenNameBelongsToUser(o.UserId, o.TokenName)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	if !ok {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": "令牌不存在或不属于该用户"})
		return
	}
	off := parseTimezoneOffsetSec(c)
	payload, err := model.GetUsageByKey(o, off)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	common.ApiSuccess(c, gin.H{
		"data_source":     "logs.consume",
		"usage":           payload,
		"timezone_offset": off,
		"time_range": gin.H{
			"start_date": payload.StartDate,
			"end_date":   payload.EndDate,
			"start":      o.StartTs,
			"end":        o.EndTs,
		},
	})
}

// GetUsageOverview GET /api/usage/overview — PRD §4，数据来自 quota_data + tokens。
func GetUsageOverview(c *gin.Context) {
	o, err := parseUsageAggOpts(c)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": err.Error()})
		return
	}
	if o.TokenName != "" {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": "overview 请勿传 token_name"})
		return
	}
	compare := c.DefaultQuery("compare_prev", "0") == "1"
	off := parseTimezoneOffsetSec(c)
	data, err := model.GetUsageOverview(o, compare, off)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	denom := data.Current.ConsumeRows + data.Current.ErrorRows
	var rate float64
	if denom > 0 {
		rate = 100.0
	}
	common.ApiSuccess(c, gin.H{
		"data_source":     "main_db.quota_data",
		"overview":        data,
		"success_rate":    rate,
		"non_log_note":    "无错误日志维度：success_rate 在无日志口径下恒为 100%（或 0 请求时 0）。",
		"time_range_unix": gin.H{"start": o.StartTs, "end": o.EndTs},
	})
}

// GetUsageDailyTrend GET /api/usage/trend/daily — 时间窗内按自然日返回使用量与使用次数；支持 start_date/end_date。
func GetUsageDailyTrend(c *gin.Context) {
	o, err := parseUsageAggOpts(c)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": err.Error()})
		return
	}
	off := parseTimezoneOffsetSec(c)
	rows, err := model.GetUsageDailyTrend(o, off)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	dataSource := "main_db.quota_data"
	if o.TokenName != "" {
		dataSource = "logs.consume"
	}
	common.ApiSuccess(c, gin.H{
		"data_source":     dataSource,
		"daily":           rows,
		"timezone_offset": off,
		"time_range_unix": gin.H{"start": o.StartTs, "end": o.EndTs},
	})
}

// GetUsageByModel GET /api/usage/by_model — 时间窗内按模型统计使用量与使用次数。
func GetUsageByModel(c *gin.Context) {
	o, err := parseUsageAggOpts(c)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": err.Error()})
		return
	}
	if o.TokenName != "" {
		ok, err := model.TokenNameBelongsToUser(o.UserId, o.TokenName)
		if err != nil {
			common.ApiError(c, err)
			return
		}
		if !ok {
			c.JSON(http.StatusOK, gin.H{"success": false, "message": "令牌不存在或不属于该用户"})
			return
		}
	}
	rows, err := model.GetUsageByModel(o)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	dataSource := "main_db.quota_data"
	if o.TokenName != "" || o.Group != "" {
		dataSource = "logs.consume"
	}
	common.ApiSuccess(c, gin.H{
		"data_source":     dataSource,
		"by_model":        rows,
		"time_range_unix": gin.H{"start": o.StartTs, "end": o.EndTs},
	})
}

// GetUsageKeysRanking GET /api/usage/keys/ranking — PRD §7，按 tokens.used_quota；可选 rank_by=accessed_in_range。
func GetUsageKeysRanking(c *gin.Context) {
	o, err := parseUsageAggOpts(c)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": err.Error()})
		return
	}
	if o.TokenName != "" {
		c.JSON(http.StatusOK, gin.H{"success": false, "message": "ranking 请勿传 token_name"})
		return
	}
	rankBy := strings.TrimSpace(c.DefaultQuery("rank_by", "used_quota"))
	if rankBy != "used_quota" && rankBy != "accessed_in_range" {
		rankBy = "used_quota"
	}
	pageInfo := common.GetPageQuery(c)
	items, total, err := model.GetUsageKeysRanking(o, pageInfo.GetPage(), pageInfo.GetPageSize(), rankBy)
	if err != nil {
		common.ApiError(c, err)
		return
	}
	pageInfo.SetTotal(int(total))
	pageInfo.SetItems(items)
	common.ApiSuccess(c, gin.H{
		"data_source": "main_db.tokens_table",
		"rank_by":     rankBy,
		"non_log_note": "排行按累计 used_quota，非时间窗内消耗；rank_by=accessed_in_range 时先筛时间窗内有访问的 Key 再排序。",
		"page":        pageInfo.Page,
		"page_size":   pageInfo.PageSize,
		"total":       pageInfo.Total,
		"items":       pageInfo.Items,
	})
}
