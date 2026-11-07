import LoginForm from "./LoginForm";

/**
 * /login. A server component on purpose: it reads the query here and hands it
 * to the form, so the whole sign-in page — Google's button space included —
 * is in the first HTML. Reading it in the browser with useSearchParams made
 * Next render nothing on the server (an empty Suspense boundary), so the page
 * arrived blank and was drawn only once the script ran.
 */
export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; message?: string; reset?: string }>;
}) {
  const { error, message, reset } = await searchParams;
  return <LoginForm query={{ error, message, reset }} />;
}
