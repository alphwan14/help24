// All required env variables are validated here at startup.
// A missing variable throws immediately — the server will not start.
export const configuration = (): Record<string, unknown> => {
  function required(key: string): string {
    const value = process.env[key];
    if (!value || value.trim() === '') {
      throw new Error(`[Config] Missing required env variable: ${key}`);
    }
    return value.trim();
  }

  // Validates that a callback URL is HTTPS and contains the expected path.
  // Daraja rejects non-HTTPS callbacks and a missing path returns 404.
  function callbackUrl(key: string, expectedPath: string): string {
    const url = required(key);
    if (!url.startsWith('https://')) {
      throw new Error(`[Config] ${key} must use HTTPS — got: ${url}`);
    }
    if (!url.includes(expectedPath)) {
      throw new Error(
        `[Config] ${key} must contain "${expectedPath}" — got: ${url}`,
      );
    }
    return url;
  }

  return {
    port: parseInt(process.env.PORT ?? '3000', 10),
    supabase: {
      url: required('SUPABASE_URL'),
      serviceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    },
    google: {
      // OPTIONAL on purpose — not `required()`. Journey ETAs are an
      // enhancement; if this is unset the /routes endpoint answers
      // "unavailable" and the app keeps its straight-line behaviour. The
      // server must never refuse to boot over a missing Phase 3 nicety.
      //
      // Must be a SERVER key (no Android app restriction — Routes is a web
      // service and ignores package/SHA-1 restrictions). Restrict by IP or
      // leave unrestricted but server-held; never ship it in the app.
      routesApiKey: process.env.GOOGLE_ROUTES_API_KEY?.trim() || undefined,
    },
    mpesa: {
      env: required('MPESA_ENV'),
      consumerKey: required('MPESA_CONSUMER_KEY'),
      consumerSecret: required('MPESA_CONSUMER_SECRET'),
      shortcode: required('MPESA_SHORTCODE'),
      passkey: required('MPESA_PASSKEY'),
      callbackUrl: callbackUrl('MPESA_CALLBACK_URL', '/mpesa/stk-callback'),
      b2cInitiatorName: required('MPESA_B2C_INITIATOR_NAME'),
      b2cSecurityCredential: required('MPESA_B2C_SECURITY_CREDENTIAL'),
      b2cResultUrl: callbackUrl('MPESA_B2C_RESULT_URL', '/mpesa/b2c-callback'),
      b2cTimeoutUrl: callbackUrl('MPESA_B2C_TIMEOUT_URL', '/mpesa/b2c-timeout'),
    },
  };
};
