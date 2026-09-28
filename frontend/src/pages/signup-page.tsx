import { useState } from 'react'
import { zodResolver } from '@hookform/resolvers/zod'
import { Controller, useForm } from 'react-hook-form'
import { Link, useLocation, useNavigate } from 'react-router'
import { toast } from 'sonner'
import { z } from 'zod'

import { AuthLayout, GoogleButton, OrDivider, PasswordInput } from '@/components/auth-layout'
import { Button } from '@/components/ui/button'
import { Field, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { useConfirmSignup, useGoogleLogin, useResendCode, useSignup } from '@/lib/auth'

const signupSchema = z
  .object({
    name: z.string().trim().min(1, 'Enter your name').max(100),
    email: z.email('Enter a valid email'),
    password: z.string().min(8, 'Use at least 8 characters'),
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: 'Passwords do not match',
    path: ['confirmPassword'],
  })

type SignupValues = z.infer<typeof signupSchema>

const confirmSchema = z.object({
  code: z.string().trim().min(1, 'Enter the confirmation code'),
})

type ConfirmValues = z.infer<typeof confirmSchema>

export function SignupPage() {
  const navigate = useNavigate()
  const locationState = useLocation().state as { confirmEmail?: string } | null
  const [confirmingEmail, setConfirmingEmail] = useState<string | null>(
    locationState?.confirmEmail ?? null,
  )

  const signup = useSignup()
  const confirmSignup = useConfirmSignup()
  const resendCode = useResendCode()
  const googleLogin = useGoogleLogin()
  const pending = signup.isPending || googleLogin.isPending

  const form = useForm<SignupValues>({
    resolver: zodResolver(signupSchema),
    defaultValues: { name: '', email: '', password: '', confirmPassword: '' },
  })

  const confirmForm = useForm<ConfirmValues>({
    resolver: zodResolver(confirmSchema),
    defaultValues: { code: '' },
  })

  const onError = (error: Error) => form.setError('root', { message: error.message })

  const onSubmit = form.handleSubmit(({ name, email, password }) =>
    signup.mutate(
      { name: name.trim(), email: email.trim(), password },
      {
        onSuccess: ({ needsConfirmation }) => {
          if (needsConfirmation) {
            setConfirmingEmail(email.trim())
          } else {
            navigate('/home', { replace: true })
          }
        },
        onError,
      },
    ),
  )

  const onConfirmSubmit = confirmForm.handleSubmit(({ code }) => {
    if (!confirmingEmail) return
    confirmSignup.mutate(
      { email: confirmingEmail, code: code.trim() },
      {
        onSuccess: (user) => {
          if (user) {
            navigate('/home', { replace: true })
          } else {
            navigate('/login', {
              replace: true,
              state: { email: confirmingEmail, notice: 'Email confirmed. You can now sign in.' },
            })
          }
        },
        onError: (error: Error) => {
          confirmForm.setError('root', { message: error.message })
        },
      },
    )
  })

  const onResend = () => {
    if (!confirmingEmail) return
    resendCode.mutate(confirmingEmail, {
      onSuccess: () => toast.success('A new confirmation code has been sent'),
      onError: (error: Error) => toast.error(error.message),
    })
  }

  if (confirmingEmail) {
    return (
      <AuthLayout
        title="Check your email"
        subtitle={`We sent a confirmation code to ${confirmingEmail}.`}
        footer={
          <>
            Already confirmed?{' '}
            <Link
              to="/login"
              state={{ email: confirmingEmail }}
              className="font-semibold text-hover underline-offset-4 hover:underline"
            >
              Sign in
            </Link>
          </>
        }
      >
        <form onSubmit={onConfirmSubmit} noValidate>
          <FieldGroup className="gap-4 short:gap-3">
            <Controller
              name="code"
              control={confirmForm.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-code">Confirmation code</FieldLabel>
                  <Input
                    id="signup-code"
                    autoFocus
                    placeholder="123456"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
            {confirmForm.formState.errors.root && (
              <FieldError>{confirmForm.formState.errors.root.message}</FieldError>
            )}
            <Button type="submit" className="w-full" disabled={confirmSignup.isPending}>
              {confirmSignup.isPending ? 'Confirming...' : 'Confirm account'}
            </Button>
            <div className="flex items-center justify-between gap-2 pt-1">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => setConfirmingEmail(null)}
                disabled={confirmSignup.isPending}
              >
                Back to sign up
              </Button>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={onResend}
                disabled={resendCode.isPending || confirmSignup.isPending}
              >
                {resendCode.isPending ? 'Sending...' : 'Resend code'}
              </Button>
            </div>
          </FieldGroup>
        </form>
      </AuthLayout>
    )
  }

  return (
    <AuthLayout
      title="Create account"
      subtitle="Plan meetings with your team."
      footer={
        <>
          Already have an account?{' '}
          <Link to="/login" className="font-semibold text-hover underline-offset-4 hover:underline">
            Sign in
          </Link>
        </>
      }
    >
      <GoogleButton
        disabled={pending}
        pending={googleLogin.isPending}
        onClick={() => googleLogin.mutate(undefined, { onError })}
      >
        Sign up with Google
      </GoogleButton>
      <OrDivider />
      <form onSubmit={onSubmit} noValidate>
        <FieldGroup className="gap-4 short:gap-3">
          <Controller
            name="name"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-name">Name</FieldLabel>
                <Input
                  id="signup-name"
                  autoComplete="name"
                  autoFocus
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          <Controller
            name="email"
            control={form.control}
            render={({ field, fieldState }) => (
              <Field data-invalid={fieldState.invalid}>
                <FieldLabel htmlFor="signup-email">Email</FieldLabel>
                <Input
                  id="signup-email"
                  type="email"
                  autoComplete="email"
                  aria-invalid={fieldState.invalid}
                  {...field}
                />
                <FieldError errors={[fieldState.error]} />
              </Field>
            )}
          />
          {/* Side by side on wider screens so the whole form fits without scrolling. */}
          <div className="grid gap-4 sm:grid-cols-2 short:gap-3">
            <Controller
              name="password"
              control={form.control}
              render={({ field, fieldState }) => (
                <Field data-invalid={fieldState.invalid}>
                  <FieldLabel htmlFor="signup-password">Password</FieldLabel>
                  <PasswordInput
                    id="signup-password"
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
                  <FieldLabel htmlFor="signup-confirm">Confirm</FieldLabel>
                  <PasswordInput
                    id="signup-confirm"
                    autoComplete="new-password"
                    aria-invalid={fieldState.invalid}
                    {...field}
                  />
                  <FieldError errors={[fieldState.error]} />
                </Field>
              )}
            />
          </div>
          {form.formState.errors.root && (
            <FieldError>{form.formState.errors.root.message}</FieldError>
          )}
          <Button type="submit" className="mt-1 w-full" disabled={pending}>
            {signup.isPending ? 'Creating account...' : 'Create account'}
          </Button>
        </FieldGroup>
      </form>
    </AuthLayout>
  )
}
