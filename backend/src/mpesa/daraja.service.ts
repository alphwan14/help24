import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import axios, { AxiosInstance, isAxiosError } from 'axios';

const DARAJA_BASES = {
  sandbox: 'https://sandbox.safaricom.co.ke',
  production: 'https://api.safaricom.co.ke',
} as const;

const STK_PATH  = '/mpesa/stkpush/v1/processrequest';
const OAUTH_PATH = '/oauth/v1/generate?grant_type=client_credentials';
const B2C_PATH  = '/mpesa/b2c/v1/paymentrequest';
const TXN_STATUS_PATH = '/mpesa/transactionstatus/v1/query';

interface TokenCache {
  token: string;
  expiresAt: number;
}

export interface StkPushResult {
  checkoutRequestId: string;
  merchantRequestId: string;
  customerMessage: string;
}

export interface B2cResult {
  conversationId: string;
  originatorConversationId: string;
}

export interface TransactionStatusAck {
  conversationId: string;
  originatorConversationId: string;
  responseCode: string;
}

@Injectable()
export class DarajaService {
  private readonly logger = new Logger(DarajaService.name);
  private readonly baseUrl: string;
  private readonly client: AxiosInstance;
  private tokenCache: TokenCache | null = null;

  constructor(private readonly config: ConfigService) {
    const env = config.get<string>('MPESA_ENV', 'sandbox');

    if (env !== 'sandbox' && env !== 'production') {
      throw new Error(
        `Invalid Daraja configuration detected. MPESA_ENV must be "sandbox" or "production", got "${env}".`,
      );
    }

    this.baseUrl = DARAJA_BASES[env];
    this.logger.log(`Daraja → ${env.toUpperCase()} (${this.baseUrl})`);
    this.logger.log(`  OAuth : ${this.baseUrl}${OAUTH_PATH}`);
    this.logger.log(`  STK   : ${this.baseUrl}${STK_PATH}`);
    this.logger.log(`  B2C   : ${this.baseUrl}${B2C_PATH}`);

    this.client = axios.create({
      baseURL: this.baseUrl,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  // Extracts Daraja's response body from an axios error so the real reason is
  // visible instead of the generic "Request failed with status code NNN".
  private handleAxiosError(context: string, error: unknown): never {
    if (isAxiosError(error)) {
      const status = error.response?.status ?? 'no-response';
      const body   = error.response?.data;
      this.logger.error(
        `[Daraja] ${context} → HTTP ${status}: ${JSON.stringify(body)}`,
      );
      throw new Error(
        `[Daraja] ${context} failed — HTTP ${status}: ${JSON.stringify(body)}`,
      );
    }
    throw error;
  }

  // ── OAuth token ───────────────────────────────────────────────────────────────

  private async getToken(): Promise<string> {
    if (this.tokenCache && Date.now() < this.tokenCache.expiresAt) {
      return this.tokenCache.token;
    }

    const key    = this.config.getOrThrow<string>('MPESA_CONSUMER_KEY');
    const secret = this.config.getOrThrow<string>('MPESA_CONSUMER_SECRET');
    const creds  = Buffer.from(`${key}:${secret}`).toString('base64');

    this.logger.log(`[Daraja] GET ${this.baseUrl}${OAUTH_PATH}`);

    let data: Record<string, unknown>;
    try {
      ({ data } = await this.client.get(OAUTH_PATH, {
        headers: { Authorization: `Basic ${creds}` },
      }));
    } catch (err) {
      this.handleAxiosError('OAuth token', err);
    }

    const expiresIn = parseInt(String(data.expires_in ?? '3600'), 10) * 1_000;
    this.tokenCache = {
      token: data.access_token as string,
      expiresAt: Date.now() + expiresIn - 60_000,
    };

    this.logger.log('[Daraja] Access token refreshed');
    return this.tokenCache.token;
  }

  // ── STK push ──────────────────────────────────────────────────────────────────

  async stkPush(params: {
    phone: string;
    amount: number;
    postId: string;
    /** Optional Daraja AccountReference override (default: Help24-<postId prefix>). */
    accountReference?: string;
    /** Optional Daraja TransactionDesc override (default: escrow wording). */
    transactionDesc?: string;
  }): Promise<StkPushResult> {
    const token       = await this.getToken();
    const shortcode   = this.config.getOrThrow<string>('MPESA_SHORTCODE');
    const passkey     = this.config.getOrThrow<string>('MPESA_PASSKEY');
    const callbackUrl = this.config.getOrThrow<string>('MPESA_CALLBACK_URL');

    const timestamp = new Date()
      .toISOString()
      .replace(/[-:T.Z]/g, '')
      .slice(0, 14); // YYYYMMDDHHmmss

    const password = Buffer.from(`${shortcode}${passkey}${timestamp}`).toString('base64');

    const payload = {
      BusinessShortCode: shortcode,
      Password:          password,
      Timestamp:         timestamp,
      TransactionType:   'CustomerPayBillOnline',
      Amount:            params.amount,
      PartyA:            params.phone,
      PartyB:            shortcode,
      PhoneNumber:       params.phone,
      CallBackURL:       callbackUrl,
      AccountReference:  params.accountReference ?? `Help24-${params.postId.slice(0, 12)}`,
      TransactionDesc:   params.transactionDesc ?? 'Help24 Escrow Payment',
    };

    this.logger.log(
      `[Daraja] STK request — shortcode=${shortcode} timestamp=${timestamp} password_len=${password.length} phone=${params.phone} amount=${params.amount} callback=${callbackUrl}`,
    );
    this.logger.log(
      `[Daraja] STK payload (no secrets): ${JSON.stringify({
        BusinessShortCode: payload.BusinessShortCode,
        Timestamp:         payload.Timestamp,
        TransactionType:   payload.TransactionType,
        Amount:            payload.Amount,
        PartyA:            payload.PartyA,
        PartyB:            payload.PartyB,
        AccountReference:  payload.AccountReference,
        CallBackURL:       payload.CallBackURL,
      })}`,
    );

    let data: Record<string, unknown>;
    try {
      ({ data } = await this.client.post(STK_PATH, payload, {
        headers: { Authorization: `Bearer ${token}` },
      }));
    } catch (err) {
      this.handleAxiosError('STK push', err);
    }

    this.logger.log(`[Daraja] STK response: ${JSON.stringify(data)}`);

    if (data.ResponseCode !== '0') {
      throw new Error(`STK push rejected by Daraja: ${data.ResponseDescription}`);
    }

    return {
      checkoutRequestId: data.CheckoutRequestID as string,
      merchantRequestId: data.MerchantRequestID as string,
      customerMessage:   (data.CustomerMessage as string) ?? 'Check your phone for the M-Pesa prompt.',
    };
  }

  // ── B2C payout ────────────────────────────────────────────────────────────────

  async b2cPayout(params: {
    phone: string;
    amount: number;
    jobId: string;
  }): Promise<B2cResult> {
    const token              = await this.getToken();
    const shortcode          = this.config.getOrThrow<string>('MPESA_SHORTCODE');
    const initiatorName      = this.config.getOrThrow<string>('MPESA_B2C_INITIATOR_NAME');
    const securityCredential = this.config.getOrThrow<string>('MPESA_B2C_SECURITY_CREDENTIAL');
    const resultUrl          = this.config.getOrThrow<string>('MPESA_B2C_RESULT_URL');
    const timeoutUrl         = this.config.getOrThrow<string>('MPESA_B2C_TIMEOUT_URL');

    const payload = {
      InitiatorName:      initiatorName,
      SecurityCredential: securityCredential,
      CommandID:          'BusinessPayment',
      Amount:             params.amount,
      PartyA:             shortcode,
      PartyB:             params.phone,
      Remarks:            'Help24 Provider Payout',
      QueueTimeOutURL:    timeoutUrl,
      ResultURL:          resultUrl,
      Occasion:           params.jobId,
    };

    this.logger.log(
      `[PAYOUT][DARAJA_REQUEST] POST ${this.baseUrl}${B2C_PATH} phone=${params.phone} amount=${params.amount} jobId=${params.jobId}`,
    );

    let data: Record<string, unknown>;
    try {
      ({ data } = await this.client.post(B2C_PATH, payload, {
        headers: { Authorization: `Bearer ${token}` },
      }));
    } catch (err) {
      this.handleAxiosError('B2C payout', err);
    }

    this.logger.log(`[PAYOUT][DARAJA_RESPONSE] raw: ${JSON.stringify(data)}`);

    if (data.ResponseCode !== '0') {
      throw new Error(`B2C payout rejected by Daraja: ${data.ResponseDescription}`);
    }

    this.logger.log(
      `[PAYOUT][DARAJA_RESPONSE] accepted conversationId=${data.ConversationID as string} originatorConversationId=${data.OriginatorConversationID as string}`,
    );

    return {
      conversationId:              data.ConversationID as string,
      originatorConversationId:    data.OriginatorConversationID as string,
    };
  }

  // ── Transaction Status Query (B2C reconciliation) ──────────────────────────────
  //
  // Asks Daraja for the definitive outcome of a prior B2C payout when its RESULT
  // callback never arrived. This is ASYNCHRONOUS: Daraja returns only an
  // acknowledgement here; the real status is POSTed to `ResultURL` later (handled
  // by MpesaService.handleB2cStatusResult), so no money is settled inline. We
  // correlate the eventual result back to our transaction via `Occasion` (echoed
  // in the result's ReferenceData) and OriginatorConversationID.

  async transactionStatusQuery(params: {
    originatorConversationId?: string;
    transactionId?: string;
    occasion?: string;
    remarks?: string;
  }): Promise<TransactionStatusAck> {
    if (!params.originatorConversationId && !params.transactionId) {
      throw new Error(
        'transactionStatusQuery requires either originatorConversationId or transactionId to identify the payout.',
      );
    }

    const token              = await this.getToken();
    const shortcode          = this.config.getOrThrow<string>('MPESA_SHORTCODE');
    const initiatorName      = this.config.getOrThrow<string>('MPESA_B2C_INITIATOR_NAME');
    const securityCredential = this.config.getOrThrow<string>('MPESA_B2C_SECURITY_CREDENTIAL');
    const timeoutUrl         = this.config.getOrThrow<string>('MPESA_B2C_TIMEOUT_URL');
    // Dedicated result route; defaults to swapping the B2C callback path so no new
    // required env var is introduced for existing deployments.
    const b2cResultUrl       = this.config.getOrThrow<string>('MPESA_B2C_RESULT_URL');
    const resultUrl =
      this.config.get<string>('MPESA_TXN_STATUS_RESULT_URL') ??
      b2cResultUrl.replace(/\/mpesa\/[^/]+$/, '/mpesa/b2c-status-result');

    const payload = {
      Initiator:          initiatorName,
      SecurityCredential: securityCredential,
      CommandID:          'TransactionStatusQuery',
      ...(params.transactionId ? { TransactionID: params.transactionId } : {}),
      ...(params.originatorConversationId
        ? { OriginatorConversationID: params.originatorConversationId }
        : {}),
      PartyA:             shortcode,
      IdentifierType:     '4', // 4 = organisation shortcode
      ResultURL:          resultUrl,
      QueueTimeOutURL:    timeoutUrl,
      Remarks:            params.remarks ?? 'Help24 payout reconcile',
      Occasion:           params.occasion ?? 'reconcile',
    };

    this.logger.log(
      `[PAYOUT][STATUS_QUERY] POST ${this.baseUrl}${TXN_STATUS_PATH} originatorConversationId=${params.originatorConversationId ?? 'n/a'} transactionId=${params.transactionId ?? 'n/a'} occasion=${payload.Occasion} resultUrl=${resultUrl}`,
    );

    let data: Record<string, unknown>;
    try {
      ({ data } = await this.client.post(TXN_STATUS_PATH, payload, {
        headers: { Authorization: `Bearer ${token}` },
      }));
    } catch (err) {
      this.handleAxiosError('Transaction Status Query', err);
    }

    this.logger.log(`[PAYOUT][STATUS_QUERY] ack: ${JSON.stringify(data)}`);

    if (data.ResponseCode !== '0') {
      throw new Error(
        `Transaction Status Query rejected by Daraja: ${data.ResponseDescription as string}`,
      );
    }

    return {
      conversationId:           data.ConversationID as string,
      originatorConversationId: data.OriginatorConversationID as string,
      responseCode:             data.ResponseCode as string,
    };
  }
}
