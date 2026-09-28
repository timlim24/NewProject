import { useEffect, useState } from 'react'
import { zodResolver } from '@hookform/resolvers/zod'
import { ArrowLeftIcon, LogOutIcon } from 'lucide-react'
import { Controller, useForm } from 'react-hook-form'
import { Link } from 'react-router'
import { toast } from 'sonner'
import { z } from 'zod'

import { PasswordInput } from '@/components/auth-layout'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import {
  useAuth,
  useChangeEmail,
  useChangePassword,
  useConfirmEmail,
  useResendEmailCode,
  useUpdateName,
  type User,
} from '@/lib/auth'

const nameSchema = z.object({
  name: z.string().trim().min(1, 'Enter your name').max(100),
})
type NameValues = z.infer<typeof nameSchema>

function NameCard({ user }: { user: User }) {
  const updateName = useUpdateName()
  const form = useForm<NameValues>({
    resolver: zodResolver(nameSchema),
    defaultValues: { name: user.name },
  })

  useEffect(() => {
    form.reset({ name: user.name })
  }, [user.name, form])

  const watchedName = form.watch('name')
  const isChanged = watchedName.trim().length > 0 && watchedName.trim() !== user.name

  const onSubmit = form.handleSubmit(({ name }) => {
    updateName.mutate(name.trim(), {
      onSuccess: () => {
        toast.success('Name updated')
      },
      onError: (error: Error) => {
        form.setError('root', { message: error.message })
      },
    })
  })

  return (
    <Card>
      <form onSubmit={onSubmit} noValidate>
        <CardHeader>
          <CardTitle>Name</CardTitle>
          <CardDescription>The name people see on your meetings.</CardDescription>
        </CardHeader>
        <CardContent>
          <FieldGroup className="gap-3">
            <Controller
              name="name"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="profile-name">Name</FieldLabel>
                  <Input
                    id="profile-name"
                    autoComplete="name"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            {form.formState.errors.root && (
              <FieldError>{form.formState.errors.root.message}</FieldError>
            )}
          </FieldGroup>
        </CardContent>
        <CardFooter className="justify-end">
          <Button type="submit" disabled={!isChanged || updateName.isPending}>
            {updateName.isPending ? 'Saving...' : 'Save name'}
          </Button>
        </CardFooter>
      </form>
    </Card>
  )
}

const emailSchema = z.object({
  email: z.email('Enter a valid email'),
})
type EmailValues = z.infer<typeof emailSchema>

const codeSchema = z.object({
  code: z.string().trim().min(1, 'Enter the verification code'),
})
type CodeValues = z.infer<typeof codeSchema>

function EmailCard({ user }: { user: User }) {
  const changeEmail = useChangeEmail()
  const confirmEmail = useConfirmEmail()
  const resendCode = useResendEmailCode()

  const [verifying, setVerifying] = useState(false)
  const [pendingEmail, setPendingEmail] = useState('')

  const emailForm = useForm<EmailValues>({
    resolver: zodResolver(emailSchema),
    defaultValues: { email: user.email },
  })

  const codeForm = useForm<CodeValues>({
    resolver: zodResolver(codeSchema),
    defaultValues: { code: '' },
  })

  useEffect(() => {
    if (!verifying) {
      emailForm.reset({ email: user.email })
    }
  }, [user.email, verifying, emailForm])

  const watchedEmail = emailForm.watch('email')
  const isEmailChanged = watchedEmail.trim().length > 0 && watchedEmail.trim() !== user.email

  const onEmailSubmit = emailForm.handleSubmit((values) => {
    const targetEmail = values.email.trim()
    changeEmail.mutate(targetEmail, {
      onSuccess: ({ needsConfirmation }) => {
        if (needsConfirmation) {
          setPendingEmail(targetEmail)
          setVerifying(true)
          codeForm.reset({ code: '' })
          toast.success(`Verification code sent to ${targetEmail}`)
        } else {
          toast.success('Email updated')
        }
      },
      onError: (error: Error) => {
        emailForm.setError('root', { message: error.message })
      },
    })
  })

  const onCodeSubmit = codeForm.handleSubmit((values) => {
    confirmEmail.mutate(values.code.trim(), {
      onSuccess: () => {
        setVerifying(false)
        setPendingEmail('')
        toast.success('Email updated')
      },
      onError: (error: Error) => {
        codeForm.setError('root', { message: error.message })
      },
    })
  })

  const onResend = () => {
    resendCode.mutate(undefined, {
      onSuccess: () => toast.success('A new code has been sent'),
      onError: (error: Error) => toast.error(error.message),
    })
  }

  const onCancel = () => {
    setVerifying(false)
    setPendingEmail('')
    emailForm.reset({ email: user.email })
    codeForm.reset({ code: '' })
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>Email</CardTitle>
        <CardDescription>
          {verifying
            ? `Enter the code Cognito sent to ${pendingEmail}`
            : 'The email address associated with your account.'}
        </CardDescription>
      </CardHeader>
      {verifying ? (
        <form onSubmit={onCodeSubmit} noValidate>
          <CardContent>
            <FieldGroup className="gap-3">
              <Controller
                name="code"
                control={codeForm.control}
                render={({ field, fieldState }) => (
                  <Field data-invalid={fieldState.invalid}>
                    <FieldLabel htmlFor="profile-code">Verification code</FieldLabel>
                    <Input
                      id="profile-code"
                      autoFocus
                      placeholder="123456"
                      aria-invalid={fieldState.invalid}
                      {...field}
                    />
                    <FieldError errors={[fieldState.error]} />
                  </Field>
                )}
              />
              {codeForm.formState.errors.root && (
                <FieldError>{codeForm.formState.errors.root.message}</FieldError>
              )}
            </FieldGroup>
          </CardContent>
          <CardFooter className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex items-center gap-2">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={onCancel}
                disabled={confirmEmail.isPending}
              >
                Cancel
              </Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={onResend}
                disabled={resendCode.isPending || confirmEmail.isPending}
              >
                {resendCode.isPending ? 'Sending...' : 'Send a new code'}
              </Button>
            </div>
            <Button type="submit" disabled={confirmEmail.isPending}>
              {confirmEmail.isPending ? 'Verifying...' : 'Verify email'}
            </Button>
          </CardFooter>
        </form>
      ) : (
        <form onSubmit={onEmailSubmit} noValidate>
          <CardContent>
            <FieldGroup className="gap-3">
              <Controller
                name="email"
                control={emailForm.control}
                render={({ field, fieldState }) => (
                  <Field data-invalid={fieldState.invalid}>
                    <FieldLabel htmlFor="profile-email">Email</FieldLabel>
                    <Input
                      id="profile-email"
                      type="email"
                      autoComplete="email"
                      aria-invalid={fieldState.invalid}
                      {...field}
                    />
                    <FieldError errors={[fieldState.error]} />
                  </Field>
                )}
              />
              {emailForm.formState.errors.root && (
                <FieldError>{emailForm.formState.errors.root.message}</FieldError>
              )}
            </FieldGroup>
          </CardContent>
          <CardFooter className="justify-end">
            <Button type="submit" disabled={!isEmailChanged || changeEmail.isPending}>
              {changeEmail.isPending ? 'Saving...' : 'Change email'}
            </Button>
          </CardFooter>
        </form>
      )}
    </Card>
  )
}

const passwordSchema = z
  .object({
    currentPassword: z.string().min(1, 'Enter your current password'),
    newPassword: z.string().min(8, 'Use at least 8 characters'),
    confirmPassword: z.string(),
  })
  .refine((v) => v.newPassword === v.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

type PasswordValues = z.infer<typeof passwordSchema>

function PasswordCard() {
  const changePassword = useChangePassword()
  const form = useForm<PasswordValues>({
    resolver: zodResolver(passwordSchema),
    defaultValues: {
      currentPassword: '',
      newPassword: '',
      confirmPassword: '',
    },
  })

  const onSubmit = form.handleSubmit(({ currentPassword, newPassword }) => {
    changePassword.mutate(
      { currentPassword, newPassword },
      {
        onSuccess: () => {
          form.reset()
          toast.success('Password changed')
        },
        onError: (error: Error) => {
          if (error.message === 'Current password is wrong') {
            form.setError('currentPassword', { message: error.message })
          } else {
            form.setError('root', { message: error.message })
          }
        },
      },
    )
  })

  return (
    <Card>
      <form onSubmit={onSubmit} noValidate>
        <CardHeader>
          <CardTitle>Password</CardTitle>
          <CardDescription>Update your password to keep your account secure.</CardDescription>
        </CardHeader>
        <CardContent>
          <FieldGroup className="gap-3">
            <Controller
              name="currentPassword"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="profile-current-password">Current password</FieldLabel>
                  <PasswordInput
                    id="profile-current-password"
                    autoComplete="current-password"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            <Controller
              name="newPassword"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="profile-new-password">New password</FieldLabel>
                  <PasswordInput
                    id="profile-new-password"
                    autoComplete="new-password"
                    placeholder="At least 8 characters"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            <Controller
              name="confirmPassword"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="profile-confirm-password">Confirm new password</FieldLabel>
                  <PasswordInput
                    id="profile-confirm-password"
                    autoComplete="new-password"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            {form.formState.errors.root && (
              <FieldError>{form.formState.errors.root.message}</FieldError>
            )}
          </FieldGroup>
        </CardContent>
        <CardFooter className="justify-end">
          <Button type="submit" disabled={changePassword.isPending}>
            {changePassword.isPending ? 'Updating...' : 'Change password'}
          </Button>
        </CardFooter>
      </form>
    </Card>
  )
}

export function ProfilePage() {
  const { user, signOut } = useAuth()

  if (!user) return null

  return (
    <div className="mx-auto flex min-h-svh max-w-xl flex-col gap-6 px-4 py-8 md:py-12">
      <header className="flex items-center gap-4">
        <Link
          to="/home"
          className="flex size-10 shrink-0 items-center justify-center rounded-full border border-border bg-card text-foreground transition-colors hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none"
          aria-label="Back to meetings"
          title="Back to meetings"
        >
          <ArrowLeftIcon className="size-5" />
        </Link>
        <div className="flex size-12 shrink-0 items-center justify-center rounded-full bg-secondary text-lg font-semibold text-secondary-foreground">
          {user.name.charAt(0).toUpperCase()}
        </div>
        <div className="min-w-0 flex-1">
          <h1 className="truncate text-3xl leading-tight font-medium">{user.name}</h1>
          <p className="truncate text-sm text-muted-foreground">{user.email}</p>
        </div>
      </header>
      <div className="hairline" />

      <main className="flex flex-col gap-6">
        {user.provider === 'google' ? (
          <Card>
            <CardHeader>
              <CardTitle>Google account</CardTitle>
              <CardDescription>
                Your account is managed by Google. Your name and email are synced automatically at
                sign-in and cannot be changed here.
              </CardDescription>
            </CardHeader>
          </Card>
        ) : (
          <>
            <NameCard user={user} />
            <EmailCard user={user} />
            <PasswordCard />
          </>
        )}
      </main>

      <div className="mt-2 flex justify-center">
        <Button variant="outline" onClick={signOut}>
          <LogOutIcon />
          Sign out
        </Button>
      </div>
    </div>
  )
}
