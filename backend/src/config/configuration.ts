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

  return {
    port: parseInt(process.env.PORT ?? '3000', 10),
    allowedOrigins: process.env.ALLOWED_ORIGINS
      ?.split(',')
      .map((s) => s.trim())
      .filter(Boolean) ?? [],
    supabase: {
      url: required('SUPABASE_URL'),
      serviceRoleKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    },
    mpesa: {
      env: required('MPESA_ENV'),
      consumerKey: required('MPESA_CONSUMER_KEY'),
      consumerSecret: required('MPESA_CONSUMER_SECRET'),
      shortcode: required('MPESA_SHORTCODE'),
      passkey: required('MPESA_PASSKEY'),
      callbackUrl: required('MPESA_CALLBACK_URL'),
      b2cInitiatorName: required('MPESA_B2C_INITIATOR_NAME'),
      b2cSecurityCredential: required('MPESA_B2C_SECURITY_CREDENTIAL'),
      b2cResultUrl: required('MPESA_B2C_RESULT_URL'),
      b2cTimeoutUrl: required('MPESA_B2C_TIMEOUT_URL'),
    },
  };
};
