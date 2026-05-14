package model

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/setting/ratio_setting"
	"github.com/google/uuid"
	"github.com/go-redis/redis/v8"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

// TokenModelUsage stores cumulative prompt+completion tokens and successful call count per token+model.
type TokenModelUsage struct {
	TokenId     int    `json:"token_id" gorm:"primaryKey"`
	ModelName   string `json:"model_name" gorm:"primaryKey;size:191"` // normalized (FormatMatchingModelName)
	TotalTokens int64  `json:"total_tokens" gorm:"default:0"`
	TotalCalls  int    `json:"total_calls" gorm:"default:0"`
	UpdatedAt   int64  `json:"updated_at" gorm:"bigint"`
}

func (TokenModelUsage) TableName() string {
	return "token_model_usages"
}

// ParseModelQuotaLimits parses model_quota_limits JSON from a token.
func (token *Token) ParseModelQuotaLimits() ([]TokenModelQuotaEntry, error) {
	raw := strings.TrimSpace(token.ModelQuotaLimits)
	if raw == "" {
		return nil, nil
	}
	var entries []TokenModelQuotaEntry
	if err := common.UnmarshalJsonStr(raw, &entries); err != nil {
		return nil, err
	}
	out := make([]TokenModelQuotaEntry, 0, len(entries))
	for _, e := range entries {
		m := strings.TrimSpace(e.Model)
		if m == "" {
			continue
		}
		out = append(out, TokenModelQuotaEntry{
			Model:     m,
			MaxTokens: e.MaxTokens,
			MaxCalls:  e.MaxCalls,
		})
	}
	return out, nil
}

// ModelQuotaLimitByNormalizedModel returns caps for a normalized model name, or ok=false.
func (token *Token) ModelQuotaLimitByNormalizedModel(normalized string) (TokenModelQuotaEntry, bool) {
	entries, err := token.ParseModelQuotaLimits()
	if err != nil || len(entries) == 0 {
		return TokenModelQuotaEntry{}, false
	}
	for _, e := range entries {
		if ratio_setting.FormatMatchingModelName(e.Model) == normalized {
			return e, true
		}
	}
	return TokenModelQuotaEntry{}, false
}

// GetTokenModelUsage returns persisted usage for a token+model (normalized name).
func GetTokenModelUsage(tokenId int, normalizedModel string) (*TokenModelUsage, error) {
	if tokenId <= 0 || normalizedModel == "" {
		return nil, errors.New("invalid token or model")
	}
	var row TokenModelUsage
	err := DB.Where("token_id = ? AND model_name = ?", tokenId, normalizedModel).First(&row).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return &TokenModelUsage{TokenId: tokenId, ModelName: normalizedModel, TotalTokens: 0, TotalCalls: 0}, nil
	}
	if err != nil {
		return nil, err
	}
	return &row, nil
}

// IncrTokenModelUsageAfterConsume increments cumulative tokens and calls for a successful relay.
func IncrTokenModelUsageAfterConsume(tokenId int, rawModel string, promptTokens, completionTokens int) {
	if tokenId <= 0 || strings.TrimSpace(rawModel) == "" {
		return
	}
	norm := ratio_setting.FormatMatchingModelName(rawModel)
	deltaTok := int64(promptTokens) + int64(completionTokens)
	if deltaTok < 0 {
		deltaTok = 0
	}
	ts := common.GetTimestamp()
	row := TokenModelUsage{
		TokenId:     tokenId,
		ModelName:   norm,
		TotalTokens: deltaTok,
		TotalCalls:  1,
		UpdatedAt:   ts,
	}
	err := DB.Clauses(clause.OnConflict{
		Columns: []clause.Column{{Name: "token_id"}, {Name: "model_name"}},
		DoUpdates: clause.Assignments(map[string]interface{}{
			"total_tokens": gorm.Expr("total_tokens + ?", deltaTok),
			"total_calls":  gorm.Expr("total_calls + ?", 1),
			"updated_at":   ts,
		}),
	}).Create(&row).Error
	if err != nil {
		common.SysLog("IncrTokenModelUsageAfterConsume: " + err.Error())
	}

	if !common.RedisEnabled {
		return
	}
	var tpmLimit int
	_ = DB.Model(&Token{}).Select("rate_limit_tpm").Where("id = ?", tokenId).Scan(&tpmLimit).Error
	if tpmLimit <= 0 {
		return
	}
	ctx := context.Background()
	key := "newapi:trl:tpm:" + strconv.Itoa(tokenId)
	now := time.Now().UnixMilli()
	member := strconv.FormatInt(deltaTok, 10) + ":" + uuid.New().String()
	_ = common.RDB.ZAdd(ctx, key, &redis.Z{Score: float64(now), Member: member}).Err()
	_ = common.RDB.ZRemRangeByScore(ctx, key, "0", strconv.FormatInt(now-60000, 10)).Err()
	_ = common.RDB.Expire(ctx, key, 180*time.Second).Err()
}
