package service

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"
	"github.com/QuantumNous/new-api/setting/ratio_setting"

	"github.com/gin-gonic/gin"
	"github.com/go-redis/redis/v8"
	"github.com/google/uuid"
)

const tokenRelayWindowMs = 60000

var (
	tokenRpmMemOnce sync.Once
	tokenRpmMem     common.InMemoryRateLimiter
)

func tokenRelayRpmMemoryAllow(tokenId int, limit int) bool {
	if limit <= 0 {
		return true
	}
	tokenRpmMemOnce.Do(func() {
		tokenRpmMem.Init(120 * time.Second)
	})
	key := "trl:rpm:" + strconv.Itoa(tokenId)
	return tokenRpmMem.Request(key, limit, 60)
}

// tokenRpmScript atomically trims the sliding window, enforces max cardinality (RPM), then records this request.
var tokenRpmScript = redis.NewScript(`
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local member = ARGV[4]
redis.call('ZREMRANGEBYSCORE', key, '0', tostring(now - window))
if limit <= 0 then
  redis.call('ZADD', key, now, member)
  redis.call('EXPIRE', key, 180)
  return 1
end
local c = redis.call('ZCARD', key)
if tonumber(c) >= limit then
  return 0
end
redis.call('ZADD', key, now, member)
redis.call('EXPIRE', key, 180)
return 1
`)

func tokenRelayTPMKey(tokenId int) string {
	return "newapi:trl:tpm:" + strconv.Itoa(tokenId)
}

func tokenRelayRPMKey(tokenId int) string {
	return "newapi:trl:rpm:" + strconv.Itoa(tokenId)
}

func sumTokenTPMWindow(ctx context.Context, tokenId int) (int64, error) {
	key := tokenRelayTPMKey(tokenId)
	now := time.Now().UnixMilli()
	_ = common.RDB.ZRemRangeByScore(ctx, key, "0", strconv.FormatInt(now-int64(tokenRelayWindowMs), 10)).Err()
	members, err := common.RDB.ZRange(ctx, key, 0, -1).Result()
	if err != nil {
		return 0, err
	}
	var sum int64
	for _, m := range members {
		idx := strings.IndexByte(m, ':')
		if idx <= 0 {
			continue
		}
		n, err := strconv.ParseInt(m[:idx], 10, 64)
		if err != nil {
			continue
		}
		sum += n
	}
	return sum, nil
}

// EnforceTokenRelayPreflight returns a user-visible English error message and blocked=true when the request must be rejected.
func EnforceTokenRelayPreflight(c *gin.Context, shouldSelectChannel bool, requestModel string) (message string, blocked bool) {
	if !shouldSelectChannel {
		return "", false
	}
	requestModel = strings.TrimSpace(requestModel)
	if requestModel == "" {
		return "", false
	}
	tokenID := c.GetInt("token_id")
	if tokenID <= 0 {
		return "", false
	}
	key := strings.TrimSpace(c.GetString("token_key"))
	if key == "" {
		return "", false
	}
	// Always load from DB so model_quota_limits / rate limits match what was just saved (Redis cache can lag).
	tok, err := model.GetTokenByKey(key, true)
	if err != nil || tok == nil {
		return "", false
	}
	norm := ratio_setting.FormatMatchingModelName(requestModel)

	if capEntry, ok := tok.ModelQuotaLimitByNormalizedModel(norm); ok {
		usage, err := model.GetTokenModelUsage(tokenID, norm)
		if err == nil && usage != nil {
			if capEntry.MaxCalls > 0 && usage.TotalCalls >= capEntry.MaxCalls {
				return fmt.Sprintf("This API key reached its maximum request count for model %s (%d).", requestModel, capEntry.MaxCalls), true
			}
			if capEntry.MaxTokens > 0 && usage.TotalTokens >= capEntry.MaxTokens {
				return fmt.Sprintf("This API key reached its maximum token usage for model %s (%d tokens).", requestModel, capEntry.MaxTokens), true
			}
		}
	}

	if tok.RateLimitTpm > 0 {
		var sum int64
		var tpmErr error
		if common.RedisEnabled {
			ctx := context.Background()
			sum, tpmErr = sumTokenTPMWindow(ctx, tokenID)
			if tpmErr != nil {
				common.SysLog("token tpm window: " + tpmErr.Error())
			}
		} else {
			sum = common.TokenRelayTpmMemorySum(tokenID)
		}
		if tpmErr == nil && int64(tok.RateLimitTpm) <= sum {
			return fmt.Sprintf("Token rate limit: TPM exceeded (limit %d tokens per ~60s rolling window).", tok.RateLimitTpm), true
		}
	}

	if tok.RateLimitRpm > 0 {
		if common.RedisEnabled {
			ctx := context.Background()
			rpmKey := tokenRelayRPMKey(tokenID)
			now := time.Now().UnixMilli()
			member := strconv.FormatInt(now, 10) + ":" + uuid.New().String()
			v, err := tokenRpmScript.Run(ctx, common.RDB, []string{rpmKey},
				strconv.FormatInt(now, 10),
				strconv.Itoa(tokenRelayWindowMs),
				strconv.Itoa(tok.RateLimitRpm),
				member,
			).Int()
			if err != nil {
				common.SysLog("token rpm script: " + err.Error())
				return "", false
			}
			if v == 0 {
				return fmt.Sprintf("Token rate limit: RPM exceeded (limit %d requests per ~60s rolling window).", tok.RateLimitRpm), true
			}
		} else {
			if !tokenRelayRpmMemoryAllow(tokenID, tok.RateLimitRpm) {
				return fmt.Sprintf("Token rate limit: RPM exceeded (limit %d requests per ~60s rolling window).", tok.RateLimitRpm), true
			}
		}
	}

	return "", false
}
