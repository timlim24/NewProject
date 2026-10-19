import { signOut } from 'aws-amplify/auth'

import { getIdToken } from '@/lib/auth'

export type Participant = {
  id: string
  name: string
  email: string
}

export type Meeting = {
  id: string
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participants: Participant[]
  created_at: string
  ai_suggestion?: Record<string, unknown> | null
}

export type MeetingCreate = {
  title: string
  description: string
  starts_at: string
  ends_at: string
  place: string
  participant_ids: string[]
  ai_suggestion?: Record<string, unknown> | null
}

export type AgendaItem = {
  topic: string
  owner?: string | null
  minutes?: number | null
}

export type ActionItem = {
  task: string
  owner?: string | null
  due?: string | null
}

export type ParsedAgenda = {
  title?: string | null
  starts_at?: string | null
  duration_minutes?: number | null
  items: AgendaItem[]
  action_items?: ActionItem[]
  language: string
}

export type ParseAgendaResponse = {
  agenda: ParsedAgenda
  model: string
  prompt_version: string
}

export type ParticipantCreate = {
  name: string
  email: string
}

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

// Backend origin, set at build time for AWS (the Lambda function URL). Empty locally,
// where the Vite dev server or nginx proxies /api to the backend.
const API_URL = (import.meta.env.VITE_API_URL ?? '').replace(/\/+$/, '')
const PARSER_URL = (import.meta.env.VITE_AGENDA_PARSER_URL ?? '').replace(/\/+$/, '')

type ValidationIssue = { loc?: (string | number)[]; msg: string }

function errorMessage(detail: unknown, fallback: string): string {
  if (typeof detail === 'string') return detail
  if (Array.isArray(detail)) {
    return (detail as ValidationIssue[])
      .map((issue) => {
        const field = issue.loc?.filter((part) => part !== 'body').join('.')
        const msg = issue.msg.replace(/^Value error, /, '')
        return field ? `${field}: ${msg}` : msg
      })
      .join('; ')
  }
  return fallback
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = await getIdToken()
  const response = await fetch(`${API_URL}/api${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token && { Authorization: `Bearer ${token}` }),
      ...init?.headers,
    },
  })

  // The session is gone (revoked, or the refresh token expired): sign out, which sends the
  // user back to the login page (see AuthProvider).
  if (response.status === 401) await signOut().catch(() => undefined)

  if (!response.ok) {
    let detail: unknown
    try {
      detail = (await response.json()).detail
    } catch {
      // body was not JSON
    }
    throw new ApiError(response.status, errorMessage(detail, response.statusText))
  }

  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

export async function parseAgenda(
  text: string,
  signal?: AbortSignal
): Promise<ParseAgendaResponse> {
  const token = await getIdToken()
  if (!token) throw new ApiError(401, 'Please sign in first.')

  const today = new Date().toISOString().slice(0, 10)
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Kyiv'

  // If deployed parser function URL exists, use it directly (outside VPC, no extra hops).
  // Otherwise fall back to local backend route /api/ai/parse in dev mode.
  const endpoint =
    PARSER_URL ||
    (import.meta.env.DEV
      ? `${API_URL}/api/ai/parse`
      : 'https://wwq74vankmuw6wpcww4ljdk33m0hsbaw.lambda-url.us-east-1.on.aws')

  const response = await fetch(endpoint, {
    method: 'POST',
    signal,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ text, today, tz }),
  })

  if (!response.ok) {
    let errorDetail = response.statusText
    try {
      const data = await response.json()
      errorDetail = data.error || data.detail || errorDetail
    } catch {
      // body was not JSON
    }
    if (response.status === 413) {
      throw new ApiError(413, errorDetail || 'Text is too long (maximum 10,000 characters).')
    }
    if (response.status === 422) {
      throw new ApiError(422, errorDetail || 'Could not find a structured agenda in the text.')
    }
    if (response.status === 429) {
      throw new ApiError(429, 'Bedrock service is busy. Please try again in a few moments.')
    }
    throw new ApiError(response.status, errorDetail || 'Failed to parse agenda')
  }

  return (await response.json()) as ParseAgendaResponse
}

export const api = {
  listMeetings: () => request<Meeting[]>('/meetings'),
  createMeeting: (data: MeetingCreate) =>
    request<Meeting>('/meetings', { method: 'POST', body: JSON.stringify(data) }),
  updateMeeting: ({ id, ...data }: MeetingCreate & { id: string }) =>
    request<Meeting>(`/meetings/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteMeeting: (id: string) => request<void>(`/meetings/${id}`, { method: 'DELETE' }),
  listParticipants: () => request<Participant[]>('/participants'),
  createParticipant: (data: ParticipantCreate) =>
    request<Participant>('/participants', { method: 'POST', body: JSON.stringify(data) }),
  parseAgenda,
}
