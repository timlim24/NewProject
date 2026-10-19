import { useEffect, useRef, useState } from 'react'
import { zodResolver } from '@hookform/resolvers/zod'
import { addHours, addMinutes, format, isSameDay } from 'date-fns'
import { CalendarIcon, Loader2Icon, SparklesIcon } from 'lucide-react'
import { Controller, useForm } from 'react-hook-form'
import { toast } from 'sonner'
import { z } from 'zod'

import { ParticipantPicker } from '@/components/participant-picker'
import { Button } from '@/components/ui/button'
import { Calendar } from '@/components/ui/calendar'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Textarea } from '@/components/ui/textarea'
import { useCreateMeeting, useUpdateMeeting } from '@/hooks/queries'
import { api, type Meeting } from '@/lib/api'

const timePattern = /^\d{2}:\d{2}$/

const meetingSchema = z
  .object({
    title: z.string().trim().min(1, 'Title is required').max(200),
    description: z.string(),
    date: z.date({ error: 'Pick a date' }),
    startTime: z.string().regex(timePattern, 'Enter a start time'),
    endTime: z.string().regex(timePattern, 'Enter an end time'),
    place: z.string().trim().min(1, 'Place is required').max(200),
    participantIds: z.array(z.string()),
  })
  .refine((v) => v.endTime > v.startTime, {
    message: 'End time must be after start time',
    path: ['endTime'],
  })

type MeetingFormValues = z.input<typeof meetingSchema>

const defaultValues: MeetingFormValues = {
  title: '',
  description: '',
  date: undefined as unknown as Date,
  startTime: '10:00',
  endTime: '11:00',
  place: '',
  participantIds: [],
}

function toFormValues(meeting: Meeting): MeetingFormValues {
  const start = new Date(meeting.starts_at)
  return {
    title: meeting.title,
    description: meeting.description,
    date: start,
    startTime: format(start, 'HH:mm'),
    endTime: format(new Date(meeting.ends_at), 'HH:mm'),
    place: meeting.place,
    participantIds: meeting.participants.map((p) => p.id),
  }
}

/** A new meeting starting at `start` and lasting an hour (cut off at midnight). */
function newMeetingValues(start: Date): MeetingFormValues {
  const end = addHours(start, 1)
  return {
    ...defaultValues,
    date: start,
    startTime: format(start, 'HH:mm'),
    endTime: isSameDay(start, end) ? format(end, 'HH:mm') : '23:59',
  }
}

function combine(date: Date, time: string): string {
  const [hours, minutes] = time.split(':').map(Number)
  const result = new Date(date)
  result.setHours(hours, minutes, 0, 0)
  return result.toISOString()
}

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** The meeting to edit; omit to create a new one. */
  meeting?: Meeting | null
  /** Prefilled start of a new meeting, e.g. the calendar slot that was clicked. */
  initialStart?: Date | null
}

export function MeetingFormDialog({ open, onOpenChange, meeting, initialStart }: Props) {
  const [datePickerOpen, setDatePickerOpen] = useState(false)
  const [showPasteAgenda, setShowPasteAgenda] = useState(false)
  const [pasteText, setPasteText] = useState('')
  const [isParsing, setIsParsing] = useState(false)
  const [parseError, setParseError] = useState<string | null>(null)
  const [suggestedFields, setSuggestedFields] = useState<Set<string>>(new Set())
  const [aiSuggestion, setAiSuggestion] = useState<Record<string, unknown> | null>(null)
  const abortControllerRef = useRef<AbortController | null>(null)

  const createMeeting = useCreateMeeting()
  const updateMeeting = useUpdateMeeting()
  const isEditing = Boolean(meeting)
  const isPending = createMeeting.isPending || updateMeeting.isPending
  const form = useForm<MeetingFormValues>({
    resolver: zodResolver(meetingSchema),
    defaultValues,
  })

  const resetAiState = () => {
    abortControllerRef.current?.abort()
    setIsParsing(false)
    setParseError(null)
    setSuggestedFields(new Set())
    setAiSuggestion(null)
    setShowPasteAgenda(false)
    setPasteText('')
  }

  useEffect(() => {
    if (!open) return
    if (meeting) {
      form.reset(toFormValues(meeting))
      if (meeting.ai_suggestion) {
        setAiSuggestion(meeting.ai_suggestion)
      }
    } else {
      form.reset(initialStart ? newMeetingValues(initialStart) : defaultValues)
    }
  }, [open, meeting, initialStart, form])

  const close = (next: boolean) => {
    if (!next) resetAiState()
    onOpenChange(next)
  }

  const markTouched = (fieldName: string) => {
    if (suggestedFields.has(fieldName)) {
      setSuggestedFields((prev) => {
        const next = new Set(prev)
        next.delete(fieldName)
        return next
      })
    }
  }

  const handleParse = async () => {
    const textToParse = pasteText.trim()
    if (!textToParse) return
    if (textToParse.length > 10000) {
      setParseError('Text is too long (maximum 10,000 characters).')
      return
    }

    setParseError(null)
    setIsParsing(true)
    const controller = new AbortController()
    abortControllerRef.current = controller

    try {
      const res = await api.parseAgenda(textToParse, controller.signal)
      const { agenda, model, prompt_version } = res

      const newSuggested = new Set<string>()

      // Fill title
      if (agenda.title) {
        form.setValue('title', agenda.title, { shouldValidate: true })
        newSuggested.add('title')
      }

      // Fill start and end times if available
      if (agenda.starts_at) {
        try {
          const start = new Date(agenda.starts_at)
          if (!isNaN(start.getTime())) {
            form.setValue('date', start, { shouldValidate: true })
            newSuggested.add('date')
            form.setValue('startTime', format(start, 'HH:mm'), { shouldValidate: true })
            newSuggested.add('startTime')

            const durationMin = agenda.duration_minutes ?? 45
            const end = addMinutes(start, durationMin)
            form.setValue('endTime', format(end, 'HH:mm'), { shouldValidate: true })
            newSuggested.add('endTime')
          }
        } catch {
          // ignore date parse issue
        }
      } else if (agenda.duration_minutes) {
        const [sh, sm] = form.getValues('startTime').split(':').map(Number)
        const baseDate = form.getValues('date') || new Date()
        const start = new Date(baseDate)
        start.setHours(sh, sm, 0, 0)
        const end = addMinutes(start, agenda.duration_minutes)
        form.setValue('endTime', format(end, 'HH:mm'), { shouldValidate: true })
        newSuggested.add('endTime')
      }

      // Format items and action items into description
      const descParts: string[] = []
      if (agenda.items && agenda.items.length > 0) {
        descParts.push('Agenda:')
        agenda.items.forEach((item, idx) => {
          let line = `${idx + 1}. ${item.topic}`
          const details: string[] = []
          if (item.owner) details.push(item.owner)
          if (item.minutes) details.push(`${item.minutes} min`)
          if (details.length > 0) line += ` (${details.join(', ')})`
          descParts.push(line)
        })
      }

      if (agenda.action_items && agenda.action_items.length > 0) {
        if (descParts.length > 0) descParts.push('')
        descParts.push('Action items:')
        agenda.action_items.forEach((item) => {
          let line = `• ${item.task}`
          const details: string[] = []
          if (item.owner) details.push(`Owner: ${item.owner}`)
          if (item.due) details.push(`Due: ${item.due}`)
          if (details.length > 0) line += ` (${details.join(', ')})`
          descParts.push(line)
        })
      }

      if (descParts.length > 0) {
        form.setValue('description', descParts.join('\n'), { shouldValidate: true })
        newSuggested.add('description')
      }

      setSuggestedFields(newSuggested)
      setAiSuggestion({
        parsed_agenda: agenda,
        model,
        prompt_version,
        input_text: textToParse,
      })
      toast.success('Agenda parsed! Review the suggested fields.')
    } catch (err: unknown) {
      if (err instanceof Error && err.name === 'AbortError') {
        toast.info('Parsing cancelled.')
      } else {
        const msg = err instanceof Error ? err.message : 'Failed to parse agenda'
        setParseError(msg)
        toast.error(msg)
      }
    } finally {
      setIsParsing(false)
      abortControllerRef.current = null
    }
  }

  const onSubmit = form.handleSubmit((values) => {
    const data = {
      title: values.title.trim(),
      description: values.description.trim(),
      starts_at: combine(values.date, values.startTime),
      ends_at: combine(values.date, values.endTime),
      place: values.place.trim(),
      participant_ids: values.participantIds,
      ai_suggestion: aiSuggestion ?? (meeting?.ai_suggestion || undefined),
    }
    const callbacks = {
      onSuccess: (saved: Meeting) => {
        toast.success(`Meeting "${saved.title}" ${isEditing ? 'updated' : 'created'}`)
        close(false)
      },
      onError: (error: Error) => form.setError('root', { message: error.message }),
    }
    if (meeting) {
      updateMeeting.mutate({ id: meeting.id, ...data }, callbacks)
    } else {
      createMeeting.mutate(data, callbacks)
    }
  })

  const renderSuggestedBadge = (fieldName: string) => {
    if (!suggestedFields.has(fieldName)) return null
    return (
      <span className="ml-2 inline-flex items-center gap-1 rounded-full bg-blue-500/15 px-2 py-0.5 text-[11px] font-medium text-blue-600 dark:bg-blue-400/20 dark:text-blue-300">
        <SparklesIcon className="size-3" />
        Suggested
      </span>
    )
  }

  return (
    <Dialog open={open} onOpenChange={close}>
      <DialogContent className="max-h-[calc(100svh-2rem)] grid-rows-[auto_minmax(0,1fr)_auto] sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{isEditing ? 'Edit meeting' : 'Add meeting'}</DialogTitle>
          <DialogDescription>Fill in the details and pick who takes part.</DialogDescription>
        </DialogHeader>

        {/* Only the fields scroll; header and footer stay put on short screens. */}
        <form
          id="meeting-form"
          onSubmit={onSubmit}
          noValidate
          className="-mx-6 overflow-y-auto px-6 py-1"
        >
          {/* Paste an agenda panel */}
          <div className="mb-4 rounded-lg border border-border/70 bg-muted/30 p-3">
            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={() => setShowPasteAgenda((prev) => !prev)}
                className="flex items-center gap-2 text-sm font-medium text-foreground/90 transition-colors hover:text-foreground cursor-pointer"
              >
                <SparklesIcon className="size-4 text-blue-500" />
                <span>Paste an agenda</span>
                <span className="text-xs font-normal text-muted-foreground">
                  ({showPasteAgenda ? 'hide' : 'AI parse notes or email'})
                </span>
              </button>
            </div>

            {showPasteAgenda && (
              <div className="mt-3 flex flex-col gap-3">
                <Textarea
                  placeholder="Paste an email, Slack message, or raw notes here..."
                  rows={4}
                  value={pasteText}
                  onChange={(e) => setPasteText(e.target.value)}
                  disabled={isParsing}
                  className="font-mono text-xs"
                />
                {parseError && (
                  <div className="rounded-md bg-destructive/15 px-3 py-2 text-xs font-medium text-destructive">
                    {parseError}
                  </div>
                )}
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-xs text-muted-foreground">
                    {pasteText.length} / 10,000 characters
                  </span>
                  <div className="flex items-center gap-2">
                    {isParsing ? (
                      <>
                        <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                          <Loader2Icon className="size-3.5 animate-spin text-blue-500" />
                          Parsing with Amazon Bedrock...
                        </span>
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          onClick={() => abortControllerRef.current?.abort()}
                        >
                          Cancel
                        </Button>
                      </>
                    ) : (
                      <Button
                        type="button"
                        variant="secondary"
                        size="sm"
                        disabled={!pasteText.trim()}
                        onClick={handleParse}
                        className="gap-1.5"
                      >
                        <SparklesIcon className="size-3.5" />
                        Parse with AI
                      </Button>
                    )}
                  </div>
                </div>
              </div>
            )}
          </div>

          <FieldGroup>
            <Controller
              name="title"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="meeting-title">
                    Title {renderSuggestedBadge('title')}
                  </FieldLabel>
                  <Input
                    id="meeting-title"
                    aria-invalid={fieldState.invalid}
                    {...field}
                    onFocus={() => markTouched('title')}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />

            <Controller
              name="description"
              control={form.control}
              render={({ field }) => (
                <Field>
                  <FieldLabel htmlFor="meeting-description">
                    Description {renderSuggestedBadge('description')}
                  </FieldLabel>
                  <Textarea
                    id="meeting-description"
                    rows={3}
                    {...field}
                    onFocus={() => markTouched('description')}
                  />
                </Field>
              )}
            />

            <div className="grid gap-4 sm:grid-cols-[1fr_auto_auto]">
              <Controller
                name="date"
                control={form.control}
                render={({ field, fieldState }) => (
                  <Field data-invalid={fieldState.invalid}>
                    <FieldLabel htmlFor="meeting-date">
                      Date {renderSuggestedBadge('date')}
                    </FieldLabel>
                    <Popover open={datePickerOpen} onOpenChange={setDatePickerOpen}>
                      <PopoverTrigger asChild>
                        <Button
                          id="meeting-date"
                          type="button"
                          variant="outline"
                          aria-invalid={fieldState.invalid}
                          className="justify-start font-normal"
                        >
                          <CalendarIcon />
                          {field.value ? (
                            format(field.value, 'EEE, d MMM yyyy')
                          ) : (
                            <span className="text-muted-foreground">Pick a date</span>
                          )}
                        </Button>
                      </PopoverTrigger>
                      <PopoverContent className="w-auto p-0" align="start">
                        <Calendar
                          mode="single"
                          selected={field.value}
                          onSelect={(date) => {
                            markTouched('date')
                            field.onChange(date)
                            setDatePickerOpen(false)
                          }}
                          autoFocus
                        />
                      </PopoverContent>
                    </Popover>
                    <FieldError errors={[fieldState.error]} />
                  </Field>
                )}
              />
              <Controller
                name="startTime"
                control={form.control}
                render={({ field, fieldState }) => (
                  <Field data-invalid={fieldState.invalid}>
                    <FieldLabel htmlFor="meeting-start">
                      Start {renderSuggestedBadge('startTime')}
                    </FieldLabel>
                    <Input
                      id="meeting-start"
                      type="time"
                      aria-invalid={fieldState.invalid}
                      {...field}
                      onFocus={() => markTouched('startTime')}
                    />
                    <FieldError errors={[fieldState.error]} />
                  </Field>
                )}
              />
              <Controller
                name="endTime"
                control={form.control}
                render={({ field, fieldState }) => (
                  <Field data-invalid={fieldState.invalid}>
                    <FieldLabel htmlFor="meeting-end">
                      End {renderSuggestedBadge('endTime')}
                    </FieldLabel>
                    <Input
                      id="meeting-end"
                      type="time"
                      aria-invalid={fieldState.invalid}
                      {...field}
                      onFocus={() => markTouched('endTime')}
                    />
                    <FieldError errors={[fieldState.error]} />
                  </Field>
                )}
              />
            </div>

            <Controller
              name="place"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="meeting-place">Place</FieldLabel>
                  <Input
                    id="meeting-place"
                    placeholder="Room, address, or video link"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />

            <Controller
              name="participantIds"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="meeting-participants">Participants</FieldLabel>
                  <ParticipantPicker
                    id="meeting-participants"
                    value={field.value}
                    onChange={field.onChange}
                    invalid={fieldState.invalid}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />

            {form.formState.errors.root && (
              <FieldError>{form.formState.errors.root.message}</FieldError>
            )}
          </FieldGroup>
        </form>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => close(false)}>
            Cancel
          </Button>
          <Button type="submit" form="meeting-form" disabled={isPending}>
            {isPending ? 'Saving...' : isEditing ? 'Save changes' : 'Add meeting'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
