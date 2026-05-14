/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import { z } from 'zod'
import { parseQuotaFromDollars, quotaUnitsToDollars } from '@/lib/format'
import { DEFAULT_GROUP } from '../constants'
import { type ApiKeyFormData, type ApiKey } from '../types'

// ============================================================================
// Form Schema
// ============================================================================

const modelQuotaRowSchema = z.object({
  model: z.string(),
  max_tokens: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  max_calls: z.number().int().min(0).max(1_000_000_000),
})

export const apiKeyFormSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  remain_quota_dollars: z.number().min(0).optional(),
  expired_time: z.date().optional(),
  unlimited_quota: z.boolean(),
  model_limits: z.array(z.string()),
  allow_ips: z.string().optional(),
  group: z.string().optional(),
  cross_group_retry: z.boolean().optional(),
  tokenCount: z.number().min(1).optional(),
  rate_limit_rpm: z.number().int().min(0).max(10_000_000),
  rate_limit_tpm: z.number().int().min(0).max(1_000_000_000),
  model_quota_limits: z.array(modelQuotaRowSchema),
})

export type ApiKeyFormValues = z.infer<typeof apiKeyFormSchema>

// ============================================================================
// Form Defaults
// ============================================================================

export const API_KEY_FORM_DEFAULT_VALUES: ApiKeyFormValues = {
  name: '',
  remain_quota_dollars: 10,
  expired_time: undefined,
  unlimited_quota: true,
  model_limits: [],
  allow_ips: '',
  group: DEFAULT_GROUP,
  cross_group_retry: true,
  tokenCount: 1,
  rate_limit_rpm: 0,
  rate_limit_tpm: 0,
  model_quota_limits: [],
}

export function getApiKeyFormDefaultValues(
  defaultUseAutoGroup: boolean
): ApiKeyFormValues {
  return {
    ...API_KEY_FORM_DEFAULT_VALUES,
    group: defaultUseAutoGroup ? 'auto' : DEFAULT_GROUP,
    cross_group_retry: defaultUseAutoGroup,
  }
}

function parseModelQuotaLimitsFromApi(
  raw: string | null | undefined
): ApiKeyFormValues['model_quota_limits'] {
  if (!raw?.trim()) {
    return []
  }
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) {
      return []
    }
    const rows: ApiKeyFormValues['model_quota_limits'] = []
    for (const item of parsed) {
      if (!item || typeof item !== 'object') {
        continue
      }
      const o = item as Record<string, unknown>
      const model = typeof o.model === 'string' ? o.model : ''
      const maxTokens = typeof o.max_tokens === 'number' ? o.max_tokens : 0
      const maxCalls = typeof o.max_calls === 'number' ? o.max_calls : 0
      rows.push({
        model,
        max_tokens: maxTokens,
        max_calls: maxCalls,
      })
    }
    return rows
  } catch {
    return []
  }
}

// ============================================================================
// Form Data Transformation
// ============================================================================

/**
 * Transform form data to API payload
 */
export function transformFormDataToPayload(
  data: ApiKeyFormValues
): ApiKeyFormData {
  const limits = data.model_quota_limits
    .filter((r) => r.model.trim() !== '')
    .map((r) => ({
      model: r.model.trim(),
      max_tokens: r.max_tokens,
      max_calls: r.max_calls,
    }))
  return {
    name: data.name,
    remain_quota: data.unlimited_quota
      ? 0
      : parseQuotaFromDollars(data.remain_quota_dollars || 0),
    expired_time: data.expired_time
      ? Math.floor(data.expired_time.getTime() / 1000)
      : -1,
    unlimited_quota: data.unlimited_quota,
    model_limits_enabled: data.model_limits.length > 0,
    model_limits: data.model_limits.join(','),
    allow_ips: data.allow_ips || '',
    group: data.group || '',
    cross_group_retry: data.group === 'auto' ? !!data.cross_group_retry : false,
    rate_limit_rpm: data.rate_limit_rpm,
    rate_limit_tpm: data.rate_limit_tpm,
    model_quota_limits: limits.length === 0 ? '' : JSON.stringify(limits),
  }
}

/**
 * Transform API key data to form defaults
 */
export function transformApiKeyToFormDefaults(
  apiKey: ApiKey
): ApiKeyFormValues {
  return {
    name: apiKey.name,
    remain_quota_dollars: quotaUnitsToDollars(apiKey.remain_quota),
    expired_time:
      apiKey.expired_time > 0
        ? new Date(apiKey.expired_time * 1000)
        : undefined,
    unlimited_quota: apiKey.unlimited_quota,
    model_limits: apiKey.model_limits
      ? apiKey.model_limits.split(',').filter(Boolean)
      : [],
    allow_ips: apiKey.allow_ips || '',
    group: apiKey.group || DEFAULT_GROUP,
    cross_group_retry: !!apiKey.cross_group_retry,
    tokenCount: 1,
    rate_limit_rpm: apiKey.rate_limit_rpm ?? 0,
    rate_limit_tpm: apiKey.rate_limit_tpm ?? 0,
    model_quota_limits: parseModelQuotaLimitsFromApi(apiKey.model_quota_limits),
  }
}
