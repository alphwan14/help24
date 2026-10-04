import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createClient, SupabaseClient } from '@supabase/supabase-js';

@Injectable()
export class SupabaseService {
  readonly client: SupabaseClient;

  /** The project origin. Read where a stored public storage URL must be recognised. */
  readonly url: string;

  constructor(private readonly configService: ConfigService) {
    this.url = this.configService.getOrThrow('SUPABASE_URL');
    this.client = createClient(
      this.url,
      this.configService.getOrThrow('SUPABASE_SERVICE_ROLE_KEY'),
    );
  }
}
